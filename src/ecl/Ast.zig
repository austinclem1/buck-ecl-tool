const std = @import("std");

const Ast = @This();

const CommandTag = @import("CommandTag.zig").Tag;
const VarType = @import("VarType.zig").VarType;
const IndexSlice = @import("../IndexSlice.zig");

const ecl_base = 0x6af6;
const stub_address: u16 = 0;

header: [5]usize,
command_blocks: []const CommandBlock,
commands: []const Command,
args: []const Arg,
data_blocks: []const DataBlock,
vars: []const Var,
arena: std.heap.ArenaAllocator,

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub const CommandBlock = struct {
    label: []const u8,
    commands: IndexSlice,
};

pub const Command = struct {
    args: IndexSlice,
    tag: CommandTag,
};

pub const Arg = union(enum) {
    immediate: u32,
    var_use: usize,
    ptr_deref: PtrDeref,
    command_block: usize,
    data_block: usize,
    string: []const u8,
};

pub const DataBlock = struct {
    label: []const u8,
    bytes: []const u8,
};

pub const Var = struct {
    name: []const u8,
    address: u16,
    var_type: VarType,
};

pub const PtrDeref = struct {
    ptr_var_id: usize,
    offset: u16,
    deref_type: VarType,
};

pub fn getBlockCommands(self: *const Ast, block: CommandBlock) []const Command {
    return self.commands[block.commands.start..block.commands.stop];
}

pub fn getCommandArgs(self: *const Ast, command: Command) []const Arg {
    return self.args[command.args.start..command.args.stop];
}

pub fn serializeText(self: *const @This(), writer: *std.Io.Writer) !void {
    try writer.print("header:\n", .{});
    for (self.header) |block_index| {
        try writer.print("\t{s}\n", .{self.command_blocks[block_index].label});
    }

    try writer.print("\n", .{});
    for (self.vars) |v| {
        try writer.print("var {s}: {s} @ 0x{x}\n", .{ v.name, @tagName(v.var_type), v.address });
    }
    try writer.print("\n", .{});

    for (self.command_blocks) |block| {
        try writer.print("{s}:\n", .{block.label});
        for (self.getBlockCommands(block)) |cmd| {
            try writer.print("\t{s}", .{@tagName(cmd.tag)});
            for (self.getCommandArgs(cmd)) |arg| {
                switch (arg) {
                    .immediate => |val| {
                        try writer.print(" {d}", .{val});
                    },
                    .var_use => |index| {
                        try writer.print(" {s}", .{self.vars[index].name});
                    },
                    .ptr_deref => |info| {
                        const base_var = self.vars[info.ptr_var_id];
                        const letter: u8 = switch (info.deref_type) {
                            .byte => 'b',
                            .word => 'w',
                            .dword => 'd',
                            .pointer => std.debug.panic("Encountered dereference to `pointer` type\n", .{}),
                        };
                        try writer.print(" {s}[{d}]{c}", .{ base_var.name, info.offset, letter });
                    },
                    .command_block => |index| {
                        try writer.print(" {s}", .{self.command_blocks[index].label});
                    },
                    .data_block => |index| {
                        try writer.print(" {s}", .{self.data_blocks[index].label});
                    },
                    .string => |s| {
                        try writer.print(" \"{s}\"", .{s});
                    },
                }
            }
            try writer.writeByte('\n');
        }
    }
    for (self.data_blocks) |block| {
        try writer.print("{s}:\n", .{block.label});
        try writer.print("\tBYTES", .{});
        for (block.bytes) |b| {
            try writer.print(" {d}", .{b});
        }
        try writer.print("\n", .{});
    }

    try writer.flush();
}

const AddressStub = struct {
    location: usize,
    dest: Dest,

    const Dest = union(enum) {
        command_block: usize,
        data_block: usize,
    };
};

pub const EclBinary = struct {
    script: []u8,
    text: []u8,
};

pub fn serializeBinary(self: *const @This(), gpa: std.mem.Allocator) !EclBinary {
    var output = std.Io.Writer.Allocating.init(gpa);
    defer output.deinit();

    var string_bytes: std.ArrayList(u8) = .empty;
    defer string_bytes.deinit(gpa);

    var address_stubs: std.ArrayList(AddressStub) = .empty;
    defer address_stubs.deinit(gpa);

    for (&self.header) |block_index| {
        try output.writer.writeInt(u16, 0x0101, .little);
        try address_stubs.append(gpa, .{
            .location = output.writer.end,
            .dest = .{ .command_block = block_index },
        });
        try output.writer.writeInt(u16, stub_address, .little);
    }

    var command_block_addresses = try std.ArrayList(u16).initCapacity(gpa, self.command_blocks.len);
    defer command_block_addresses.deinit(gpa);
    var data_block_addresses = try std.ArrayList(u16).initCapacity(gpa, self.data_blocks.len);
    defer data_block_addresses.deinit(gpa);

    for (self.command_blocks) |block| {
        command_block_addresses.appendAssumeCapacity(@intCast(output.writer.end + ecl_base));
        for (self.getBlockCommands(block)) |command| {
            try output.writer.writeByte(@intFromEnum(command.tag));
            for (self.getCommandArgs(command)) |arg| {
                try writeArgBinary(gpa, arg, &output.writer, self.vars, &address_stubs, &string_bytes);
            }
        }
    }

    for (self.data_blocks) |block| {
        data_block_addresses.appendAssumeCapacity(@intCast(output.writer.end + ecl_base));
        try output.writer.writeAll(block.bytes);
    }

    std.debug.assert(command_block_addresses.items.len == self.command_blocks.len);
    std.debug.assert(data_block_addresses.items.len == self.data_blocks.len);
    var out_script = try output.toOwnedSlice();
    errdefer gpa.free(out_script);
    for (address_stubs.items) |stub_info| {
        const address = switch (stub_info.dest) {
            .command_block => |index| command_block_addresses.items[index],
            .data_block => |index| data_block_addresses.items[index],
        };
        var fixed_writer = std.Io.Writer.fixed(out_script[stub_info.location..]);
        try fixed_writer.writeInt(u16, address, .little);
    }

    if (output.writer.end % 2 == 1) {
        try output.writer.writeByte(0);
    }

    const out_text = try string_bytes.toOwnedSlice(gpa);
    errdefer gpa.free(out_text);

    return EclBinary{
        .script = out_script,
        .text = out_text,
    };
}

fn writeArgBinary(gpa: std.mem.Allocator, arg: Arg, out_writer: *std.Io.Writer, vars: []const Var, address_stubs: *std.ArrayList(AddressStub), string_bytes: *std.ArrayList(u8)) !void {
    switch (arg) {
        .immediate => |val| {
            if (std.math.cast(u8, val)) |cast_val| {
                try out_writer.writeByte(0);
                try out_writer.writeByte(cast_val);
            } else if (std.math.cast(u16, val)) |cast_val| {
                try out_writer.writeByte(2);
                try out_writer.writeInt(u16, cast_val, .little);
            } else {
                try out_writer.writeByte(4);
                try out_writer.writeInt(u32, val, .little);
            }
        },
        .var_use => |var_index| {
            const var_info = vars[var_index];
            const meta_byte: u8 = switch (var_info.var_type) {
                .byte => 1,
                .word => 3,
                .dword => 5,
                .pointer => 0x81,
            };
            try out_writer.writeByte(meta_byte);
            try out_writer.writeInt(u16, var_info.address, .little);
        },
        .ptr_deref => |deref_info| {
            const var_info = vars[deref_info.ptr_var_id];
            std.debug.assert(var_info.var_type == .pointer);
            const meta_byte: u8 = switch (deref_info.deref_type) {
                .byte => 1,
                .word => 3,
                .dword => 5,
                .pointer => std.debug.panic("Encountered pointer dereference to pointer type\n", .{}),
            };
            try out_writer.writeByte(meta_byte);
            try out_writer.writeInt(u16, @intCast(var_info.address + deref_info.offset), .little);
        },
        .string => |s| {
            const string_offset: u16 = @intCast(string_bytes.items.len);
            try string_bytes.appendSlice(gpa, s);
            try string_bytes.append(gpa, 0x00); // null terminator
            try out_writer.writeByte(0x80);
            try out_writer.writeInt(u16, string_offset, .little);
        },
        .command_block => |block_index| {
            try out_writer.writeByte(1);
            try address_stubs.append(gpa, .{
                .location = out_writer.end,
                .dest = .{ .command_block = block_index },
            });
            try out_writer.writeInt(u16, stub_address, .little);
        },
        .data_block => |block_index| {
            try out_writer.writeByte(1);
            try address_stubs.append(gpa, .{
                .location = out_writer.end,
                .dest = .{ .data_block = block_index },
            });
            try out_writer.writeInt(u16, stub_address, .little);
        },
    }
}

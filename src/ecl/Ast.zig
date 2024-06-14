const std = @import("std");

const Ast = @This();

const CommandTag = @import("CommandTag.zig").Tag;
const VarType = @import("VarType.zig").VarType;
const IndexSlice = @import("../IndexSlice.zig");

header: [5]usize,
blocks: []const Block,
commands: []const Command,
args: []const Arg,
init_segments: []const InitSegment,
vars: []const Var,
arena: std.heap.ArenaAllocator,

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub const Block = struct {
    label: []const u8,
    commands: IndexSlice,
};

pub const Command = struct {
    args: IndexSlice,
    tag: CommandTag,
};

pub const Arg = union(enum) {
    immediate: usize,
    var_use: usize,
    ptr_deref: PtrDeref,
    jump_dest_block: usize,
    init_data_segment: usize,
    string: []const u8,
};

pub const InitSegment = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const Var = struct {
    name: []const u8,
    address: u16,
    var_type: VarType,
};

pub const PtrDeref = struct {
    ptr_var_id: usize,
    offset: usize,
    deref_type: VarType,
};

pub fn getBlockCommands(self: *const Ast, block: Block) []const Command {
    return self.commands[block.commands.start..block.commands.stop];
}

pub fn getCommandArgs(self: *const Ast, command: Command) []const Arg {
    return self.args[command.args.start..command.args.stop];
}

pub fn serializeText(self: *const @This(), writer: anytype) !void {
    try writer.print("header:\n", .{});
    for (self.header) |block_index| {
        try writer.print("\t{s}\n", .{self.blocks[block_index].label});
    }

    for (self.blocks) |block| {
        try writer.print("{s}:\n", .{block.label});
        for (self.getBlockCommands(block)) |cmd| {
            try writer.print("\t{s}", .{@tagName(cmd.tag)});
            for (self.getCommandArgs(cmd)) |arg| {
                switch (arg) {
                    .immediate => |val| {
                        try writer.print(" {x}", .{val});
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
                    .jump_dest_block => |index| {
                        try writer.print(" {s}", .{self.blocks[index].label});
                    },
                    .init_data_segment => |index| {
                        try writer.print(" {s}", .{self.init_segments[index].name});
                    },
                    .string => |s| {
                        try writer.print(" \"{s}\"", .{s});
                    },
                }
            }
            try writer.writeByte('\n');
        }
    }
    for (self.init_segments) |segment| {
        try writer.print("{s}:\n", .{segment.name});
        try writer.print("\t{s}\n", .{std.fmt.fmtSliceHexLower(segment.bytes)});
    }
}

// pub fn serializeBinary(self: *const @This(), writer: anytype) !void {
//     var counting_writer = std.io.countingWriter(writer);
//     const w = counting_writer.writer();
//
//     for (self.header) |address| {
//         try w.writeInt(u16, 0x0101, .little);
//         try w.writeInt(u16, address, .little);
//     }
//     for (self.commands) |command| {
//         try w.writeByte(@intFromEnum(command.tag));
//         for (self.getCommandArgs(command)) |arg| {
//             try writeArgBinary(arg, w);
//         }
//     }
//
//     for (self.init_data_segments) |segment| {
//         try w.writeAll(segment.bytes);
//     }
//
//     if (counting_writer.bytes_written % 2 == 1) {
//         try w.writeByte(0);
//     }
// }
//
// fn writeArgBinary(arg: Arg, writer: anytype) !void {
//     const encoding = arg.getEncoding();
//     const meta_byte = encoding.getMetaByte();
//     switch (encoding) {
//         .immediate1 => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeByte(@intCast(arg.immediate));
//         },
//         .immediate2 => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.immediate), .little);
//         },
//         .immediate4 => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u32, @intCast(arg.immediate), .little);
//         },
//         .byte_var => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.byte_var), .little);
//         },
//         .word_var => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.word_var), .little);
//         },
//         .dword_var => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.dword_var), .little);
//         },
//         .mem_address => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.mem_address), .little);
//         },
//         .string => {
//             try writer.writeInt(i8, meta_byte, .little);
//             try writer.writeInt(u16, @intCast(arg.string), .little);
//         },
//     }
// }

const std = @import("std");

const Ast = @import("Ast.zig");
const CommandTag = @import("CommandTag.zig").Tag;
const VarType = @import("VarType.zig").VarType;
const IndexSlice = @import("../IndexSlice.zig");

const ecl_base = 0x6af6;
const scratch_start = 0x9e6f;
const scratch_end = 0x9e79;

const Command = struct {
    tag: CommandTag,
    args: IndexSlice,
    address: u16,
};

pub fn parseAlloc(allocator: std.mem.Allocator, script_bytes: []const u8, text_bytes: []const u8, initial_highest_known_command_address: ?u16) !Ast {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const duped_text_bytes = try arena.allocator().dupe(u8, text_bytes);

    var var_map = std.AutoArrayHashMap(VarUse, []const u8).init(allocator);
    defer var_map.deinit();

    var init_data_refs = std.AutoArrayHashMap(u16, void).init(allocator);
    defer init_data_refs.deinit();

    var jump_dests = std.AutoArrayHashMap(u16, void).init(allocator);
    defer jump_dests.deinit();

    var script_stream = std.io.fixedBufferStream(script_bytes);

    const header, const commands, const args = try readHeaderAndCommands(allocator, &script_stream, initial_highest_known_command_address);
    defer allocator.free(commands);
    defer allocator.free(args);

    // if multiple bytes still remain after reading all commands and args, assume they are
    // initialized bytes that must be tracked
    // if 1 byte remains, it's probably just padding to
    // keep the script alignment of 2
    if (try script_stream.getEndPos() - script_stream.pos > 1) {
        try init_data_refs.put(@intCast(ecl_base + script_stream.pos), {});
    }

    for (&header) |address| {
        try jump_dests.put(address, {});
    }

    for (args) |*arg| {
        switch (arg.*) {
            .jump_dest_addr => |address| try jump_dests.put(address, {}),
            .var_use => canonicalizeVarUse(arg, script_bytes.len),
            else => {},
        }

        switch (arg.*) {
            .var_use => |info| {
                if (!var_map.contains(info)) {
                    const name = try generateVarName(arena.allocator(), info);
                    try var_map.putNoClobber(info, name);
                }
            },
            .ptr_deref => |info| {
                const base_ptr_var = info.getBaseVar();
                if (!var_map.contains(base_ptr_var)) {
                    const name = try generateVarName(arena.allocator(), base_ptr_var);
                    try var_map.putNoClobber(base_ptr_var, name);
                }
            },
            .init_data_addr => |address| try init_data_refs.put(address, {}),
            else => {},
        }
    }

    {
        const SortByAddress = struct {
            keys: []const u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };
        jump_dests.sort(SortByAddress{ .keys = jump_dests.keys() });
    }

    std.debug.assert(jump_dests.count() >= 1);

    const blocks = try getBlocksFromCommandsAndJumpDests(arena.allocator(), commands, jump_dests.keys());

    const ast_header = astHeaderFromHeader(header, jump_dests);

    {
        const SortByAddress = struct {
            keys: []const u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };
        init_data_refs.sort(SortByAddress{ .keys = init_data_refs.keys() });
    }

    const init_segments = try getInitSegmentsFromRefs(arena.allocator(), script_bytes, init_data_refs.keys());

    const vars = try getVarsFromVarMap(arena.allocator(), var_map);

    const ast_commands = try getAstCommandsFromCommands(arena.allocator(), commands);

    const ast_args = try getAstArgsFromArgs(arena.allocator(), args, var_map, jump_dests, init_data_refs, duped_text_bytes);

    const ast = Ast{
        .header = ast_header,
        .blocks = blocks,
        .commands = ast_commands,
        .args = ast_args,
        .init_segments = init_segments,
        .vars = vars,
        .arena = arena,
    };

    return ast;
}

fn readHeader(reader: anytype) ![5]u16 {
    var result: [5]u16 = undefined;
    for (&result) |*address| {
        try reader.skipBytes(2, .{});
        address.* = try reader.readInt(u16, .little);
    }
    return result;
}

fn readHeaderAndCommands(allocator: std.mem.Allocator, script_stream: *std.io.FixedBufferStream([]const u8), initial_highest_known_command_address: ?u16) !struct { [5]u16, []Command, []Arg } {
    var commands = std.ArrayList(Command).init(allocator);
    defer commands.deinit();
    var args = std.ArrayList(Arg).init(allocator);
    defer args.deinit();

    const header = try readHeader(script_stream.reader());
    var highest_known_command_address = std.mem.max(u16, &header);
    if (initial_highest_known_command_address) |address| {
        highest_known_command_address = @max(address, highest_known_command_address);
    }

    var last_command_was_conditional = false;
    while (script_stream.pos + ecl_base <= highest_known_command_address) {
        const command = blk: {
            var c: Command = undefined;

            c.address = @intCast(script_stream.pos + ecl_base);
            c.tag = try script_stream.reader().readEnum(CommandTag, .little);
            c.args.start = args.items.len;
            try readCommandArgs(script_stream.reader(), c.tag, &args);
            c.args.stop = args.items.len;

            break :blk c;
        };

        try commands.append(command);

        for (args.items[command.args.start..command.args.stop]) |arg| {
            if (arg == .jump_dest_addr) {
                highest_known_command_address = @max(arg.jump_dest_addr, highest_known_command_address);
            }
        }

        if (command.tag.isFallthrough() or last_command_was_conditional) {
            const next_command_address: u16 = @intCast(script_stream.pos + ecl_base);
            highest_known_command_address = @max(next_command_address, highest_known_command_address);
        }

        last_command_was_conditional = command.tag.isConditional();
    }

    const owned_commands = try commands.toOwnedSlice();
    errdefer allocator.free(owned_commands);
    const owned_args = try args.toOwnedSlice();
    errdefer allocator.free(owned_args);

    return .{
        header,
        owned_commands,
        owned_args,
    };
}

fn readCommandArgs(reader: anytype, command_tag: CommandTag, args: *std.ArrayList(Arg)) !void {
    switch (command_tag) {
        .ONGOTO, .ONGOSUB => {
            const arg0 = try readArg(reader);
            const arg1 = try readArg(reader);

            try args.append(arg0);
            try args.append(arg1);

            const num_varargs = arg1.immediate;
            try args.ensureUnusedCapacity(num_varargs);
            for (0..num_varargs) |_| {
                const arg = try readJumpDestArg(reader);
                args.appendAssumeCapacity(arg);
            }
        },
        .HMENU, .WHMENU, .TREASURE, .NEWREGION => {
            const arg0 = try readArg(reader);
            const arg1 = try readArg(reader);

            try args.append(arg0);
            try args.append(arg1);

            const num_varargs = if (command_tag == .NEWREGION) arg1.immediate * 4 else arg1.immediate;
            try args.ensureUnusedCapacity(num_varargs);
            for (0..num_varargs) |_| {
                const arg = try readArg(reader);
                args.appendAssumeCapacity(arg);
            }
        },
        .GOTO, .GOSUB => {
            const arg = try readJumpDestArg(reader);
            try args.append(arg);
        },
        else => {
            try args.ensureUnusedCapacity(command_tag.getArgCount());
            for (0..command_tag.getArgCount()) |_| {
                const arg = try readArg(reader);
                args.appendAssumeCapacity(arg);
            }
        },
    }
}

fn canonicalizeVarUse(arg: *Arg, script_len: usize) void {
    const address = arg.var_use.address;
    const var_type = arg.var_use.var_type;

    if (address >= scratch_start and address < scratch_end) {
        arg.* = .{ .ptr_deref = .{
            .base = scratch_start,
            .offset = address - scratch_start,
            .deref_type = var_type,
        } };
    } else if (address >= ecl_base and address < ecl_base + script_len) {
        std.debug.assert(var_type == .byte);
        arg.* = .{ .init_data_addr = address };
    }
}

fn generateVarName(allocator: std.mem.Allocator, var_use: VarUse) ![]const u8 {
    const prefix = switch (var_use.var_type) {
        .byte => "bvar",
        .word => "wvar",
        .dword => "dvar",
        .pointer => "ptr",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}_{x:0>4}",
        .{ prefix, var_use.address },
    );
}

fn astHeaderFromHeader(header_addresses: [5]u16, jump_dests: std.AutoArrayHashMap(u16, void)) [5]usize {
    std.debug.assert(std.sort.isSorted(u16, jump_dests.keys(), {}, std.sort.asc(u16)));

    var result: [5]usize = undefined;
    for (&header_addresses, &result) |address, *block_index| {
        block_index.* = jump_dests.getIndex(address).?;
    }

    return result;
}

fn getBlocksFromCommandsAndJumpDests(allocator: std.mem.Allocator, commands: []const Command, jump_dests: []const u16) ![]Ast.Block {
    std.debug.assert(std.sort.isSorted(u16, jump_dests, {}, std.sort.asc(u16)));

    var blocks = try std.ArrayList(Ast.Block).initCapacity(allocator, jump_dests.len);
    errdefer blocks.deinit();

    var commands_start: usize = 0;
    for (0..jump_dests.len) |i| {
        const block_end_address = if (i >= jump_dests.len - 1) std.math.maxInt(u16) else jump_dests[i + 1];
        // find first command at or past the end address of this block
        var commands_end = commands_start;
        while (commands_end < commands.len) : (commands_end += 1) {
            if (commands[commands_end].address >= block_end_address) break;
        }

        const label = try std.fmt.allocPrint(
            allocator,
            "label_{d}",
            .{i},
        );
        errdefer allocator.free(label);

        blocks.appendAssumeCapacity(.{
            .label = label,
            .commands = IndexSlice{
                .start = commands_start,
                .stop = commands_end,
            },
        });

        commands_start = commands_end;
    }

    return blocks.toOwnedSlice();
}

fn getInitSegmentsFromRefs(allocator: std.mem.Allocator, script: []const u8, ref_addresses: []const u16) ![]Ast.InitSegment {
    std.debug.assert(std.sort.isSorted(u16, ref_addresses, {}, std.sort.asc(u16)));

    var init_segments = try std.ArrayList(Ast.InitSegment).initCapacity(allocator, ref_addresses.len);
    errdefer init_segments.deinit();

    for (0..ref_addresses.len) |i| {
        const name = try std.fmt.allocPrint(
            allocator,
            "init_data{d}",
            .{i},
        );
        errdefer allocator.free(name);

        const start_address = ref_addresses[i];
        const end_address = if (i < ref_addresses.len - 1) ref_addresses[i + 1] else ecl_base + script.len;
        const start = start_address - ecl_base;
        const end = end_address - ecl_base;
        const bytes = try allocator.dupe(u8, script[start..end]);
        errdefer allocator.free(bytes);

        init_segments.appendAssumeCapacity(.{
            .name = name,
            .bytes = bytes,
        });
    }

    return init_segments.toOwnedSlice();
}

fn getVarsFromVarMap(allocator: std.mem.Allocator, var_map: std.AutoArrayHashMap(VarUse, []const u8)) ![]Ast.Var {
    var vars = try std.ArrayList(Ast.Var).initCapacity(allocator, var_map.count());
    errdefer vars.deinit();

    var it = var_map.iterator();
    while (it.next()) |entry| {
        vars.appendAssumeCapacity(.{
            .name = entry.value_ptr.*,
            .address = entry.key_ptr.address,
            .var_type = entry.key_ptr.var_type,
        });
    }

    return vars.toOwnedSlice();
}

fn getAstCommandsFromCommands(allocator: std.mem.Allocator, commands: []const Command) ![]Ast.Command {
    var ast_commands = try std.ArrayList(Ast.Command).initCapacity(allocator, commands.len);
    errdefer ast_commands.deinit();

    for (commands) |command| {
        ast_commands.appendAssumeCapacity(.{
            .tag = command.tag,
            .args = command.args,
        });
    }

    return ast_commands.toOwnedSlice();
}

fn getAstArgsFromArgs(allocator: std.mem.Allocator, args: []const Arg, var_map: std.AutoArrayHashMap(VarUse, []const u8), jump_dests: std.AutoArrayHashMap(u16, void), init_data_refs: std.AutoArrayHashMap(u16, void), text_bytes: []const u8) ![]Ast.Arg {
    std.debug.assert(std.sort.isSorted(u16, jump_dests.keys(), {}, std.sort.asc(u16)));
    std.debug.assert(std.sort.isSorted(u16, init_data_refs.keys(), {}, std.sort.asc(u16)));

    var ast_args = try std.ArrayList(Ast.Arg).initCapacity(allocator, args.len);
    errdefer ast_args.deinit();

    for (args) |arg| {
        const ast_arg: Ast.Arg = switch (arg) {
            .immediate => |val| .{ .immediate = val },
            .var_use => |info| .{ .var_use = var_map.getIndex(info).? },
            .ptr_deref => |info| .{ .ptr_deref = .{
                .ptr_var_id = var_map.getIndex(info.getBaseVar()).?,
                .offset = info.offset,
                .deref_type = info.deref_type,
            } },
            .jump_dest_addr => |address| .{ .jump_dest_block = jump_dests.getIndex(address).? },
            .init_data_addr => |address| .{ .init_data_segment = init_data_refs.getIndex(address).? },
            .string => |offset| .{ .string = std.mem.sliceTo(text_bytes[offset..], '\x00') },
        };

        ast_args.appendAssumeCapacity(ast_arg);
    }

    return ast_args.toOwnedSlice();
}

const Block = struct {
    address: u16,
    commands: IndexSlice,
};

const VarUse = struct {
    address: u16,
    var_type: VarType,
};

const PtrDeref = struct {
    base: u16,
    offset: u16,
    deref_type: VarType,

    pub fn getBaseVar(self: PtrDeref) VarUse {
        return .{
            .address = self.base,
            .var_type = .pointer,
        };
    }
};

const Arg = union(enum) {
    immediate: u32,
    var_use: VarUse,
    ptr_deref: PtrDeref,
    jump_dest_addr: u16,
    init_data_addr: u16,
    string: u16,

    const Encoding = enum {
        immediate1,
        immediate2,
        immediate4,
        byte_var,
        word_var,
        dword_var,
        string,
        mem_address,

        fn fromMetaByte(meta_byte: u8) Encoding {
            return switch (meta_byte) {
                0 => .immediate1,
                2 => .immediate2,
                4 => .immediate4,
                1 => .byte_var,
                3 => .word_var,
                5 => .dword_var,
                0x80 => .string,
                0x81 => .mem_address,
                else => std.debug.panic("Unkown arg encoding byte: {d}\n", .{meta_byte}),
            };
        }

        fn getMetaByte(encoding: Encoding) u8 {
            return switch (encoding) {
                .immediate1 => 0,
                .immediate2 => 2,
                .immediate4 => 4,
                .byte_var => 1,
                .word_var => 3,
                .dword_var => 5,
                .string => 0x80,
                .mem_address => 0x81,
            };
        }
    };

    fn getEncoding(arg: Arg) Encoding {
        switch (arg) {
            .immediate => |val| {
                if (val <= std.math.maxInt(u8)) return .immediate1;
                if (val <= std.math.maxInt(u16)) return .immediate2;
                return .immediate4;
            },
            .byte_var => return .byte_var,
            .word_var => return .word_var,
            .dword_var => return .dword_var,
            .string => return .string,
            .mem_address => return .mem_address,
        }
    }
};

fn readCommand(reader: anytype, args: *std.ArrayList(Arg), address: u16) !Command {
    const args_start_index = args.items.len;
    const tag = try reader.readEnum(CommandTag, .little);

    switch (tag) {
        .ONGOTO, .ONGOSUB, .HMENU, .WHMENU, .TREASURE, .NEWREGION => {
            const arg0 = try readArg(reader);
            const arg1 = try readArg(reader);

            const num_varargs = if (tag == .NEWREGION) arg1.immediate * 4 else arg1.immediate;

            try args.ensureUnusedCapacity(2 + num_varargs);

            args.appendAssumeCapacity(arg0);
            args.appendAssumeCapacity(arg1);

            for (0..num_varargs) |_| {
                const a = try readArg(reader);
                args.appendAssumeCapacity(a);
            }
        },
        else => {
            try args.ensureUnusedCapacity(tag.getArgCount());
            for (0..tag.getArgCount()) |_| {
                const arg = try readArg(reader);
                args.appendAssumeCapacity(arg);
            }
        },
    }

    return Command{
        .tag = tag,
        .args = IndexSlice{
            .start = args_start_index,
            .len = args.items.len - args_start_index,
        },
        .address = address,
    };
}

fn readArg(reader: anytype) !Arg {
    const meta_byte = try reader.readByte();

    const encoding = Arg.Encoding.fromMetaByte(meta_byte);

    return switch (encoding) {
        .immediate1 => .{ .immediate = try reader.readByte() },
        .immediate2 => .{ .immediate = try reader.readInt(u16, .little) },
        .immediate4 => .{ .immediate = try reader.readInt(u32, .little) },
        .byte_var => .{ .var_use = .{
            .address = try reader.readInt(u16, .little),
            .var_type = .byte,
        } },
        .word_var => .{ .var_use = .{
            .address = try reader.readInt(u16, .little),
            .var_type = .word,
        } },
        .dword_var => .{ .var_use = .{
            .address = try reader.readInt(u16, .little),
            .var_type = .dword,
        } },
        .mem_address => .{ .var_use = .{
            .address = try reader.readInt(u16, .little),
            .var_type = .pointer,
        } },
        .string => .{ .string = try reader.readInt(u16, .little) },
    };
}

fn readJumpDestArg(reader: anytype) !Arg {
    const arg = try readArg(reader);
    if (arg != .var_use and arg.var_use.var_type != .byte) {
        return error.WrongArgEncoding;
    }

    return .{ .jump_dest_addr = arg.var_use.address };
}

const Var = struct {
    address: u16,
    type: VarType,
};

const VarMap = std.AutoHashMap(VarMapKey, []const u8);

pub const VarMapKey = struct {
    address: u16,
    type: VarType,
};

const InitializedDataSegment = struct {
    name: []const u8,
    bytes: []const u8,
};

const std = @import("std");

const ecl_base = 0x6af6;
const scratch_start_address = 0x9e6f;
const scratch_end_address = 0x9e79;

// game globals
// maybe window graphic to show 979b
// unknown bool 97a1
// land_type 97ad
// combat region 97dc
// last active level 97e8
// wall type 97f8
// for_loop_i 98ec
// player_y 9af6
// player_x 9af7
// player_room_id 9af9
// player_dir 9afa
// selected_character_status 9bf6 (maybe unused in sega version?)
// 10 bytes scratch_space 9e6f-9e79

pub const EclBinaryParseResult = struct {
    header: [5]u16,
    blocks: []const Block,
    commands: []const Command,
    args: []const Arg,
    init_data_segments: []const InitializedDataSegment,
    bytes_arena: std.heap.ArenaAllocator,
    var_map: std.AutoHashMapUnmanaged(VarMapKey, []const u8),
    text_bytes: []const u8,

    pub fn getBlockCommands(self: *const EclBinaryParseResult, block: Block) []const Command {
        const start = block.commands.start;
        const stop = start + block.commands.len;
        return self.commands[start..stop];
    }

    pub fn getCommandArgs(self: *const EclBinaryParseResult, command: Command) []const Arg {
        const start = command.args.start;
        const stop = start + command.args.len;
        return self.args[start..stop];
    }
};

pub fn parseEclBinaryAlloc(allocator: std.mem.Allocator, script_bytes: []const u8, text_bytes: []const u8) !EclBinaryParseResult {
    var bytes_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer bytes_arena.deinit();

    var var_map = VarMap{};
    errdefer var_map.deinit(allocator);

    var commands = std.ArrayListUnmanaged(Command){};
    defer commands.deinit(allocator);

    var args = std.ArrayListUnmanaged(Arg){};
    defer args.deinit(allocator);

    var init_data_segments = std.ArrayListUnmanaged(InitializedDataSegment){};
    defer init_data_segments.deinit(allocator);

    var init_data_refs = std.AutoArrayHashMapUnmanaged(u16, void){};
    defer init_data_refs.deinit(allocator);

    var jump_dests = std.AutoArrayHashMapUnmanaged(u16, void){};
    defer jump_dests.deinit(allocator);

    var script_fbs = std.io.fixedBufferStream(script_bytes);

    var header: [5]u16 = undefined;
    for (&header) |*address| {
        try script_fbs.seekBy(2);
        address.* = try script_fbs.reader().readInt(u16, .little);
        try jump_dests.put(allocator, address.*, {});
    }

    var highest_known_command_address = std.mem.max(u16, &header);
    var last_command_was_conditional = false;
    while (script_fbs.pos + ecl_base <= highest_known_command_address) {
        const command_address: u16 = @intCast(script_fbs.pos + ecl_base);
        const tag = try script_fbs.reader().readEnum(Command.Tag, .little);
        const args_start_index = args.items.len;

        switch (tag) {
            .ONGOTO, .ONGOSUB, .HMENU, .WHMENU, .TREASURE, .NEWREGION => {
                const arg0 = try readArg(script_fbs.reader());
                const arg1 = try readArg(script_fbs.reader());

                const num_varargs = if (tag == .NEWREGION) arg1.immediate * 4 else arg1.immediate;

                try args.ensureUnusedCapacity(allocator, 2 + num_varargs);

                args.appendAssumeCapacity(arg0);
                args.appendAssumeCapacity(arg1);

                for (0..num_varargs) |_| {
                    const a = try readArg(script_fbs.reader());
                    args.appendAssumeCapacity(a);
                }
            },
            else => {
                try args.ensureUnusedCapacity(allocator, tag.getArgCount());
                for (0..tag.getArgCount()) |_| {
                    const arg = try readArg(script_fbs.reader());
                    args.appendAssumeCapacity(arg);
                }
            },
        }

        const jump_args = switch (tag) {
            .GOTO, .GOSUB => args.items[args_start_index..],
            .ONGOTO, .ONGOSUB => args.items[args_start_index + 2 ..],
            else => &[0]Arg{},
        };
        for (jump_args) |arg| {
            const dest = arg.byte_var;
            try jump_dests.put(allocator, dest, {});
            highest_known_command_address = @max(dest, highest_known_command_address);
        }

        const possible_vars = switch (tag) {
            .GOTO, .GOSUB => &[0]Arg{},
            .ONGOTO, .ONGOSUB => args.items[args_start_index .. args_start_index + 2],
            else => args.items[args_start_index..],
        };
        for (possible_vars) |arg| {
            const address, const var_type = switch (arg) {
                .byte_var => |addr| .{ addr, Var.Type.byte },
                .word_var => |addr| .{ addr, Var.Type.word },
                .dword_var => |addr| .{ addr, Var.Type.dword },
                .mem_address => |addr| .{ addr, Var.Type.pointer },
                else => continue,
            };
            if (address >= ecl_base and address < script_bytes.len + ecl_base) {
                try init_data_refs.put(allocator, address, {});
                continue;
            }
            const gop = try var_map.getOrPut(allocator, VarMapKey{
                .address = address,
                .type = var_type,
            });
            if (gop.found_existing) continue;
            if (address >= scratch_start_address and address < scratch_end_address) {
                const offset = address - scratch_start_address;
                const var_name = try std.fmt.allocPrint(
                    bytes_arena.allocator(),
                    "scratch[{d}]{c}",
                    .{ offset, var_type.getLetter() },
                );
                gop.value_ptr.* = var_name;
            } else {
                const var_name = try std.fmt.allocPrint(
                    bytes_arena.allocator(),
                    "{c}var_{x:0>4}",
                    .{ var_type.getLetter(), address },
                );
                gop.value_ptr.* = var_name;
            }
        }

        try commands.append(allocator, Command{
            .tag = tag,
            .address = command_address,
            .args = IndexSlice{
                .start = args_start_index,
                .len = args.items.len - args_start_index,
            },
        });

        if (tag.isFallthrough() or last_command_was_conditional) {
            const next_command_address: u16 = @intCast(script_fbs.pos + ecl_base);
            highest_known_command_address = @max(next_command_address, highest_known_command_address);
        }

        last_command_was_conditional = tag.isConditional();
    }

    {
        const SortByAddress = struct {
            keys: []const u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };
        jump_dests.sortUnstable(SortByAddress{ .keys = jump_dests.keys() });
    }
    try var_map.ensureUnusedCapacity(allocator, @intCast(jump_dests.count()));
    for (jump_dests.keys(), 0..) |address, i| {
        const label = try std.fmt.allocPrint(
            bytes_arena.allocator(),
            "label{d}",
            .{i},
        );
        var_map.putAssumeCapacityNoClobber(
            .{ .address = address, .type = .byte },
            label,
        );
    }

    var blocks = try std.ArrayListUnmanaged(Block).initCapacity(allocator, jump_dests.count());
    errdefer blocks.deinit(allocator);
    std.debug.assert(jump_dests.count() >= 1);
    var command_i: usize = 0;
    for (0..jump_dests.count() - 1) |jump_dest_i| {
        const block_start_address = jump_dests.keys()[jump_dest_i];
        const block_end_address = jump_dests.keys()[jump_dest_i + 1];
        const commands_start = command_i;
        // find first command at or past the end address of this block
        const commands_end = while (command_i < commands.items.len) : (command_i += 1) {
            const cmd = commands.items[command_i];
            if (cmd.address >= block_end_address) break command_i;
        } else commands.items.len;
        blocks.appendAssumeCapacity(.{
            .address = block_start_address,
            .commands = IndexSlice{
                .start = commands_start,
                .len = commands_end - commands_start,
            },
        });
    }
    // final block is any remaining commands
    const last_block_start_address = jump_dests.keys()[jump_dests.count() - 1];
    blocks.appendAssumeCapacity(.{
        .address = last_block_start_address,
        .commands = IndexSlice{
            .start = command_i,
            .len = commands.items.len - command_i,
        },
    });

    {
        const SortByAddress = struct {
            keys: []const u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };
        init_data_refs.sortUnstable(SortByAddress{ .keys = init_data_refs.keys() });
    }

    try init_data_segments.ensureUnusedCapacity(allocator, init_data_refs.count());
    for (0..init_data_refs.count()) |i| {
        const start_address = init_data_refs.keys()[i];
        const end_address = if (i < init_data_refs.count() - 1) init_data_refs.keys()[i + 1] else script_bytes.len + ecl_base;

        const name = try std.fmt.allocPrint(
            bytes_arena.allocator(),
            "init_data{d}",
            .{i},
        );
        try var_map.putNoClobber(
            allocator,
            VarMapKey{ .address = start_address, .type = .byte },
            name,
        );

        const start = start_address - ecl_base;
        const end = end_address - ecl_base;
        const duped_bytes = try bytes_arena.allocator().dupe(u8, script_bytes[start..end]);
        init_data_segments.appendAssumeCapacity(.{
            .name = name,
            .bytes = duped_bytes,
        });
    }

    const result = EclBinaryParseResult{
        .header = header,
        .blocks = try blocks.toOwnedSlice(allocator),
        .commands = try commands.toOwnedSlice(allocator),
        .args = try args.toOwnedSlice(allocator),
        .init_data_segments = try init_data_segments.toOwnedSlice(allocator),
        .bytes_arena = bytes_arena,
        .var_map = var_map,
        .text_bytes = try allocator.dupe(u8, text_bytes),
    };

    errdefer allocator.free(result.blocks);
    errdefer allocator.free(result.commands);
    errdefer allocator.free(result.args);
    errdefer allocator.free(result.init_data_segments);
    errdefer allocator.free(result.text_bytes);

    return result;
}

pub fn freeEclBinaryParseResult(allocator: std.mem.Allocator, parse_result: *EclBinaryParseResult) void {
    allocator.free(parse_result.blocks);
    allocator.free(parse_result.commands);
    allocator.free(parse_result.args);
    allocator.free(parse_result.init_data_segments);
    parse_result.bytes_arena.deinit();
    parse_result.var_map.deinit(allocator);
    allocator.free(parse_result.text_bytes);
}

const IndexSlice = struct {
    start: usize,
    len: usize,
};

const Block = struct {
    address: u16,
    commands: IndexSlice,
};
pub const Command = struct {
    tag: Tag,
    address: u16,
    args: IndexSlice,

    const Tag = enum(u8) {
        EXIT,
        GOTO,
        GOSUB,
        COMPARE,
        ADD,
        SUBTRACT,
        DIVIDE,
        MULTIPLY,
        RANDOM,
        SAVE,
        LOADCHARACTER,
        LOADMONSTER,
        SETUPMONSTERS,
        APPROACH,
        PICTURE,
        INPUTNUMBER,
        INPUTSTRING,
        PRINT,
        PRINTCLEAR,
        RETURN,
        COMPAREAND,
        MENU,
        IFEQ,
        IFNE,
        IFLT,
        IFGT,
        IFLE,
        IFGE,
        CLEARMONSTERS,
        SETTIMER,
        CHECKPARTY,
        SPACECOMBAT,
        NEWECL,
        LOADFILES,
        SKILL,
        PRINTSKILL,
        COMBAT,
        ONGOTO,
        ONGOSUB,
        TREASURE,
        ROB,
        CONTINUE,
        GETABLE,
        HMENU,
        GETYN,
        DRAWINDOW,
        DAMAGE,
        AND,
        OR,
        WHMENU,
        FINDITEM,
        PRINTRETURN,
        CLOCK,
        SAVETABLE,
        ADDNPC,
        LOADPIECES,
        PROGRAM,
        WHO,
        DELAY,
        SPELLS,
        PROTECT,
        CLEARBOX,
        DUMP,
        JOURNAL,
        DESTROY,
        ADDEP,
        ENCEXIT,
        SOUND,
        SAVECHARACTER,
        HOWFAR,
        FOR,
        ENDFOR,
        HIDEITEMS,
        SKILLDAMAGE,
        DUEL,
        STORE,
        VIEW,
        ANIMATE,
        STAIRCASE,
        HALFSTEP,
        STEPFORWARD,
        PALETTE,
        UNLOCKDOOR,
        ADDFIGURE,
        ADDCORPSE,
        ADDFIGURE2,
        ADDCORPSE2,
        UPDATEFRAME,
        REMOVEFIGURE,
        EXPLOSION,
        STEPBACK,
        HALFBACK,
        NEWREGION,
        ICONMENU,

        const count = @typeInfo(@This()).Enum.fields.len;

        fn isConditional(tag: Tag) bool {
            return switch (tag) {
                .IFEQ, .IFNE, .IFLT, .IFGT, .IFLE, .IFGE => true,
                else => false,
            };
        }

        fn isFallthrough(tag: Tag) bool {
            return switch (tag) {
                .EXIT, .GOTO, .RETURN, .ENCEXIT => false,
                else => true,
            };
        }

        fn getArgCount(command_tag: Tag) u8 {
            return switch (command_tag) {
                .EXIT => 0x00,
                .GOTO => 0x01,
                .GOSUB => 0x01,
                .COMPARE => 0x02,
                .ADD => 0x03,
                .SUBTRACT => 0x03,
                .DIVIDE => 0x03,
                .MULTIPLY => 0x03,
                .RANDOM => 0x02,
                .SAVE => 0x02,
                .LOADCHARACTER => 0x01,
                .LOADMONSTER => 0x03,
                .SETUPMONSTERS => 0x04,
                .APPROACH => 0x00,
                .PICTURE => 0x01,
                .INPUTNUMBER => 0x02,
                .INPUTSTRING => 0x03, // NOTE: changed from 2 (this command is also not supported in genesis)
                .PRINT => 0x01,
                .PRINTCLEAR => 0x01,
                .RETURN => 0x00,
                .COMPAREAND => 0x04,
                .MENU => 0x00,
                .IFEQ => 0x00,
                .IFNE => 0x00,
                .IFLT => 0x00,
                .IFGT => 0x00,
                .IFLE => 0x00,
                .IFGE => 0x00,
                .CLEARMONSTERS => 0x00,
                .SETTIMER => 0x02,
                .CHECKPARTY => 0x06,
                .SPACECOMBAT => 0x04, // NOTE: changed from 2
                .NEWECL => 0x01,
                .LOADFILES => 0x03,
                .SKILL => 0x03,
                .PRINTSKILL => 0x03,
                .COMBAT => 0x00,
                .ONGOTO => 0x00,
                .ONGOSUB => 0x02,
                .TREASURE => 0x00,
                .ROB => 0x03,
                .CONTINUE => 0x00,
                .GETABLE => 0x03,
                .HMENU => 0x00,
                .GETYN => 0x00,
                .DRAWINDOW => 0x00,
                .DAMAGE => 0x05,
                .AND => 0x03,
                .OR => 0x03,
                .WHMENU => 0x00,
                .FINDITEM => 0x01,
                .PRINTRETURN => 0x00,
                .CLOCK => 0x01,
                .SAVETABLE => 0x03,
                .ADDNPC => 0x02, // NOTE: changed from 1
                .LOADPIECES => 0x01,
                .PROGRAM => 0x01,
                .WHO => 0x01,
                .DELAY => 0x00,
                .SPELLS => 0x03,
                .PROTECT => 0x01,
                .CLEARBOX => 0x00,
                .DUMP => 0x00,
                .JOURNAL => 0x02,
                .DESTROY => 0x02,
                .ADDEP => 0x02,
                .ENCEXIT => 0x00,
                .SOUND => 0x01,
                .SAVECHARACTER => 0x00,
                .HOWFAR => 0x02,
                .FOR => 0x02,
                .ENDFOR => 0x00,
                .HIDEITEMS => 0x01,
                .SKILLDAMAGE => 0x06,
                .DUEL => 0x00,
                .STORE => 0x01,
                .VIEW => 0x02,
                .ANIMATE => 0x00,
                .STAIRCASE => 0x00,
                .HALFSTEP => 0x00,
                .STEPFORWARD => 0x00,
                .PALETTE => 0x01,
                .UNLOCKDOOR => 0x00,
                .ADDFIGURE => 0x04,
                .ADDCORPSE => 0x03,
                .ADDFIGURE2 => 0x04,
                .ADDCORPSE2 => 0x03,
                .UPDATEFRAME => 0x01,
                .REMOVEFIGURE => 0x00,
                .EXPLOSION => 0x01,
                .STEPBACK => 0x00,
                .HALFBACK => 0x00,
                .NEWREGION => 0x00,
                .ICONMENU => 0x00,
            };
        }
    };
};

const Arg = union(enum) {
    immediate: u32,
    byte_var: u16,
    word_var: u16,
    dword_var: u16,
    string: u16,
    mem_address: u16,

    const Encoding = enum {
        immediate1,
        immediate2,
        immediate4,
        byte_var,
        word_var,
        dword_var,
        string,
        mem_address,

        fn fromMetaByte(meta_byte: i8) Encoding {
            return switch (meta_byte) {
                0 => .immediate1,
                2 => .immediate2,
                4 => .immediate4,
                1 => .byte_var,
                3 => .word_var,
                5 => .dword_var,
                -0x80 => .string,
                -0x7f => .mem_address,
                else => unreachable,
            };
        }
    };
};

fn readArg(reader: anytype) !Arg {
    const meta_byte = try reader.readByteSigned();

    const encoding = Arg.Encoding.fromMetaByte(meta_byte);

    const result: Arg = switch (encoding) {
        .immediate1 => .{ .immediate = try reader.readByte() },
        .immediate2 => .{ .immediate = try reader.readInt(u16, .little) },
        .immediate4 => .{ .immediate = try reader.readInt(u32, .little) },
        .byte_var => .{ .byte_var = try reader.readInt(u16, .little) },
        .word_var => .{ .word_var = try reader.readInt(u16, .little) },
        .dword_var => .{ .dword_var = try reader.readInt(u16, .little) },
        .string => .{ .string = try reader.readInt(u16, .little) },
        .mem_address => .{ .mem_address = try reader.readInt(u16, .little) },
    };

    return result;
}

const Var = struct {
    address: u16,
    type: Type,
    name: []const u8,

    const Type = enum {
        byte,
        word,
        dword,
        pointer,

        fn getLetter(self: Type) u8 {
            return switch (self) {
                .byte => 'b',
                .word => 'w',
                .dword => 'd',
                .pointer => 'p',
            };
        }
    };
};

const VarMap = std.AutoHashMapUnmanaged(VarMapKey, []const u8);

pub const VarMapKey = struct {
    address: u16,
    type: Var.Type,
};

const InitializedDataSegment = struct {
    name: []const u8,
    bytes: []const u8,
};

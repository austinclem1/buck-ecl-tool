const std = @import("std");

const ecl_base = 0x6af6;
const header_size = 20;
var encountered_string_offsets: std.AutoHashMap(u16, void) = undefined;

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
// 10 bytes scratch_space 9e6f-9e78 (inclusive)

const IndexSlice = struct {
    start: u16,
    stop: u16,

    fn getLen(s: IndexSlice) u16 {
        return s.stop - s.start;
    }
};

pub const CommandParser = struct {
    allocator: std.mem.Allocator,
    genesis_memory: []const u8,
    script: []const u8,
    text: []const u8,
    commands: std.ArrayList(Command),
    args: std.ArrayList(Arg),
    vars: ArgMap,
    labels: AddressArraySet,
    strings: std.ArrayList(String),
    initialized_bytes: ?[]const u8,
    highest_known_command_address: u16,

    const BranchQueue = std.fifo.LinearFifo(u16, .Dynamic);
    const ArgMap = std.AutoArrayHashMap(u16, VarType);
    const AddressArraySet = std.AutoArrayHashMap(u16, void);
    const AddressSet = std.AutoHashMap(u16, void);

    pub const VarType = enum {
        byte,
        word,
        dword,
    };

    const header_address = 0x6af6;

    pub fn ensureStringArgsAccountedFor(self: *const CommandParser) !void {
        for (self.commands.items) |cmd| {
            for (self.getCommandArgs(cmd)) |arg| {
                switch (arg) {
                    .string => |offset| {
                        for (self.strings.items) |str| {
                            if (offset == str.offset) break;
                        } else {
                            std.debug.print("{x}\n", .{offset});
                            return error.StringOffsetNotFound;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    pub fn sortVarsByAddress(self: *CommandParser) void {
        const C = struct {
            keys: []u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };

        self.vars.sort(C{ .keys = self.vars.keys() });
    }

    pub fn sortLabelsByAddress(self: *CommandParser) void {
        const C = struct {
            keys: []u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };

        self.labels.sort(C{ .keys = self.labels.keys() });
    }

    pub fn init(allocator: std.mem.Allocator, script_bytes: []const u8, text_bytes: []const u8) !CommandParser {
        var genesis_memory = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(genesis_memory);

        const script_end = ecl_base + script_bytes.len;
        const text_end = script_end + text_bytes.len;
        @memcpy(genesis_memory[ecl_base..script_end], script_bytes);
        @memcpy(genesis_memory[script_end..text_end], text_bytes);

        const commands = std.ArrayList(Command).init(allocator);
        const args = std.ArrayList(Arg).init(allocator);
        const vars = ArgMap.init(allocator);
        const labels = AddressArraySet.init(allocator);
        const strings = std.ArrayList(String).init(allocator);

        encountered_string_offsets = std.AutoHashMap(u16, void).init(allocator);

        return .{
            .allocator = allocator,
            .genesis_memory = genesis_memory,
            .script = genesis_memory[ecl_base..script_end],
            .text = genesis_memory[script_end..text_end],
            .commands = commands,
            .args = args,
            .vars = vars,
            .labels = labels,
            .strings = strings,
            .initialized_bytes = null,
            .highest_known_command_address = 0,
        };
    }

    pub fn deinit(self: *CommandParser) void {
        self.allocator.free(self.genesis_memory);
        self.commands.deinit();
        self.args.deinit();
        self.vars.deinit();
        self.labels.deinit();
        self.strings.deinit();
        encountered_string_offsets.deinit();
    }

    const String = struct {
        bytes: []const u8,
        offset: u16,
    };

    const CommandBlock = struct {
        start_addr: u16,
        end_addr: u16,
        commands: IndexSlice,

        pub fn lessThan(context: void, a: CommandBlock, b: CommandBlock) bool {
            _ = context;
            return a.start_addr < b.start_addr;
        }
    };

    pub fn readStrings(self: *CommandParser, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const slice = std.mem.sliceTo(text[i..], '\x00');
            try self.strings.append(String{
                .bytes = slice,
                .offset = @intCast(i),
            });
            i += slice.len + 1;
        }
    }

    // variables must be sorted by address for this to work
    pub fn detectVariableAliasing(self: *const CommandParser) void {
        var it = self.vars.iterator();

        var prev_var = it.next() orelse return;

        while (it.next()) |cur_var| : (prev_var = cur_var) {
            const prev_address = prev_var.key_ptr.*;
            const prev_size: u16 = switch (prev_var.value_ptr.*) {
                .byte => 1,
                .word => 2,
                .dword => 4,
            };

            const cur_address = cur_var.key_ptr.*;

            if (cur_address < prev_address + prev_size) {
                std.debug.print("alias detected: {x}: {s}, {x}: {s}\n", .{ prev_address, @tagName(prev_var.value_ptr.*), cur_address, @tagName(cur_var.value_ptr.*) });
                // return error.VariablesAlias;
            }
        }
    }

    pub fn getBlockCommands(self: *const CommandParser, block: CommandBlock) []Command {
        return self.commands.items[block.commands.start..block.commands.stop];
    }

    pub fn getCommandArgs(self: *const CommandParser, cmd: Command) []Arg {
        return self.args.items[cmd.args.start..cmd.args.stop];
    }

    pub fn parseEcl(self: *CommandParser) !void {
        try self.readStrings(self.text);

        const ecl_header = parseEclHeader(self.genesis_memory[ecl_base .. ecl_base + header_size]);

        try self.addLabelAndTrackHighestAddress(ecl_header.a);
        try self.addLabelAndTrackHighestAddress(ecl_header.b);
        try self.addLabelAndTrackHighestAddress(ecl_header.c);
        try self.addLabelAndTrackHighestAddress(ecl_header.d);
        try self.addLabelAndTrackHighestAddress(ecl_header.first_command_address);

        var cur_addr: u16 = ecl_base + header_size;
        while (cur_addr <= self.highest_known_command_address) {
            std.debug.assert(self.highest_known_command_address <= ecl_base + self.script.len);
            const cmd_size = try self.parseCommand(cur_addr);

            const cmd = self.commands.getLast();
            try self.trackCommandLabels(cmd);
            try self.trackCommandVars(cmd);

            switch (cmd.tag.getFlowType()) {
                .fallthrough => {
                    cur_addr += cmd_size;
                    self.highest_known_command_address = @max(cur_addr, self.highest_known_command_address);
                },
                .conditional => {
                    const next_cmd_address = cur_addr + cmd_size;
                    const next_cmd_size = try self.parseCommand(next_cmd_address);

                    const next_cmd = self.commands.getLast();
                    try self.trackCommandLabels(next_cmd);
                    try self.trackCommandVars(next_cmd);

                    cur_addr = next_cmd_address + next_cmd_size;
                    self.highest_known_command_address = @max(cur_addr, self.highest_known_command_address);
                },
                .terminal => {
                    cur_addr += cmd_size;
                },
            }
        }

        const cur_script_offset = cur_addr - ecl_base;
        if (cur_script_offset < self.script.len) {
            self.initialized_bytes = self.script[cur_script_offset..];
        }
    }

    fn parseEclHeader(header_bytes: []const u8) EclHeader {
        return .{
            .a = std.mem.readInt(u16, header_bytes[2..4], .little),
            .b = std.mem.readInt(u16, header_bytes[6..8], .little),
            .c = std.mem.readInt(u16, header_bytes[10..12], .little),
            .d = std.mem.readInt(u16, header_bytes[14..16], .little),
            .first_command_address = std.mem.readInt(u16, header_bytes[18..20], .little),
        };
    }

    fn addLabelAndTrackHighestAddress(self: *CommandParser, address: u16) !void {
        self.highest_known_command_address = @max(address, self.highest_known_command_address);
        try self.labels.put(address, {});
    }

    fn trackCommandLabels(self: *CommandParser, command: Command) !void {
        const args = self.getCommandArgs(command);

        switch (command.tag) {
            .ONGOTO, .ONGOSUB => {
                for (args[2..]) |arg| {
                    const address = try arg.getAddress();
                    try self.addLabelAndTrackHighestAddress(address);
                }
            },
            .GOTO, .GOSUB => {
                const address = try args[0].getAddress();
                try self.addLabelAndTrackHighestAddress(address);
            },
            else => {},
        }
    }

    fn trackCommandVars(self: *CommandParser, command: Command) !void {
        const args = self.getCommandArgs(command);

        switch (command.tag) {
            .GOTO, .GOSUB => {},
            .ONGOTO, .ONGOSUB => {
                // first 2 args could be vars, not any subsequent ones
                try self.trackArgIfVar(args[0], null);
                try self.trackArgIfVar(args[1], null);
            },
            else => {
                for (args) |arg| {
                    try self.trackArgIfVar(arg, null);
                }
            },
        }
    }

    fn trackArgIfVar(self: *CommandParser, arg: Arg, explicit_var_type: ?VarType) !void {
        const var_type = explicit_var_type orelse arg.maybeGetVarType() orelse return;
        const address = try arg.getAddress();
        const maybe_existing = try self.vars.fetchPut(address, var_type);
        if (maybe_existing) |existing_entry| {
            const existing_var_type = existing_entry.value;
            if (existing_var_type != var_type) {
                std.debug.print("var type mismatch for address {x}, existing: {s}, new: {s}\n", .{ address, @tagName(existing_var_type), @tagName(var_type) });
                //         return error.VariableTypeMismatch;
            }
        }
    }

    const ParseResult = struct {
        command: Command,
        end_address: u16,
    };

    fn parseCommand(self: *CommandParser, address: u16) !u16 {
        var fbs = std.io.fixedBufferStream(self.genesis_memory);
        try fbs.seekTo(address);

        const r = fbs.reader();

        const command_code = try r.readByte();
        if (command_code >= Command.Tag.count) {
            std.debug.print("error: invalid command code at address {x}\n", .{address});
            return error.InvalidCommandCode;
        }
        const tag: Command.Tag = @enumFromInt(command_code);

        const first_arg_index = self.args.items.len;

        switch (tag) {
            .ONGOTO, .ONGOSUB => {
                const branch_to_take = try readArg(r);
                const num_branches = try readArg(r);

                try self.args.append(branch_to_take);
                try self.args.append(num_branches);

                for (0..num_branches.immediate) |_| {
                    const arg = try readArg(r);
                    try self.args.append(arg);
                }
            },
            // first arg is where choices are located
            // second arg is num choices
            // rest are the choices
            .HMENU, .WHMENU => {
                const choices_base = try readArg(r);
                const num_choices = try readArg(r);

                try self.args.append(choices_base);
                try self.args.append(num_choices);

                for (0..num_choices.immediate) |_| {
                    const arg = try readArg(r);
                    try self.args.append(arg);
                }
            },
            .TREASURE => {
                const unknown1 = try readArg(r);
                const num_items = try readArg(r);

                try self.args.append(unknown1);
                try self.args.append(num_items);

                for (0..num_items.immediate) |_| {
                    const arg = try readArg(r);
                    try self.args.append(arg);
                }
            },
            .NEWREGION => {
                const unknown1 = try readArg(r);
                const num_tiles = try readArg(r);

                try self.args.append(unknown1);
                try self.args.append(num_tiles);

                for (0..num_tiles.immediate * 4) |_| {
                    const arg = try readArg(r);
                    try self.args.append(arg);
                }
            },
            else => {
                const arg_count = tag.getArgCount();
                for (0..arg_count) |_| {
                    const arg = try readArg(r);
                    try self.args.append(arg);
                }
            },
        }

        try self.commands.append(Command{
            .tag = tag,
            .args = IndexSlice{
                .start = @intCast(first_arg_index),
                .stop = @intCast(self.args.items.len),
            },
            .address = address,
        });
        return @intCast(fbs.pos - address);
    }

    const Arg = union(enum) {
        immediate: u32,
        indirect1: u16,
        indirect2: u16,
        indirect4: u16,
        string: u16,
        mem_address: u16,

        pub fn writeString(self: Arg, writer: anytype) !void {
            switch (self) {
                .immediate => |val| try writer.print("{x}", .{val}),
                .indirect1 => |addr| try writer.print("b@{x}", .{addr}),
                .indirect2 => |addr| try writer.print("w@{x}", .{addr}),
                .indirect4 => |addr| try writer.print("d@{x}", .{addr}),
                .string => |offset| try writer.print("str_{x}", .{offset}),
                .mem_address => |addr| try writer.print("mem[{x}]", .{addr}),
            }
        }

        fn getScalar(arg: Arg) !u32 {
            return switch (arg) {
                .immediate => |val| val,
                else => error.WrongArgType,
            };
        }

        fn getAddress(arg: Arg) !u16 {
            return switch (arg) {
                .indirect1, .indirect2, .indirect4, .string, .mem_address => |addr| addr,
                else => error.WrongArgType,
            };
        }

        fn maybeGetVarType(arg: Arg) ?VarType {
            return switch (arg) {
                .indirect1 => VarType.byte,
                .indirect2 => VarType.word,
                .indirect4 => VarType.dword,
                else => null,
            };
        }

        const Encoding = enum {
            immediate1,
            immediate2,
            immediate4,
            indirect1,
            indirect2,
            indirect4,
            string,
            mem_address,

            fn fromMetaByte(meta_byte: i8) Encoding {
                const even = @mod(meta_byte, 2) == 0;

                if (meta_byte == 0) return .immediate1;

                if (meta_byte == 4) return .immediate4;

                if (meta_byte > 0 and even) return .immediate2;

                if (meta_byte == -0x80) return .string;

                if (meta_byte < 0) return .mem_address;

                if (meta_byte == 1) return .indirect1;

                if (meta_byte == 3) return .indirect2;

                return .indirect4;
                // TODO see if these relaxed requirements can be more specific
                // i.e. instead of "any even positive" maybe it happens to always be 2 in practice
            }
        };
    };

    fn readArg(reader: anytype) !Arg {
        const meta_byte = try reader.readByteSigned();

        const arg_type = Arg.Encoding.fromMetaByte(meta_byte);
        // std.debug.print("{s} meta_byte {x}\n", .{ @tagName(arg_type), meta_byte });

        const result: Arg = switch (arg_type) {
            .immediate1 => .{ .immediate = try reader.readByte() },
            .immediate2 => .{ .immediate = try reader.readInt(u16, .little) },
            .immediate4 => .{ .immediate = try reader.readInt(u32, .little) },
            .indirect1 => .{ .indirect1 = try reader.readInt(u16, .little) },
            .indirect2 => .{ .indirect2 = try reader.readInt(u16, .little) },
            .indirect4 => .{ .indirect4 = try reader.readInt(u16, .little) },
            .string => .{ .string = try reader.readInt(u16, .little) },
            .mem_address => .{ .mem_address = try reader.readInt(u16, .little) },
        };

        return result;
    }
};

const EclHeader = struct {
    a: u16,
    b: u16,
    c: u16,
    d: u16,
    first_command_address: u16,
};

pub const Command = struct {
    tag: Tag,
    args: IndexSlice,
    address: u16,

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

        fn getFlowType(command_tag: Tag) FlowType {
            return switch (command_tag) {
                .EXIT, .GOTO, .RETURN, .ENCEXIT => .terminal,
                .IFEQ, .IFNE, .IFLT, .IFGT, .IFLE, .IFGE => .conditional,
                else => .fallthrough,
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
                .ONGOTO => 0x02, // NOTE: I changed this from 0
                .ONGOSUB => 0x02,
                .TREASURE => 0x02, // NOTE: changed from 0
                .ROB => 0x03,
                .CONTINUE => 0x00,
                .GETABLE => 0x03,
                .HMENU => 0x02, // NOTE: changed from 0
                .GETYN => 0x00,
                .DRAWINDOW => 0x00,
                .DAMAGE => 0x05,
                .AND => 0x03,
                .OR => 0x03,
                .WHMENU => 0x02, // NOTE: changed from 0
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

    const FlowType = enum {
        fallthrough,
        conditional,
        terminal,
    };
};

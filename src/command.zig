const std = @import("std");

pub const CommandParser = struct {
    allocator: std.mem.Allocator,
    genesis_memory: []const u8,
    branch_queue: BranchQueue,
    blocks: std.ArrayList(CommandBlock),
    commands: std.ArrayList(Command),
    args: std.ArrayList(Arg),
    vars: ArgMap,
    visited_branches: AddressSet,

    const BranchQueue = std.fifo.LinearFifo(u16, .Dynamic);
    const ArgMap = std.AutoArrayHashMap(u16, VarType);
    const AddressSet = std.AutoHashMap(u16, void);

    pub const VarType = enum {
        byte,
        word,
        dword,
    };

    const header_address = 0x6af6;

    pub fn sortVarsByAddress(self: *CommandParser) void {
        const C = struct {
            keys: []u16,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[a_index] < ctx.keys[b_index];
            }
        };

        self.vars.sort(C{ .keys = self.vars.keys() });
    }

    pub fn init(allocator: std.mem.Allocator, genesis_memory: []const u8) CommandParser {
        const branch_queue = BranchQueue.init(allocator);
        const blocks = std.ArrayList(CommandBlock).init(allocator);
        const commands = std.ArrayList(Command).init(allocator);
        const args = std.ArrayList(Arg).init(allocator);
        const vars = ArgMap.init(allocator);
        const visited_branches = AddressSet.init(allocator);

        return .{
            .allocator = allocator,
            .genesis_memory = genesis_memory,
            .branch_queue = branch_queue,
            .blocks = blocks,
            .commands = commands,
            .args = args,
            .vars = vars,
            .visited_branches = visited_branches,
        };
    }

    pub fn deinit(self: *CommandParser) void {
        self.branch_queue.deinit();
        self.blocks.deinit();
        self.commands.deinit();
        self.args.deinit();
        self.vars.deinit();
        self.visited_branches.deinit();
    }

    const CommandBlock = struct {
        start_addr: u16,
        end_addr: u16,
        commands_index: u16,
        commands_count: u16,

        pub fn lessThan(context: void, a: CommandBlock, b: CommandBlock) bool {
            _ = context;
            return a.start_addr < b.start_addr;
        }
    };

    pub fn getBlockCommands(self: *const CommandParser, block: CommandBlock) []Command {
        const start = block.commands_index;
        const end = start + block.commands_count;
        return self.commands.items[start..end];
    }

    pub fn getCommandArgs(self: *const CommandParser, command: Command) []Arg {
        const start = command.args_index;
        const end = start + command.args_count;
        return self.args.items[start..end];
    }

    pub fn parseCommandsRecursively(self: *CommandParser, start_address: u16) !void {
        try self.branch_queue.writeItem(start_address);

        while (self.branch_queue.readItem()) |block_start_addr| {
            const surrounding_blocks = self.getBlocksSurroundingAddress(block_start_addr);
            if (surrounding_blocks.left) |left_block| {
                if (block_start_addr < left_block.end_addr) {
                    std.debug.print("skipping parsing block at {x}, already included in block {x} - {x}\n", .{ block_start_addr, left_block.start_addr, left_block.end_addr });
                    continue; // already parsed these commands
                }
            }

            std.debug.print("parsing block at {x}\n", .{block_start_addr});

            const first_command_index = self.commands.items.len;

            var cur_addr = block_start_addr;
            block_loop: while (true) {
                if (surrounding_blocks.right) |right_block| {
                    if (cur_addr == right_block.start_addr) {
                        std.debug.print("while parsing block at {x} ran into existing block {x} - {x}\n", .{ block_start_addr, right_block.start_addr, right_block.end_addr });
                        // we've run into an existing block and must update it with any preceding commands

                        try self.commands.ensureUnusedCapacity(right_block.commands_count);
                        const start = right_block.commands_index;
                        const stop = start + right_block.commands_count;
                        const existing_commands = self.commands.items[start..stop];
                        self.commands.appendSliceAssumeCapacity(existing_commands);

                        right_block.start_addr = block_start_addr;
                        right_block.commands_index = @intCast(first_command_index);
                        right_block.commands_count = @intCast(self.commands.items[first_command_index..].len);
                        break :block_loop;
                    }
                }

                var parse_result: ParseResult = undefined;

                parse_result = try self.parseCommand(cur_addr);
                const cmd = parse_result.command;
                const cmd_end = parse_result.end_address;

                try self.commands.append(cmd);
                try self.queueCommandBranches(cmd);
                try self.trackUsedVars(cmd);

                switch (cmd.tag.getFlowType()) {
                    .fallthrough => {
                        cur_addr = cmd_end;
                    },
                    .conditional => {
                        parse_result = try self.parseCommand(cmd_end);
                        const conditional_cmd = parse_result.command;
                        const conditional_cmd_end = parse_result.end_address;

                        try self.commands.append(conditional_cmd);
                        try self.queueCommandBranches(conditional_cmd);
                        try self.trackUsedVars(conditional_cmd);

                        cur_addr = conditional_cmd_end;
                    },
                    .terminal => {
                        const new_block = CommandBlock{
                            .start_addr = block_start_addr,
                            .end_addr = cmd_end,
                            .commands_index = @intCast(first_command_index),
                            .commands_count = @intCast(self.commands.items[first_command_index..].len),
                        };
                        try self.blocks.append(new_block);
                        std.sort.insertion(CommandBlock, self.blocks.items, {}, CommandBlock.lessThan);
                        break :block_loop;
                    },
                }
            }
        }
    }

    fn getBlocksSurroundingAddress(self: *const CommandParser, address: u16) struct {
        left: ?*CommandBlock,
        right: ?*CommandBlock,
    } {
        var left_index: ?usize = null;
        for (self.blocks.items, 0..) |block, i| {
            if (block.start_addr > address) break;
            left_index = i;
        }

        var right_index: ?usize = if (left_index) |li| li + 1 else 0;
        if (right_index.? >= self.blocks.items.len) right_index = null;

        return .{
            .left = if (left_index) |li| &self.blocks.items[li] else null,
            .right = if (right_index) |ri| &self.blocks.items[ri] else null,
        };
    }

    fn trackUsedVars(self: *CommandParser, command: Command) !void {
        const args = self.getCommandArgs(command);

        for (args) |arg| {
            const var_type = switch (arg) {
                .indirect1 => VarType.byte,
                .indirect2 => VarType.word,
                .indirect4 => VarType.dword,
                else => continue,
            };
            const addr = try arg.getAddress();
            const maybe_existing = try self.vars.fetchPut(addr, var_type);
            if (maybe_existing) |entry| {
                std.debug.assert(entry.value == var_type);
            }
        }
    }

    fn queueCommandBranches(self: *CommandParser, command: Command) !void {
        const command_args = self.getCommandArgs(command);

        switch (command.tag) {
            .ONGOTO, .ONGOSUB => {
                for (command_args[2..]) |arg| {
                    const addr = try arg.getAddress();
                    if (self.visited_branches.contains(addr)) continue;
                    try self.visited_branches.putNoClobber(addr, {});
                    try self.branch_queue.writeItem(addr);
                    std.debug.print("queued {x}\n", .{addr});
                }
            },
            .GOTO, .GOSUB => {
                const addr = try command_args[0].getAddress();
                if (self.visited_branches.contains(addr)) return;
                try self.visited_branches.putNoClobber(addr, {});
                try self.branch_queue.writeItem(addr);
                std.debug.print("queued {x}\n", .{addr});
            },
            else => {},
        }
    }

    const ParseResult = struct {
        command: Command,
        end_address: u16,
    };

    fn parseCommand(self: *CommandParser, address: u16) !ParseResult {
        var fbs = std.io.fixedBufferStream(self.genesis_memory);
        try fbs.seekTo(address);

        const r = fbs.reader();

        const command_code = try r.readByte();
        const tag: Command.Tag =
            if (command_code < Command.Tag.count) @enumFromInt(command_code) else return error.InvalidCommandCode;

        const first_arg_index = self.args.items.len;

        switch (tag) {
            .ONGOTO, .ONGOSUB => {
                const branch_to_take = try parseArg(r);
                const num_branches = try parseArg(r);

                try self.args.append(branch_to_take);
                try self.args.append(num_branches);

                for (0..num_branches.immediate) |_| {
                    const arg = try parseArg(r);
                    try self.args.append(arg);
                }
            },
            else => {
                const arg_count = tag.getArgCount();
                for (0..arg_count) |_| {
                    const arg = try parseArg(r);
                    try self.args.append(arg);
                }
            },
        }

        return ParseResult{
            .command = Command{
                .tag = tag,
                .args_index = @intCast(first_arg_index),
                .args_count = @intCast(self.args.items[first_arg_index..].len),
            },
            .end_address = @intCast(fbs.pos),
        };
    }

    pub fn parseEclHeader(self: *const CommandParser) EclHeader {
        const header_bytes = self.genesis_memory[header_address..];

        return .{
            .a = std.mem.readIntLittle(u16, header_bytes[2..4]),
            .b = std.mem.readIntLittle(u16, header_bytes[6..8]),
            .c = std.mem.readIntLittle(u16, header_bytes[10..12]),
            .d = std.mem.readIntLittle(u16, header_bytes[14..16]),
            .first_command_address = std.mem.readIntLittle(u16, header_bytes[18..20]),
        };
    }
};

const EclHeader = struct {
    a: u16,
    b: u16,
    c: u16,
    d: u16,
    first_command_address: u16,
};

const Arg = union(enum) {
    immediate: u32,
    indirect1: u16,
    indirect2: u16,
    indirect4: u16,
    level_text_offset: u16,
    mem_address: u16,

    pub fn writeString(self: Arg, writer: anytype) !void {
        switch (self) {
            .immediate => |val| try writer.print("{x}", .{val}),
            .indirect1 => |addr| try writer.print("b@{x}", .{addr}),
            .indirect2 => |addr| try writer.print("w@{x}", .{addr}),
            .indirect4 => |addr| try writer.print("d@{x}", .{addr}),
            .level_text_offset => |offset| try writer.print("text[{x}]", .{offset}),
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
            .indirect1, .indirect2, .indirect4, .level_text_offset, .mem_address => |addr| addr,
            else => error.WrongArgType,
        };
    }

    const Encoding = enum {
        immediate1,
        immediate2,
        immediate4,
        indirect1,
        indirect2,
        indirect4,
        level_text_offset,
        mem_address,

        fn fromMetaByte(meta_byte: i8) Encoding {
            const even = @mod(meta_byte, 2) == 0;

            if (meta_byte == 0) return .immediate1;

            if (meta_byte == 4) return .immediate4;

            if (meta_byte > 0 and even) return .immediate2;

            if (meta_byte == -0x80) return .level_text_offset;

            if (meta_byte < 0) return .mem_address;

            if (meta_byte == 1) return .indirect1;

            if (meta_byte == 3) return .indirect2;

            return .indirect4;
            // TODO see if these relaxed requirements can be more specific
            // i.e. instead of "any even positive" maybe it happens to always be 2 in practice
        }
    };
};

fn parseArg(reader: anytype) !Arg {
    const meta_byte = try reader.readByteSigned();

    const arg_type = Arg.Encoding.fromMetaByte(meta_byte);
    std.debug.print("{s} meta_byte {x}\n", .{ @tagName(arg_type), meta_byte });

    return switch (arg_type) {
        .immediate1 => .{ .immediate = try reader.readByte() },
        .immediate2 => .{ .immediate = try reader.readIntLittle(u16) },
        .immediate4 => .{ .immediate = try reader.readIntLittle(u32) },
        .indirect1 => .{ .indirect1 = try reader.readIntLittle(u16) },
        .indirect2 => .{ .indirect2 = try reader.readIntLittle(u16) },
        .indirect4 => .{ .indirect4 = try reader.readIntLittle(u16) },
        .level_text_offset => .{ .level_text_offset = try reader.readIntLittle(u16) },
        .mem_address => .{ .mem_address = try reader.readIntLittle(u16) },
    };
}

pub const Command = struct {
    tag: Tag,
    args_index: u16,
    args_count: u16,

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
                .EXIT, .GOTO, .RETURN, .ONGOTO => .terminal,
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
                .INPUTSTRING => 0x02,
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
                .SPACECOMBAT => 0x02,
                .NEWECL => 0x01,
                .LOADFILES => 0x03,
                .SKILL => 0x03,
                .PRINTSKILL => 0x03,
                .COMBAT => 0x00,
                .ONGOTO => 0x02, // NOTE: I changed this from 0 to 2
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
                .ADDNPC => 0x01,
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

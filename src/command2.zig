const std = @import("std");

// const ParseError = error{
//     InvalidCommandCode,
//     UnsupportedCommand,
// };

pub fn readCommandBinary(reader: anytype) !Command {
    const code = try reader.readByte();

    const tag: CommandTag = blk: {
        if (code >= Command.tag_count) return error.InvalidCommandCode;
        break :blk @enumFromInt(code);
    };

    std.debug.print("{}\n", .{tag});

    @setEvalBranchQuota(1000000);

    switch (tag) {
        .ONGOTO => {
            const arg1 = try expectScalar(reader);
            const arg_count = try expectScalar(reader);
            for (0..getScalarValue(arg_count)) |_| {
                _ = try readArgBinary(reader);
            }

            return .{ .ONGOTO = .{
                .arg1 = arg1,
                .arg_count = arg_count,
            } };
        },
        .LOADFILES => {
            const arg1 = try expectScalar(reader);
            if (getScalarValue(arg1) < 0x7f) {
                return .{ .LOADFILES = .{
                    .arg1 = arg1,
                    .arg2 = null,
                    .arg3 = null,
                } };
            } else {
                return .{ .LOADFILES = .{
                    .arg1 = arg1,
                    .arg2 = try readArgBinary(reader),
                    .arg3 = try readArgBinary(reader),
                } };
            }
        },
        inline else => |t| {
            const Payload = std.meta.TagPayload(Command, t);
            if (Payload == void) return t;
            var payload: Payload = undefined;
            inline for (std.meta.fields(Payload)) |field| {
                switch (field.type) {
                    Scalar => @field(payload, field.name) = try expectScalar(reader),
                    Address => @field(payload, field.name) = try expectAddress(reader),
                    Arg => @field(payload, field.name) = try readArgBinary(reader),
                    else => unreachable,
                }
            }
            return @unionInit(Command, @tagName(t), payload);
        },
    }
}

const Scalar = union(enum) {
    immediate: u32,
    indirect1: u16,
    indirect2: u16,
    indirect4: u16,
};

fn expectScalar(reader: anytype) !Scalar {
    const meta_byte = try reader.readByteSigned();
    const arg_type = parseArgMetaByte(meta_byte);

    return switch (arg_type) {
        .scalar1 => .{ .immediate = try reader.readByte() },
        .scalar2 => .{ .immediate = try reader.readIntLittle(u16) },
        .scalar4 => .{ .immediate = try reader.readIntLittle(u32) },
        .indirect_scalar1 => .{ .indirect1 = try reader.readIntLittle(u16) },
        .indirect_scalar2 => .{ .indirect2 = try reader.readIntLittle(u16) },
        .indirect_scalar4 => .{ .indirect4 = try reader.readIntLittle(u16) },
        else => error.WrongArgType,
    };
}

fn expectAddress(reader: anytype) !Address {
    const meta_byte = try reader.readByteSigned();
    const arg_type = parseArgMetaByte(meta_byte);

    return switch (arg_type) {
        .level_text_offset => .{ .text = try reader.readIntLittle(u16) },
        .mem_address => .{ .memory = try reader.readIntLittle(u16) },
        else => error.WrongArgType,
    };
}

const ArgEncoding = enum {
    scalar1,
    scalar2,
    scalar4,
    indirect_scalar1,
    indirect_scalar2,
    indirect_scalar4,
    level_text_offset,
    mem_address,
};

const Arg = union(enum) {
    scalar: u32,
    indirect_scalar1: u16,
    indirect_scalar2: u16,
    indirect_scalar4: u16,
    level_text_offset: u16,
    mem_address: u16,
};

fn readArgBinary(reader: anytype) !Arg {
    const meta_byte = try reader.readByteSigned();

    const arg_type = parseArgMetaByte(meta_byte);

    return switch (arg_type) {
        .scalar1 => .{ .scalar = try reader.readByte() },
        .scalar2 => .{ .scalar = try reader.readIntLittle(u16) },
        .scalar4 => .{ .scalar = try reader.readIntLittle(u32) },
        .indirect_scalar1 => .{ .indirect_scalar1 = try reader.readIntLittle(u16) },
        .indirect_scalar2 => .{ .indirect_scalar2 = try reader.readIntLittle(u16) },
        .indirect_scalar4 => .{ .indirect_scalar4 = try reader.readIntLittle(u16) },
        .level_text_offset => .{ .level_text_offset = try reader.readIntLittle(u16) },
        .mem_address => .{ .mem_address = try reader.readIntLittle(u16) },
    };
}

fn getScalarValue(s: Scalar) u32 {
    return switch (s) {
        .immediate => |v| v,
        .indirect1, .indirect2, .indirect4 => unreachable,
    };
}

fn parseArgMetaByte(meta_byte: i8) ArgEncoding {
    const even = @mod(meta_byte, 2) == 0;

    if (meta_byte == 0) return .scalar1;

    if (meta_byte == 4) return .scalar4;

    if (meta_byte > 0 and even) return .scalar2;

    if (meta_byte == 0x80) return .level_text_address;

    if (meta_byte < 0) return .mem_address;

    if (meta_byte == 1) return .indirect_scalar1;

    if (meta_byte == 3) return .indirect_scalar2;

    return .indirect_scalar4;
    // TODO see if these relaxed requirements can be more specific
    // i.e. instead of "any even positive" maybe it happens to always be 2 in practice

}

const CommandTag = std.meta.Tag(Command);

pub const Command = union(enum(u8)) {
    EXIT,
    GOTO: struct {
        dest: Scalar,
    },
    GOSUB: struct {
        dest: Scalar,
    },
    COMPARE: struct {
        lhs: Scalar,
        rhs: Scalar,
    },
    ADD: BinOp,
    SUBTRACT: BinOp,
    DIVIDE: BinOp,
    MULTIPLY: BinOp,
    RANDOM: struct {
        range: Scalar,
        dest: Scalar,
    },
    SAVE: struct {
        val: Scalar,
        dest: Scalar,
    },
    LOADCHARACTER,
    LOADMONSTER,
    SETUPMONSTERS,
    APPROACH,
    PICTURE,
    INPUTNUMBER,
    INPUTSTRING,
    PRINT: struct {
        arg: Arg,
    },
    PRINTCLEAR: struct {
        arg: Arg,
    },
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
    LOADFILES: struct {
        arg1: Scalar,
        arg2: ?Arg,
        arg3: ?Arg,
    },
    SKILL,
    PRINTSKILL,
    COMBAT,
    ONGOTO: struct {
        arg1: Scalar,
        arg_count: Scalar,
        // arg_list: []Arg,
    },
    ONGOSUB,
    TREASURE,
    ROB,
    CONTINUE,
    GETABLE,
    HMENU,
    GETYN,
    DRAWINDOW,
    DAMAGE,
    AND: BinOp,
    OR: BinOp,
    WHMENU,
    FINDITEM,
    PRINTRETURN,
    CLOCK,
    SAVETABLE,
    ADDNPC, // 2
    LOADPIECES, // 1
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
    SOUND: struct {
        sound_id: Scalar,
    },
    SAVECHARACTER,
    HOWFAR: struct {
        arg1: Address,
        arg2: Scalar,
    },
    FOR: struct {
        arg1: Scalar,
        arg2: Scalar,
    },
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

    const tag_count = @typeInfo(@This()).Union.fields.len;
};

// const Unknown1Arg = struct {
//     arg1: Arg,
// };
//
// const Unknown2Args = struct {
//     arg1: Arg,
//     arg2: Arg,
// };

const BinOp = struct {
    lhs: Scalar,
    rhs: Scalar,
    dest: Scalar,
};
// const BinOp = struct {
//     lhs: Scalar,
//     rhs: Scalar,
//     dest: Address,
// };

const Address = union(enum) {
    memory: u16,
    text: u16,
};

const command_arg_counts = [Command.tag_count]u8{
    0x00,
    0x01,
    0x01,
    0x02,
    0x03,
    0x03,
    0x03,
    0x03,
    0x02,
    0x02,
    0x01,
    0x03,
    0x04,
    0x00,
    0x01,
    0x02,
    0x02,
    0x01,
    0x01,
    0x00,
    0x04,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x02,
    0x06,
    0x02,
    0x01,
    0x03,
    0x03,
    0x03,
    0x00,
    0x00,
    0x02,
    0x00,
    0x03,
    0x00,
    0x03,
    0x00,
    0x00,
    0x00,
    0x05,
    0x03,
    0x03,
    0x00,
    0x01,
    0x00,
    0x01,
    0x03,
    0x01,
    0x01,
    0x01,
    0x01,
    0x00,
    0x03,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x02,
    0x00,
    0x01,
    0x00,
    0x02,
    0x02,
    0x00,
    0x01,
    0x06,
    0x00,
    0x01,
    0x02,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x04,
    0x03,
    0x04,
    0x03,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
};

pub fn printCommandNamesAndArgCount() void {
    for (0..Command.tag_count) |i| {
        std.debug.print("{x} {s} Args: {d}\n", .{ i, @tagName(@as(CommandTag, @enumFromInt(i))), command_arg_counts[i] });
    }
}

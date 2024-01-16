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

    return switch (tag) {
        .EXIT => Command.EXIT,
        .ADD => .{ .ADD = [3]Arg{
            try readArgBinary(reader),
            try readArgBinary(reader),
            try readArgBinary(reader),
        } },
        .SAVE => .{ .SAVE = [2]Arg{
            try readArgBinary(reader),
            try readArgBinary(reader),
        } },
        .SOUND => .{ .SOUND = try readArgBinary(reader) },
        .LOADFILES => .{ .LOADFILES = try readArgBinary(reader) },
        .AND => .{ .AND = [3]Arg{
            try readArgBinary(reader),
            try readArgBinary(reader),
            try readArgBinary(reader),
        } },
        else => error.UnsupportedCommand,
    };
}

const ArgParseError = error{
    WrongArgType,
};

const ArgType = enum {
    scalar_1,
    scalar_2,
    scalar_4,
    indirect_scalar_1,
    indirect_scalar_2,
    indirect_scalar_4,
    level_text_offset,
    mem_address,
};

const Arg = union(ArgType) {
    scalar_1: u8,
    scalar_2: u16,
    scalar_4: u32,
    indirect_scalar_1: u16,
    indirect_scalar_2: u16,
    indirect_scalar_4: u16,
    level_text_offset: u16,
    mem_address: u16,
};

fn readArgBinary(reader: anytype) !Arg {
    const meta_byte = try reader.readByteSigned();

    const arg_type = parseArgMetaByte(meta_byte);

    return switch (arg_type) {
        .scalar_1 => .{ .scalar_1 = try reader.readByte() },
        .scalar_2 => .{ .scalar_2 = try reader.readIntLittle(u16) },
        .scalar_4 => .{ .scalar_4 = try reader.readIntLittle(u32) },
        .indirect_scalar_1 => .{ .indirect_scalar_1 = try reader.readIntLittle(u16) },
        .indirect_scalar_2 => .{ .indirect_scalar_2 = try reader.readIntLittle(u16) },
        .indirect_scalar_4 => .{ .indirect_scalar_4 = try reader.readIntLittle(u16) },
        .level_text_offset => .{ .level_text_offset = try reader.readIntLittle(u16) },
        .mem_address => .{ .mem_address = try reader.readIntLittle(u16) },
    };
}

fn parseArgMetaByte(meta_byte: i8) ArgType {
    const even = @mod(meta_byte, 2) == 0;

    if (meta_byte == 0) return .scalar_1;

    if (meta_byte == 4) return .scalar_4;

    if (meta_byte > 0 and even) return .scalar_2;

    if (meta_byte == 0x80) return .level_text_address;

    if (meta_byte < 0) return .mem_address;

    if (meta_byte == 1) return .indirect_scalar_1;

    if (meta_byte == 3) return .indirect_scalar_2;

    return .indirect_scalar_4;
    // TODO see if these relaxed requirements can be more specific
    // i.e. instead of "any even positive" maybe it happens to always be 2 in practice

}

const CommandTag = std.meta.Tag(Command);

pub const Command = union(enum(u8)) {
    EXIT,
    GOTO,
    GOSUB,
    COMPARE,
    ADD: [3]Arg,
    SUBTRACT: [3]Arg,
    DIVIDE: [3]Arg,
    MULTIPLY: [3]Arg,
    RANDOM,
    SAVE: [2]Arg,
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
    LOADFILES: Arg,
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
    AND: [3]Arg,
    OR,
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
    SOUND: Arg,
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

    const tag_count = @typeInfo(@This()).Union.fields.len;
};

const BinOp = struct {
    lhs: Scalar,
    rhs: Scalar,
    dest: Address,
};

const Scalar = u32;
const Address = union(enum) {
    memory: u16,
    text: u16,
};

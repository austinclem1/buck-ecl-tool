const VarType = @import("VarType.zig").VarType;

// name, type, and address tuples
pub const vars = [_]struct { []const u8, VarType, u16 }{
    .{ "land_type", .byte, 0x97ad },
    .{ "combat_region", .byte, 0x97dc },
    .{ "current_level_id", .byte, 0x97e8 },
    .{ "scratch1", .pointer, 0x97f6 },
    .{ "for_i", .byte, 0x98ec },
    .{ "player_y", .byte, 0x9af6 },
    .{ "player_x", .byte, 0x9af7 },
    .{ "player_room_id", .byte, 0x9af9 },
    .{ "player_dir", .byte, 0x9afa },
    .{ "ptr_9afc", .pointer, 0x9afc },
    .{ "bool_training_party", .byte, 0x9d9e },
    .{ "scratch2", .pointer, 0x9e6f },
    .{ "bvar_9eec", .byte, 0x9eec },
};

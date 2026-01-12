const VarType = @import("VarType.zig").VarType;

// name, type, and address tuples
pub const known_vars = [_]KnownVar{
    .{ .name = "land_type", .var_type = .byte, .address = 0x97ad },
    .{ .name = "combat_region", .var_type = .byte, .address = 0x97dc },
    .{ .name = "current_level_id", .var_type = .byte, .address = 0x97e8 },
    .{ .name = "scratch1", .var_type = .pointer, .address = 0x97f6 },
    .{ .name = "for_i", .var_type = .byte, .address = 0x98ec },
    .{ .name = "player_y", .var_type = .byte, .address = 0x9af6 },
    .{ .name = "player_x", .var_type = .byte, .address = 0x9af7 },
    .{ .name = "player_room_id", .var_type = .byte, .address = 0x9af9 },
    .{ .name = "player_dir", .var_type = .byte, .address = 0x9afa },
    .{ .name = "ptr_9afc", .var_type = .pointer, .address = 0x9afc },
    .{ .name = "bool_training_party", .var_type = .byte, .address = 0x9d9e },
    .{ .name = "scratch2", .var_type = .pointer, .address = 0x9e6f },
    .{ .name = "bvar_9eec", .var_type = .byte, .address = 0x9eec },
};

const KnownVar = struct {
    address: u16,
    var_type: VarType,
    name: []const u8,
};

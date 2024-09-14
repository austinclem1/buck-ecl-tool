const std = @import("std");

const File = std.fs.File;

pub const Ast = @import("ecl/Ast.zig");

pub const binary_parser = @import("ecl/binary_parser.zig");
pub const TextParser = @import("ecl/TextParser.zig");

pub const level_ids = [_]u8{ 0x00, 0x01, 0x03, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x34, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63 };

const script_offsets_table_addr = 0x38d02;
const scripts_section_end_addr = 0x42b0a;

const text_offsets_table_addr = 0x42b2a;
const text_section_end_addr = 0x51102;

pub fn fileReadCompressedScriptAlloc(allocator: std.mem.Allocator, rom_file: File, level_id: u8) ![]const u8 {
    const start_addr, const end_addr = try getScriptAddrs(rom_file, level_id);

    const script_len = end_addr - start_addr;
    const buffer = try allocator.alloc(u8, script_len);
    errdefer allocator.free(buffer);

    try rom_file.seekTo(start_addr);
    _ = try rom_file.readAll(buffer);

    return buffer;
}

pub fn getScriptAddrs(rom_file: File, level_id: u8) !struct { u32, u32 } {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(script_offsets_table_addr + level_index * 4);
    const start_addr = try rom_file.reader().readInt(u32, .big) + script_offsets_table_addr;
    const end_addr = blk: {
        if (level_index == level_ids.len - 1) {
            break :blk scripts_section_end_addr;
        } else {
            const offset = try rom_file.reader().readInt(u32, .big);
            break :blk script_offsets_table_addr + offset;
        }
    };

    return .{ start_addr, end_addr };
}

pub fn fileReadCompressedTextAlloc(allocator: std.mem.Allocator, rom_file: File, level_id: u8) ![]const u8 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(text_offsets_table_addr + level_index * 4);
    const start_addr, const end_addr = try getTextAddrs(rom_file, level_id);

    const text_len = end_addr - start_addr;
    const buffer = try allocator.alloc(u8, text_len);
    errdefer allocator.free(buffer);

    try rom_file.seekTo(start_addr);
    _ = try rom_file.readAll(buffer);

    return buffer;
}

pub fn getTextAddrs(rom_file: File, level_id: u8) !struct { u32, u32 } {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(text_offsets_table_addr + level_index * 4);
    const start_addr = try rom_file.reader().readInt(u32, .big) + text_offsets_table_addr;
    const end_addr = blk: {
        if (level_index == level_ids.len - 1) {
            break :blk text_section_end_addr;
        } else {
            const offset = try rom_file.reader().readInt(u32, .big);
            break :blk text_offsets_table_addr + offset;
        }
    };

    return .{ start_addr, end_addr };
}

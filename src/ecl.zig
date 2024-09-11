const std = @import("std");

const File = std.fs.File;

pub const binary_parser = @import("ecl/binary_parser.zig");
pub const TextParser = @import("ecl/TextParser.zig");

pub const level_ids = [_]u8{ 0x00, 0x01, 0x03, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x34, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63 };

const compressedScriptsTableAddr = 0x38d02;
const compressedTextTableAddr = 0x42b2a;

pub fn getCompressedScriptAddress(rom_file: File, id: u8) !u32 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(compressedScriptsTableAddr + level_index * 4);
    const offset = try rom_file.reader().readInt(u32, .big);

    return compressedScriptsTableAddr + offset;
}

pub fn getCompressedTextAddress(rom_file: File, id: u8) !u32 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(compressedTextTableAddr + level_index * 4);
    const offset = try rom_file.reader().readInt(u32, .big);

    return compressedTextTableAddr + offset;
}

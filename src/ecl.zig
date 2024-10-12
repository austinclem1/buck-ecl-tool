const std = @import("std");

pub const Ast = @import("ecl/Ast.zig");

pub const binary_parser = @import("ecl/binary_parser.zig");
pub const TextParser = @import("ecl/TextParser.zig");

// TODO maybe we can make an enum for identifying levels
pub const level_ids = [_]u8{ 0x00, 0x01, 0x03, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x34, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63 };

const script_offsets_table_addr = 0x38d02;
const scripts_section_end_addr = 0x42b0a;

const text_offsets_table_addr = 0x42b2a;
const text_section_end_addr = 0x51102;

const CompressedLevelReadError = error{
    LevelIdNotFound,
    ReadFailed,
    OutOfMemory,
};

pub fn readCompressedScriptAlloc(allocator: std.mem.Allocator, seekable_stream: anytype, level_id: u8) CompressedLevelReadError![]const u8 {
    const start_addr, const end_addr = try getScriptAddrs(seekable_stream, level_id);

    const script_len = end_addr - start_addr;
    const buffer = try allocator.alloc(u8, script_len);
    errdefer allocator.free(buffer);

    seekable_stream.seekTo(start_addr) catch return error.ReadFailed;
    const bytes_read = seekable_stream.context.reader().readAll(buffer) catch return error.ReadFailed;
    std.debug.assert(bytes_read == script_len);

    return buffer;
}

pub fn getScriptAddrs(seekable_stream: anytype, level_id: u8) CompressedLevelReadError!struct { u32, u32 } {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    seekable_stream.seekTo(script_offsets_table_addr + level_index * 4) catch return error.ReadFailed;
    const start_addr = blk: {
        const offset = seekable_stream.context.reader().readInt(u32, .big) catch return error.ReadFailed;
        break :blk script_offsets_table_addr + offset;
    };
    const end_addr = blk: {
        if (level_index == level_ids.len - 1) {
            break :blk scripts_section_end_addr;
        } else {
            const offset = seekable_stream.context.reader().readInt(u32, .big) catch return error.ReadFailed;
            break :blk script_offsets_table_addr + offset;
        }
    };

    return .{ start_addr, end_addr };
}

pub fn readCompressedTextAlloc(allocator: std.mem.Allocator, seekable_stream: anytype, level_id: u8) CompressedLevelReadError![]const u8 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    seekable_stream.seekTo(text_offsets_table_addr + level_index * 4) catch return error.ReadFailed;
    const start_addr, const end_addr = try getTextAddrs(seekable_stream, level_id);

    const text_len = end_addr - start_addr;
    const buffer = try allocator.alloc(u8, text_len);
    errdefer allocator.free(buffer);

    seekable_stream.seekTo(start_addr) catch return error.ReadFailed;
    const bytes_read = seekable_stream.context.reader().readAll(buffer) catch return error.ReadFailed;
    std.debug.assert(bytes_read == text_len);

    return buffer;
}

pub fn getTextAddrs(seekable_stream: anytype, level_id: u8) CompressedLevelReadError!struct { u32, u32 } {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.LevelIdNotFound;

    seekable_stream.seekTo(text_offsets_table_addr + level_index * 4) catch return error.ReadFailed;
    const start_addr = blk: {
        const offset = seekable_stream.context.reader().readInt(u32, .big) catch return error.ReadFailed;
        break :blk text_offsets_table_addr + offset;
    };
    const end_addr = blk: {
        if (level_index == level_ids.len - 1) {
            break :blk text_section_end_addr;
        } else {
            const offset = seekable_stream.context.reader().readInt(u32, .big) catch return error.ReadFailed;
            break :blk text_offsets_table_addr + offset;
        }
    };

    return .{ start_addr, end_addr };
}

const std = @import("std");

const File = std.fs.File;

const CommandParser = @import("command.zig").CommandParser;
const LzwDecoder = @import("LzwDecoder.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_base: u16 = 0x6af6;
const memdump_path = "salvation.dmp";

pub fn main() !void {
    var stderr = std.io.bufferedWriter(std.io.getStdErr().writer());

    var gpa = GPA{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile(memdump_path, .{});
    defer file.close();

    const genesis_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(genesis_mem);

    for (level_ids) |level_id| {
        // we skip 0x61 because there might be a bug in the game or this particular rom dump
        // where an END code isn't found, so it just keeps decompressing subsequent data from later levels'
        // text
        // could be I'm missing some special way this particular level is loaded from a different function
        // We can't just remove it from the list of level_ids because each id's index in the array is
        // significant to finding the rom address of the compressed level data
        if (level_id == 0x61) continue;
        try stderr.writer().print("\n\n\nlevel id {x}\n", .{level_id});

        const rom_file = try std.fs.cwd().openFile("buck.md", .{});
        defer rom_file.close();

        const compressed_script_addr = try getCompressedScriptAddress(rom_file, level_id);
        const compressed_text_addr = try getCompressedTextAddress(rom_file, level_id);

        var decoder = try LzwDecoder.init(allocator);
        defer decoder.deinit();

        try stderr.writer().print("decompressing script from {x}\n", .{compressed_script_addr});
        try rom_file.seekTo(compressed_script_addr);
        const script = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(script);

        decoder.resetRetainingCapacity();

        try stderr.writer().print("decompressing text from {x}\n", .{compressed_text_addr});
        try rom_file.seekTo(compressed_text_addr);
        const text = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(text);

        const text_base: u16 = @intCast(ecl_base + script.len);

        try stderr.writer().print("script: {x} - {x}\n", .{ ecl_base, ecl_base + script.len });
        try stderr.writer().print("text: {x} - {x}\n", .{ text_base, text_base + text.len });

        var parser = try CommandParser.init(allocator, script, text);
        defer parser.deinit();

        try parser.parseEcl();

        try stderr.writer().print("\n", .{});
        for (parser.strings.items) |s| {
            try stderr.writer().print("str_{x}=\"{s}\"\n", .{ s.offset, s.bytes });
            std.debug.assert(std.mem.indexOfScalar(u8, s.bytes, '"') == null);
            std.debug.assert(std.mem.indexOfScalar(u8, s.bytes, '\n') == null);
        }
        try stderr.writer().print("\n", .{});

        parser.sortLabelsByAddress();
        parser.sortVarsByAddress();

        try parser.ensureStringArgsAccountedFor();
        if (parser.initialized_data) |data| {
            const end_address = data.address + data.bytes.len;
            try stderr.writer().print("\ninitialized bytes {x}-{x}\n", .{ data.address, end_address });
            try stderr.writer().print("{s}\n\n", .{std.fmt.fmtSliceHexLower(data.bytes)});
        }

        var it = parser.vars.iterator();
        while (it.next()) |e| {
            try stderr.writer().print("{s} {x}\n", .{ @tagName(e.value_ptr.*), e.key_ptr.* });
        }
        try stderr.writer().print("\n", .{});

        parser.detectVariableAliasing();

        var labels_it = parser.labels.iterator();
        var next_label = labels_it.next();
        for (parser.commands.items) |command| {
            if (next_label) |label| {
                if (command.address == label.key_ptr.*) {
                    try stderr.writer().print("LABEL_{x}:\n", .{label.key_ptr.*});
                    next_label = labels_it.next();
                }
            }
            try stderr.writer().print("    {s}", .{@tagName(command.tag)});
            for (parser.getCommandArgs(command)) |arg| {
                try stderr.writer().print(" ", .{});
                try arg.writeString(stderr.writer());
            }
            try stderr.writer().print("\n", .{});
        }
    }

    try stderr.flush();
}

const level_ids = [_]u8{ 0x00, 0x01, 0x03, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x34, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63 };
const compressedScriptsTableAddr = 0x38d02;
const compressedTextTableAddr = 0x42b2a;

fn getCompressedScriptAddress(rom_file: File, id: u8) !u32 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(compressedScriptsTableAddr + level_index * 4);
    const offset = try rom_file.reader().readInt(u32, .big);

    return compressedScriptsTableAddr + offset;
}

fn getCompressedTextAddress(rom_file: File, id: u8) !u32 {
    const level_index = std.mem.indexOfScalar(u8, &level_ids, id) orelse return error.LevelIdNotFound;

    try rom_file.seekTo(compressedTextTableAddr + level_index * 4);
    const offset = try rom_file.reader().readInt(u32, .big);

    return compressedTextTableAddr + offset;
}

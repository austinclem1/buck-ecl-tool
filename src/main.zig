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

        // In the game, when the decompressed output length is odd, the returned length is rounded down.
        // However, the final odd byte is still written into RAM. This matters with the script decompression
        // because the following decompressed text section will be placed following the rounded down length
        // of the script section, so we manually make this adjustment.
        const adjusted_len_script = if (script.len % 2 == 1) script[0 .. script.len - 1] else script;

        decoder.resetRetainingCapacity();

        try stderr.writer().print("decompressing text from {x}\n", .{compressed_text_addr});
        try rom_file.seekTo(compressed_text_addr);
        const text = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(text);

        const text_base: u16 = @intCast(ecl_base + adjusted_len_script.len);

        try stderr.writer().print("script: {x} - {x}\n", .{ ecl_base, ecl_base + adjusted_len_script.len });
        try stderr.writer().print("text: {x} - {x}\n", .{ text_base, text_base + text.len });

        var parser = try CommandParser.init(allocator, adjusted_len_script, text);
        defer parser.deinit();

        try parser.parseEcl();

        parser.sortLabelsByAddress();

        try parser.ensureStringArgsAccountedFor();

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
            for (parser.getCommandArgs(command), 0..) |arg, arg_i| {
                try stderr.writer().print(" ", .{});
                switch (command.tag) {
                    .GOTO, .GOSUB => try stderr.writer().print("LABEL_{x}", .{arg.indirect1}),
                    .ONGOTO, .ONGOSUB => {
                        if (arg_i >= 2) {
                            try stderr.writer().print("LABEL_{x}", .{arg.indirect1});
                        } else {
                            try arg.writeString(&parser, stderr.writer());
                        }
                    },
                    else => try arg.writeString(&parser, stderr.writer()),
                }
            }
            try stderr.writer().print("\n", .{});
        }
        for (parser.initialized_data_segments.items) |segment| {
            try stderr.writer().print("{s}:\n", .{segment.name});
            try stderr.writer().print("\t{s}\n", .{std.fmt.fmtSliceHexLower(segment.bytes)});
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

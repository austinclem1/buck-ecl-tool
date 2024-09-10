const std = @import("std");

const File = std.fs.File;

const ecl = @import("ecl.zig");
const LzwDecoder = @import("LzwDecoder.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_base: u16 = 0x6af6;
const memdump_path = "salvation.dmp";

const tokenize = @import("ecl/tokenize.zig");

pub fn main() !void {
    var stderr = std.io.bufferedWriter(std.io.getStdErr().writer());

    var gpa = GPA{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var ecl_dir = try std.fs.cwd().openDir("ecl_out", .{ .iterate = true });
    defer ecl_dir.close();
    var it = ecl_dir.iterate();
    var done_first = false;
    while (try it.next()) |entry| : (done_first = true) {
        if (done_first) break;
        const filename = switch (entry.kind) {
            .file => entry.name,
            else => continue,
        };
        var test_text = try ecl_dir.openFile(filename, .{});
        defer test_text.close();
        const test_text_bytes = try test_text.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(test_text_bytes);
        var parser = ecl.TextParser.init(allocator);
        defer parser.deinit();
        var ast = try parser.parse(test_text_bytes);
        defer ast.deinit();
        var token_stream = try tokenize.tokenize(allocator, test_text_bytes);
        defer token_stream.free(allocator);
        for (token_stream.tokens) |tok| {
            std.debug.print("{d}\t", .{tok.location});
            switch (tok.variant) {
                .string => |str| std.debug.print("string \"{s}\"\n", .{str}),
                .identifier => |str| std.debug.print("identifier: \"{s}\"\n", .{str}),
                else => std.debug.print("{any}\n", .{tok}),
            }
        }
        try ast.serializeText(stderr.writer());
    }

    for (level_ids[0..0]) |level_id| {
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
        // const adjusted_len_script = script;

        decoder.resetRetainingCapacity();

        try stderr.writer().print("decompressing text from {x}\n", .{compressed_text_addr});
        try rom_file.seekTo(compressed_text_addr);
        const text = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(text);

        // const text_base: u16 = @intCast(ecl_base + adjusted_len_script.len);

        // try stderr.writer().print("script: {x} - {x}\n", .{ ecl_base, ecl_base + adjusted_len_script.len });
        // try stderr.writer().print("text: {x} - {x}\n", .{ text_base, text_base + text.len });

        const initial_highest_known_command_address: ?u16 = if (level_id == 0x60) 0x907 + 0x6af6 else null;
        var parsed_ecl = try ecl.binary_parser.parseAlloc(allocator, adjusted_len_script, text, initial_highest_known_command_address);
        defer parsed_ecl.deinit();

        {
            var out_dir = try std.fs.cwd().makeOpenPath("ecl_out", .{});
            defer out_dir.close();

            const filename = try std.fmt.allocPrint(allocator, "{d}.ecl", .{level_id});
            defer allocator.free(filename);

            var f = try out_dir.createFile(filename, .{});
            defer f.close();

            try parsed_ecl.serializeText(f.writer());
        }
        if (level_id != 0x43) {
            const bin_result = try parsed_ecl.serializeBinary(allocator);
            defer allocator.free(bin_result.script);
            defer allocator.free(bin_result.text);
            std.debug.assert(std.mem.eql(u8, adjusted_len_script, bin_result.script));
            std.debug.assert(std.mem.eql(u8, text, bin_result.text));
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

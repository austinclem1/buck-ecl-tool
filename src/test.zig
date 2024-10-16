const std = @import("std");

const ecl = @import("ecl.zig");

const lzw = @import("lzw.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

pub fn runTest() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rom_file = try std.fs.cwd().openFile("fixed_buck.md", .{});
    defer rom_file.close();
    const rom_stream = rom_file.seekableStream();

    for (ecl.level_ids) |level_id| {
        // we skip 0x61 because there might be a bug in the game or this particular rom dump
        // where an END code isn't found, so it just keeps decompressing subsequent data from later levels'
        // text
        // could be I'm missing some special way this particular level is loaded from a different function
        // We can't just remove it from the list of level_ids because each id's index in the array is
        // significant to finding the rom address of the compressed level data
        if (level_id == 0x61) continue;

        const compressed_script = try ecl.readCompressedScriptAlloc(allocator, rom_stream, level_id);
        defer allocator.free(compressed_script);

        const compressed_text = try ecl.readCompressedTextAlloc(allocator, rom_stream, level_id);
        defer allocator.free(compressed_text);

        var decoder = try lzw.Decoder.init(allocator);
        defer decoder.deinit();

        var script_fbs = std.io.fixedBufferStream(compressed_script);
        const bin_script = try decoder.decompressAlloc(allocator, script_fbs.reader());
        defer allocator.free(bin_script);

        // In the game, when the decompressed output length is odd, the returned length is rounded down.
        // However, the final odd byte is still written into RAM. This matters with the script decompression
        // because the following decompressed text section will be placed following the rounded down length
        // of the script section, so we manually make this adjustment.
        const adjusted_len_bin_script = if (bin_script.len % 2 == 1) bin_script[0 .. bin_script.len - 1] else bin_script;

        decoder.resetRetainingCapacity();

        var text_fbs = std.io.fixedBufferStream(compressed_text);
        const bin_text = try decoder.decompressAlloc(allocator, text_fbs.reader());
        defer allocator.free(bin_text);

        {
            var encoder = try lzw.Encoder.init(allocator);
            defer encoder.deinit();
            const recompressed_script = try encoder.compressAlloc(allocator, bin_script);
            defer allocator.free(recompressed_script);
            const trimmed_orig = std.mem.trimRight(u8, compressed_script, "\x00");
            const trimmed_new = std.mem.trimRight(u8, recompressed_script, "\x00");
            std.debug.assert(std.mem.eql(u8, trimmed_orig, trimmed_new));
        }
        {
            var encoder = try lzw.Encoder.init(allocator);
            defer encoder.deinit();
            const recompressed_text = try encoder.compressAlloc(allocator, bin_text);
            defer allocator.free(recompressed_text);
            const trimmed_orig = std.mem.trimRight(u8, compressed_text, "\x00");
            const trimmed_new = std.mem.trimRight(u8, recompressed_text, "\x00");
            std.debug.assert(std.mem.eql(u8, trimmed_orig, trimmed_new));
        }

        const initial_highest_known_command_address: ?u16 = if (level_id == 0x60) 0x907 + 0x6af6 else null;
        var parsed_ecl = try ecl.binary_parser.parseAlloc(allocator, adjusted_len_bin_script, bin_text, initial_highest_known_command_address);
        defer parsed_ecl.deinit();

        if (level_id != 0x43) {
            const serialized_binary = try parsed_ecl.serializeBinary(allocator);
            defer allocator.free(serialized_binary.script);
            defer allocator.free(serialized_binary.text);
            std.debug.assert(std.mem.eql(u8, adjusted_len_bin_script, serialized_binary.script));
            std.debug.assert(std.mem.eql(u8, bin_text, serialized_binary.text));
        }
        {
            var ast_text = std.ArrayList(u8).init(allocator);
            defer ast_text.deinit();
            try parsed_ecl.serializeText(ast_text.writer());

            var parser = ecl.TextParser.init(allocator);
            defer parser.deinit();

            var reparsed_ast = try parser.parse(ast_text.items);
            defer reparsed_ast.deinit();

            var reserialized_ast_text = std.ArrayList(u8).init(allocator);
            defer reserialized_ast_text.deinit();
            try reparsed_ast.serializeText(reserialized_ast_text.writer());

            std.debug.assert(std.mem.eql(u8, ast_text.items, reserialized_ast_text.items));
        }
    }
}

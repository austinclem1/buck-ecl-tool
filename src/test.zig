const std = @import("std");

const ecl = @import("ecl.zig");

const GPA = std.heap.GeneralPurposeAllocator;

pub fn runTest() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rom_file = try std.fs.cwd().openFile("buck.md", .{});
    defer rom_file.close();

    for (ecl.level_ids) |level_id| {
        // we skip 0x61 because there might be a bug in the game or this particular rom dump
        // where an END code isn't found, so it just keeps decompressing subsequent data from later levels'
        // text
        // could be I'm missing some special way this particular level is loaded from a different function
        // We can't just remove it from the list of level_ids because each id's index in the array is
        // significant to finding the rom address of the compressed level data
        if (level_id == 0x61) continue;

        const compressed_script_addr = try ecl.getCompressedScriptAddress(rom_file, level_id);
        const compressed_text_addr = try ecl.getCompressedTextAddress(rom_file, level_id);

        var decoder = try ecl.LzwDecoder.init(allocator);
        defer decoder.deinit();

        try rom_file.seekTo(compressed_script_addr);

        const bin_script = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(bin_script);

        // In the game, when the decompressed output length is odd, the returned length is rounded down.
        // However, the final odd byte is still written into RAM. This matters with the script decompression
        // because the following decompressed text section will be placed following the rounded down length
        // of the script section, so we manually make this adjustment.
        const adjusted_len_bin_script = if (bin_script.len % 2 == 1) bin_script[0 .. bin_script.len - 1] else bin_script;

        decoder.resetRetainingCapacity();

        try rom_file.seekTo(compressed_text_addr);
        const bin_text = try decoder.decompressAlloc(allocator, rom_file.reader());
        defer allocator.free(bin_text);

        const initial_highest_known_command_address: ?u16 = if (level_id == 0x60) 0x907 + 0x6af6 else null;
        var parsed_ecl = try ecl.binary_parser.parseAlloc(allocator, adjusted_len_bin_script, bin_text, initial_highest_known_command_address);
        defer parsed_ecl.deinit();

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

        // {
        //     var out_dir = try std.fs.cwd().makeOpenPath("ecl_out", .{});
        //     defer out_dir.close();
        //
        //     const filename = try std.fmt.allocPrint(allocator, "{d}.ecl", .{level_id});
        //     defer allocator.free(filename);
        //
        //     var f = try out_dir.createFile(filename, .{});
        //     defer f.close();
        //
        //     try parsed_ecl.serializeText(f.writer());
        // }
        // if (level_id != 0x43) {
        //     const bin_result = try parsed_ecl.serializeBinary(allocator);
        //     defer allocator.free(bin_result.script);
        //     defer allocator.free(bin_result.text);
        //     std.debug.assert(std.mem.eql(u8, adjusted_len_script, bin_result.script));
        //     std.debug.assert(std.mem.eql(u8, text, bin_result.text));
        // }
    }
}

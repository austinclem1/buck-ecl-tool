const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const ecl = @import("ecl.zig");
const lzw = @import("lzw.zig");

const ecl_base: u16 = 0x6af6;

const tokenize = @import("ecl/tokenize.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // var f = try std.fs.cwd().openFile("lastfuzzinput", .{});
    // defer f.close();
    // const input = try f.readToEndAlloc(allocator, 0x100000);
    // defer allocator.free(input);
    // // try testEncodeDecode(allocator, &@as([1000]u8, @splat(0)));
    // try testEncodeDecode(allocator, input);

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Failed to allocate process args\n", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const subcommand = args[1];
    if (std.mem.eql(u8, subcommand, "extract-all")) {
        const subcommandArgs = parseExtractAllCommandArgs(args[2..]) catch {
            printHelp();
            return;
        };
        extractAllCommand(allocator, subcommandArgs);
    } else if (std.mem.eql(u8, subcommand, "patch-rom")) {
        const subcommandArgs = parsePatchRomCommandArgs(args[2..]) catch {
            printHelp();
            return;
        };
        patchRomCommand(allocator, subcommandArgs);
    } else if (std.mem.eql(u8, subcommand, "fix-mariposa")) {
        const subcommandArgs = parseFixMariposaCommandArgs(args[2..]) catch {
            printHelp();
            return;
        };
        fixMariposaCommand(subcommandArgs);
    } else {
        printHelp();
        return;
    }
}

fn parseFile(allocator: std.mem.Allocator, path: []const u8) !ecl.Ast {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(file_bytes);

    var parser = ecl.TextParser.init(allocator);
    defer parser.deinit();

    return parser.parse(file_bytes);
}

fn calculateSegaHeaderChecksum(seekable_stream: anytype) !u16 {
    const rom_len = try seekable_stream.getEndPos();
    if (rom_len % 2 != 0) return error.RomOddLegth;

    try seekable_stream.seekTo(0x200);

    var checksum: u16 = 0;

    while (seekable_stream.context.reader().readInt(u16, .big)) |val| {
        checksum +%= val;
    } else |err| switch (err) {
        error.EndOfStream => {},
    }

    return checksum;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: buck-ecl-tool [command] [options]
        \\
        \\Commands:
        \\
        \\  extract-all --rom [input rom path] --out [output directory]
        \\    Extract all levels in rom as text ECL format to output directory
        \\
        \\  patch-rom --rom [input rom path] --ecl [updated ecl path] --dest-level-id [rom level id to overwrite] --out [output rom path]
        \\    Patch specified level id in rom with the given text ECL file, writing the updated rom file to [out]
        \\
        \\  fix-mariposa --rom [input rom path]
        \\    Apply fix to original compressed mariposa text data in rom that causes lzw decoder to erroneously keep running on
        \\    level id 97 (0x61)
        \\
    , .{});
}

const ExtractAllCommandArgs = struct {
    input_rom_path: []const u8,
    output_dir_path: []const u8,
};

fn parseExtractAllCommandArgs(args: []const []const u8) !ExtractAllCommandArgs {
    var input_rom_path: ?[]const u8 = null;
    var output_dir_path: ?[]const u8 = null;
    const ParseState = enum {
        init,
        rom,
        out,
    };
    var parse_state: ParseState = .init;
    for (args) |arg| {
        switch (parse_state) {
            .init => {
                if (std.mem.eql(u8, arg, "--rom")) {
                    parse_state = .rom;
                } else if (std.mem.eql(u8, arg, "--out")) {
                    parse_state = .out;
                } else {
                    std.debug.print("Error: unexpected arg \"{s}\"\n", .{arg});
                    return error.ParseArgsFailed;
                }
            },
            .rom => {
                input_rom_path = arg;
                parse_state = .init;
            },
            .out => {
                output_dir_path = arg;
                parse_state = .init;
            },
        }
    }

    return ExtractAllCommandArgs{
        .input_rom_path = input_rom_path orelse {
            std.debug.print("Error: No input rom path given with \"--rom\"\n", .{});
            return error.ParseArgsFailed;
        },
        .output_dir_path = output_dir_path orelse {
            std.debug.print("Error: No output directory path given with \"--out\"\n", .{});
            return error.ParseArgsFailed;
        },
    };
}

const PatchRomCommandArgs = struct {
    input_rom_path: []const u8,
    input_ecl_path: []const u8,
    dest_level_id: u16,
    output_rom_path: []const u8,
};

fn parsePatchRomCommandArgs(args: []const []const u8) !PatchRomCommandArgs {
    var input_rom_path: ?[]const u8 = null;
    var input_ecl_path: ?[]const u8 = null;
    var dest_level_id: ?u16 = null;
    var output_rom_path: ?[]const u8 = null;
    const ParseState = enum {
        init,
        rom,
        ecl,
        dest_level,
        out,
    };
    var parse_state: ParseState = .init;
    for (args) |arg| {
        switch (parse_state) {
            .init => {
                if (std.mem.eql(u8, arg, "--rom")) {
                    parse_state = .rom;
                } else if (std.mem.eql(u8, arg, "--ecl")) {
                    parse_state = .ecl;
                } else if (std.mem.eql(u8, arg, "--dest-level-id")) {
                    parse_state = .dest_level;
                } else if (std.mem.eql(u8, arg, "--out")) {
                    parse_state = .out;
                } else {
                    std.debug.print("Error: unexpected arg \"{s}\"\n", .{arg});
                    return error.ParseArgsFailed;
                }
            },
            .rom => {
                input_rom_path = arg;
                parse_state = .init;
            },
            .ecl => {
                input_ecl_path = arg;
                parse_state = .init;
            },
            .dest_level => {
                dest_level_id = std.fmt.parseUnsigned(u16, arg, 0) catch {
                    std.debug.print("Error: Failed to parse --dest-level-id option \"{s}\"\n", .{arg});
                    return error.ParseArgsFailed;
                };
                parse_state = .init;
            },
            .out => {
                output_rom_path = arg;
                parse_state = .init;
            },
        }
    }

    return PatchRomCommandArgs{
        .input_rom_path = input_rom_path orelse {
            std.debug.print("Error: No input rom path given\n", .{});
            return error.ParseArgsFailed;
        },
        .input_ecl_path = input_ecl_path orelse {
            std.debug.print("Error: No input ecl path given\n", .{});
            return error.ParseArgsFailed;
        },
        .dest_level_id = dest_level_id orelse {
            std.debug.print("Error: No destination level id given\n", .{});
            return error.ParseArgsFailed;
        },
        .output_rom_path = output_rom_path orelse {
            std.debug.print("Error: No output rom path given\n", .{});
            return error.ParseArgsFailed;
        },
    };
}

fn extractAllCommand(allocator: Allocator, args: ExtractAllCommandArgs) void {
    var rom = std.fs.cwd().openFile(args.input_rom_path, .{}) catch fatal("failed to open input rom \"{s}\"\n", .{args.input_rom_path});
    defer rom.close();
    const rom_stream = rom.seekableStream();
    for (ecl.level_ids) |id| {
        const compressed_script = ecl.readCompressedScriptAlloc(allocator, rom_stream, id) catch |err| {
            fatal("failed to read compressed script section for level id {d}, error: {s}\n", .{ id, @errorName(err) });
        };
        defer allocator.free(compressed_script);
        const compressed_text = ecl.readCompressedTextAlloc(allocator, rom_stream, id) catch |err| {
            fatal("failed to read compressed text section for level id {d}, error: {s}\n", .{ id, @errorName(err) });
        };
        defer allocator.free(compressed_text);

        var decoder = lzw.Decoder.init(allocator) catch |err| {
            fatal("failed to initialize lzw decoder, error: {s}\n", .{@errorName(err)});
        };
        defer decoder.deinit(allocator);
        const bin_script = blk: {
            var fbs = std.io.fixedBufferStream(compressed_script);
            var output = std.ArrayList(u8).init(allocator);
            errdefer output.deinit();
            decoder.decompress(fbs.reader(), output.writer(), null) catch |err| {
                fatal("failed to decompress script section for level id {d}, error: {s}\n", .{ id, @errorName(err) });
            };
            break :blk output.toOwnedSlice() catch fatal("out of memory\n", .{});
        };
        defer allocator.free(bin_script);
        decoder.reset();
        const bin_text = blk: {
            var fbs = std.io.fixedBufferStream(compressed_text);
            var output = std.ArrayList(u8).init(allocator);
            errdefer output.deinit();
            decoder.decompress(fbs.reader(), output.writer(), null) catch |err| {
                fatal("failed to decompress text section for level id {d}, error: {s}\n", .{ id, @errorName(err) });
            };
            break :blk output.toOwnedSlice() catch fatal("out of memory\n", .{});
        };
        defer allocator.free(bin_text);
        const init_highest = if (id == 0x60) 0x907 + ecl_base else null;
        var ast = ecl.binary_parser.parseAlloc(allocator, bin_script, bin_text, init_highest) catch |err| {
            fatal("failed disassembly for level id {d}, error: {s}\n", .{ id, @errorName(err) });
        };
        defer ast.deinit();

        var out_dir = std.fs.cwd().makeOpenPath(args.output_dir_path, .{}) catch |err| {
            fatal("failed to create and open path {s}, error: {s}\n", .{ args.output_dir_path, @errorName(err) });
        };
        defer out_dir.close();

        var buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&buf, "{d:0>2}.ecl", .{id}) catch |err| {
            fatal("output path too long, error: {s}\n", .{@errorName(err)});
        };
        var out_file = out_dir.createFile(filename, .{}) catch |err| {
            fatal("failed to create file {s} in path {s}, error: {s}\n", .{ filename, args.output_dir_path, @errorName(err) });
        };
        defer out_file.close();
        ast.serializeText(out_file.writer()) catch |err| {
            fatal("failed to serialize ecl for level id {d} to file {s}, error: {s}\n", .{ id, filename, @errorName(err) });
        };
    }
}

fn patchRomCommand(allocator: Allocator, args: PatchRomCommandArgs) void {
    var in_rom = std.fs.cwd().openFile(args.input_rom_path, .{}) catch fatal("failed to open input rom \"{s}\"\n", .{args.input_rom_path});
    defer in_rom.close();

    var out_rom_bytes = in_rom.readToEndAlloc(allocator, 1024 * 1024 * 16) catch |err| {
        fatal("failed to read file {s}, error: {s}\n", .{ args.input_rom_path, @errorName(err) });
    };
    defer allocator.free(out_rom_bytes);

    var in_ecl = std.fs.cwd().openFile(args.input_ecl_path, .{}) catch fatal("failed to open input ecl text file \"{s}\"\n", .{args.input_ecl_path});
    defer in_ecl.close();

    const in_ecl_bytes = in_ecl.readToEndAlloc(allocator, 1024 * 1024 * 32) catch |err| {
        fatal("failed to read file {s}, error: {s}\n", .{ args.input_ecl_path, @errorName(err) });
    };
    defer allocator.free(in_ecl_bytes);

    var parsed_ecl = blk: {
        var parser = ecl.TextParser.init(allocator);
        defer parser.deinit();

        break :blk parser.parse(in_ecl_bytes) catch |err| {
            fatal("failed to parse file {s}, error: {s}\n", .{ args.input_ecl_path, @errorName(err) });
        };
    };
    defer parsed_ecl.deinit();

    const ecl_binary = parsed_ecl.serializeBinary(allocator) catch |err| {
        fatal("failed to serialize parsed ecl to binary, error: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(ecl_binary.script);
    defer allocator.free(ecl_binary.text);

    {
        const compressed_script = blk: {
            var encoder = lzw.Encoder.init(allocator) catch |err| {
                fatal("failed to initialize lzw encoder, error: {s}\n", .{@errorName(err)});
            };
            defer encoder.deinit(allocator);
            var fbs = std.io.fixedBufferStream(ecl_binary.script);
            var output = std.ArrayList(u8).init(allocator);
            defer output.deinit();
            encoder.compress(output.writer(), fbs.reader()) catch |err| {
                fatal("failed to compress ecl binary script data, error: {s}\n", .{@errorName(err)});
            };
            break :blk output.toOwnedSlice() catch fatal("out of memory\n", .{});
        };
        defer allocator.free(compressed_script);

        const dest_start, const dest_end = ecl.getScriptAddrs(in_rom.seekableStream(), 0x10) catch |err| {
            fatal("failed to read script dest address from rom file {s}, error: {s}\n", .{ args.input_rom_path, @errorName(err) });
        };
        const max_script_size = dest_end - dest_start;

        if (compressed_script.len > max_script_size) {
            fatal("resulting script data larger than original data: {d} bytes (original {d})\n", .{ compressed_script.len, max_script_size });
        }

        std.mem.copyForwards(u8, out_rom_bytes[dest_start..dest_end], compressed_script);
    }

    {
        const compressed_text = blk: {
            var encoder = lzw.Encoder.init(allocator) catch |err| {
                fatal("failed to initialize lzw encoder, error: {s}\n", .{@errorName(err)});
            };
            defer encoder.deinit(allocator);
            var fbs = std.io.fixedBufferStream(ecl_binary.text);
            var output = std.ArrayList(u8).init(allocator);
            defer output.deinit();
            encoder.compress(output.writer(), fbs.reader()) catch |err| {
                fatal("failed to compress ecl binary text data, error: {s}\n", .{@errorName(err)});
            };
            break :blk output.toOwnedSlice() catch fatal("out of memory\n", .{});
        };
        defer allocator.free(compressed_text);

        const dest_start, const dest_end = ecl.getTextAddrs(in_rom.seekableStream(), 0x10) catch |err| {
            fatal("failed to read text dest address from rom file {s}, error: {s}\n", .{ args.input_rom_path, @errorName(err) });
        };
        const max_text_size = dest_end - dest_start;

        if (compressed_text.len > max_text_size) {
            fatal("resulting text data larger than original data: {d} bytes (original {d})\n", .{ compressed_text.len, max_text_size });
        }

        std.mem.copyForwards(u8, out_rom_bytes[dest_start..dest_end], compressed_text);
    }

    {
        // TODO: this patching of the checksum could be a separate command
        var fbs = std.io.fixedBufferStream(out_rom_bytes);
        fixRomChecksum(fbs.seekableStream()) catch |err| {
            fatal("failed to patch checksum for output rom bytes, error: {s}\n", .{@errorName(err)});
        };
    }

    var out_rom = std.fs.cwd().createFile(args.output_rom_path, .{}) catch |err| {
        fatal("failed to create output rom file \"{s}\", error: {s}\n", .{ args.output_rom_path, @errorName(err) });
    };
    defer out_rom.close();

    out_rom.writeAll(out_rom_bytes) catch |err| {
        fatal("failed to write to output rom file \"{s}\", error: {s}\n", .{ args.output_rom_path, @errorName(err) });
    };
}

fn fixMariposaCommand(args: FixMariposaCommandArgs) void {
    var rom = std.fs.cwd().openFile(args.rom_path, .{ .mode = .write_only }) catch fatal("failed to open input rom \"{s}\"\n", .{args.rom_path});
    defer rom.close();
    const rom_stream = rom.seekableStream();
    rom_stream.seekTo(0x4fadb) catch |err| {
        fatal("failed seeking rom file to mariposa fix destination, error: {s}\n", .{@errorName(err)});
    };
    rom_stream.context.writer().writeInt(u16, 0x1010, .big) catch |err| {
        fatal("failed writing mariposa text fix to rom, error: {s}\n", .{@errorName(err)});
    };
}

const FixMariposaCommandArgs = struct {
    rom_path: []const u8,
};

fn parseFixMariposaCommandArgs(args: []const []const u8) !FixMariposaCommandArgs {
    var rom_path: ?[]const u8 = null;
    const ParseState = enum {
        init,
        rom,
    };
    var parse_state: ParseState = .init;
    for (args) |arg| {
        switch (parse_state) {
            .init => {
                if (std.mem.eql(u8, arg, "--rom")) {
                    parse_state = .rom;
                } else {
                    std.debug.print("Error: unexpected arg \"{s}\"\n", .{arg});
                    return error.ParseArgsFailed;
                }
            },
            .rom => {
                rom_path = arg;
                parse_state = .init;
            },
        }
    }

    return FixMariposaCommandArgs{
        .rom_path = rom_path orelse {
            std.debug.print("Error: No input rom path given with \"--rom\"\n", .{});
            return error.ParseArgsFailed;
        },
    };
}

fn fixRomChecksum(seekable_stream: anytype) !void {
    seekable_stream.seekTo(0x300) catch return error.SeekFailed;

    const m68k_nop_code: u16 = 0x4e71;

    seekable_stream.context.writer().writeInt(u16, m68k_nop_code, .big) catch return error.WriteFailed;
    seekable_stream.context.writer().writeInt(u16, m68k_nop_code, .big) catch return error.WriteFailed;
    seekable_stream.context.writer().writeInt(u16, m68k_nop_code, .big) catch return error.WriteFailed;

    // calculate standard sega header checksum and patch the rom with that
    const sega_checksum = calculateSegaHeaderChecksum(seekable_stream) catch |err| {
        fatal("failed to calculate rom checksum, error: {s}\n", .{@errorName(err)});
    };
    seekable_stream.seekTo(0x18e) catch return error.SeekFailed;
    seekable_stream.context.writer().writeInt(u16, sega_checksum, .big) catch return error.WriteFailed;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

test "fuzz there and back" {
    // return std.testing.fuzz({}, testEncodeDecode, .{});
    return std.testing.fuzz(std.testing.allocator, testEncodeDecode, .{});
}

fn testEncodeDecode(context: std.mem.Allocator, input: []const u8) anyerror!void {
    // _ = context;
    const allocator = context;
    // var f = try std.fs.cwd().createFile("~/projects/buck-ecl-tool/lastfuzzinput", .{});
    var f = try std.fs.cwd().createFile("lastfuzzinput", .{});
    defer f.close();
    try f.writer().writeAll(input);
    
    // const allocator = std.testing.allocator;
    var encoder = try lzw.Encoder.init(allocator);
    defer encoder.deinit(allocator);
    var decoder = try lzw.Decoder.init(allocator);
    defer decoder.deinit(allocator);

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    {
        var fbs = std.io.fixedBufferStream(input);
        try encoder.compress(compressed.writer(), fbs.reader());
        // try compressed.appendSlice("\x00\x00\x00\x00");
    }
    
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    {
        var fbs = std.io.fixedBufferStream(compressed.items);
        try decoder.decompress(fbs.reader(), output.writer(), null);
    }
    try std.testing.expectEqualSlices(u8, std.mem.trimRight(u8, input, "\x00"), std.mem.trimRight(u8, output.items, "\x00"));
    // try std.testing.expectEqualSlices(u8, input, output.items);
}

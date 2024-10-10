const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const ecl = @import("ecl.zig");
const lzw = @import("lzw.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_base: u16 = 0x6af6;

const tokenize = @import("ecl/tokenize.zig");

pub fn main() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
        extractAllCommand(allocator, subcommandArgs) catch {
            std.debug.print("Error: extract-all command failed\n", .{});
            return;
        };
    } else if (std.mem.eql(u8, subcommand, "patch-rom")) {
        const remaining_args = args[2..];
        _ = remaining_args;
    } else {
        printHelp();
        return;
    }

    //if (true) {
    //    var rom = try std.fs.cwd().openFile("buck.md", .{});
    //    defer rom.close();
    //    for (ecl.level_ids) |id| {
    //        if (id == 0x61) continue;

    //        const compressed_script = try ecl.fileReadCompressedScriptAlloc(allocator, rom, id);
    //        defer allocator.free(compressed_script);
    //        const compressed_text = try ecl.fileReadCompressedTextAlloc(allocator, rom, id);
    //        defer allocator.free(compressed_text);

    //        var decoder = try lzw.Decoder.init(allocator);
    //        defer decoder.deinit();
    //        const bin_script = blk: {
    //            var fbs = std.io.fixedBufferStream(compressed_script);
    //            break :blk try decoder.decompressAlloc(allocator, fbs.reader());
    //        };
    //        defer allocator.free(bin_script);
    //        decoder.resetRetainingCapacity();
    //        const bin_text = blk: {
    //            var fbs = std.io.fixedBufferStream(compressed_text);
    //            break :blk try decoder.decompressAlloc(allocator, fbs.reader());
    //        };
    //        defer allocator.free(bin_text);
    //        const init_highest = if (id == 0x60) 0x907 + ecl_base else null;
    //        var ast = try ecl.binary_parser.parseAlloc(allocator, bin_script, bin_text, init_highest);
    //        defer ast.deinit();

    //        var buf: [100]u8 = undefined;
    //        const out_path = try std.fmt.bufPrint(&buf, "ecl_out/{d}.ecl", .{id});
    //        var out_file = try std.fs.cwd().createFile(out_path, .{});
    //        defer out_file.close();
    //        try ast.serializeText(out_file.writer());
    //    }
    //}

    //std.debug.print("Parsing \"{s}\"\n", .{input_ecl_path});
    //var ast = try parseFile(allocator, input_ecl_path);
    //defer ast.deinit();

    //const ecl_binary = try ast.serializeBinary(allocator);
    //defer allocator.free(ecl_binary.script);
    //defer allocator.free(ecl_binary.text);

    //std.debug.print("Read rom data from \"{s}\"\n", .{input_rom_path});
    //const in_rom = try std.fs.cwd().openFile(input_rom_path, .{});
    //defer in_rom.close();

    //var rom_bytes = try in_rom.readToEndAlloc(allocator, 1024 * 1024 * 4);
    //defer allocator.free(rom_bytes);

    //{
    //    const compressed_script = blk: {
    //        var encoder = try lzw.Encoder.init(allocator);
    //        defer encoder.deinit();
    //        break :blk try encoder.compressAlloc(allocator, ecl_binary.script);
    //    };
    //    defer allocator.free(compressed_script);

    //    const dest_start, const dest_end = try ecl.getScriptAddrs(in_rom, 0x10);
    //    const max_script_size = dest_end - dest_start;
    //    if (compressed_script.len > max_script_size) {
    //        std.debug.print("resulting script too long: {d} (max {d})\n", .{ compressed_script.len, max_script_size });
    //        return;
    //    }

    //    std.mem.copyForwards(u8, rom_bytes[dest_start..dest_end], compressed_script);
    //}

    //{
    //    const compressed_text = blk: {
    //        var encoder = try lzw.Encoder.init(allocator);
    //        defer encoder.deinit();
    //        break :blk try encoder.compressAlloc(allocator, ecl_binary.text);
    //    };
    //    defer allocator.free(compressed_text);

    //    const dest_start, const dest_end = try ecl.getTextAddrs(in_rom, 0x10);
    //    const max_text_size = dest_end - dest_start;

    //    if (compressed_text.len > max_text_size) {
    //        std.debug.print("resulting text too long: {d} (max {d})\n", .{ compressed_text.len, max_text_size });
    //    }

    //    std.mem.copyForwards(u8, rom_bytes[dest_start..dest_end], compressed_text);
    //}

    //{
    //    var fbs = std.io.fixedBufferStream(rom_bytes);

    //    // turn buck's custom checksum function call into 3 NOPs
    //    try fbs.seekTo(0x300);

    //    const m68k_nop_code: u16 = 0x4e71;

    //    try fbs.writer().writeInt(u16, m68k_nop_code, .big);
    //    try fbs.writer().writeInt(u16, m68k_nop_code, .big);
    //    try fbs.writer().writeInt(u16, m68k_nop_code, .big);

    //    // calculate standard sega header checksum and patch the rom with that
    //    const sega_checksum = try calculateSegaHeaderChecksum(rom_bytes);
    //    try fbs.seekTo(0x18e);
    //    try fbs.writer().writeInt(u16, sega_checksum, .big);
    //}

    //var out_rom = try std.fs.cwd().createFile(output_rom_path, .{});
    //defer out_rom.close();

    //try out_rom.writeAll(rom_bytes);
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

fn calculateSegaHeaderChecksum(rom_bytes: []const u8) !u16 {
    if (rom_bytes.len % 2 != 0) return error.RomOddLegth;

    var fbs = std.io.fixedBufferStream(rom_bytes);
    fbs.seekTo(0x200) catch return error.RomTooSmall;

    var checksum: u16 = 0;

    while (fbs.reader().readInt(u16, .big)) |val| {
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
        \\  patch-rom --rom [input rom path] --ecl [updated ecl path] --dest-level [rom level id to overwrite] --out [output rom path]
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
                } else if (std.mem.eql(u8, arg, "--dest-level")) {
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
        .input_rom_path orelse {},
        .input_ecl_path orelse {},
        .dest_level_id orelse {},
        .output_rom_path orelse {},
    };
}

fn extractAllCommand(allocator: Allocator, args: ExtractAllCommandArgs) error{Failed}!void {
    var rom = std.fs.cwd().openFile(args.input_rom_path, .{}) catch {
        std.debug.print("Error: Failed to open input rom \"{s}\"\n", .{args.input_rom_path});
        return error.Failed;
    };
    defer rom.close();
    for (ecl.level_ids) |id| {
        if (id == 0x61) continue;

        const compressed_script = ecl.fileReadCompressedScriptAlloc(allocator, rom, id) catch {
            std.debug.print("Error: Failed to read compressed script section for level id {d}\n", .{id});
            return error.Failed;
        };
        defer allocator.free(compressed_script);
        const compressed_text = ecl.fileReadCompressedTextAlloc(allocator, rom, id) catch {
            std.debug.print("Error: Failed to read compressed text section for level id {d}\n", .{id});
            return error.Failed;
        };
        defer allocator.free(compressed_text);

        var decoder = lzw.Decoder.init(allocator) catch {
            std.debug.print("Error: Failed to initialize lzw decoder\n", .{});
            return error.Failed;
        };
        defer decoder.deinit();
        const bin_script = blk: {
            var fbs = std.io.fixedBufferStream(compressed_script);
            break :blk decoder.decompressAlloc(allocator, fbs.reader()) catch {
                std.debug.print("Error: Failed to decompress script section for level id {d}\n", .{id});
                return error.Failed;
            };
        };
        defer allocator.free(bin_script);
        decoder.resetRetainingCapacity();
        const bin_text = blk: {
            var fbs = std.io.fixedBufferStream(compressed_text);
            break :blk decoder.decompressAlloc(allocator, fbs.reader()) catch {
                std.debug.print("Error: Failed to decompress script section for level id {d}\n", .{id});
                return error.Failed;
            };
        };
        defer allocator.free(bin_text);
        const init_highest = if (id == 0x60) 0x907 + ecl_base else null;
        var ast = ecl.binary_parser.parseAlloc(allocator, bin_script, bin_text, init_highest) catch {
            std.debug.print("Error: Failed disassembly for level id {d}\n", .{id});
            return error.Failed;
        };
        defer ast.deinit();

        var out_dir = std.fs.cwd().makeOpenPath(args.output_dir_path, .{}) catch {
            std.debug.print("Error: Failed to create and open path \"{s}\"\n", .{args.output_dir_path});
            return error.Failed;
        };
        defer out_dir.close();

        var buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&buf, "{d:0>2}.ecl", .{id}) catch {
            std.debug.print("Error: output path too long\n", .{});
            return error.Failed;
        };
        var out_file = out_dir.createFile(filename, .{}) catch {
            std.debug.print("Error: failed to create file {s} in path {s}\n", .{ filename, args.output_dir_path });
            return error.Failed;
        };
        defer out_file.close();
        ast.serializeText(out_file.writer()) catch {
            std.debug.print("Error: failed to serialize ecl for level id {d} to file {s}\n", .{ id, filename });
            return error.Failed;
        };
    }
}

const std = @import("std");

const fatal = std.process.fatal;
const panic = std.debug.panic;

const ecl = @import("ecl.zig");
const lzw = @import("lzw.zig");

const ecl_base: u16 = 0x6af6;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const args = std.process.argsAlloc(gpa) catch {
        @panic("Failed to allocate process args\n");
    };
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        fatal(help_text, .{});
    }

    const subcommand = args[1];
    if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        std.debug.print(help_text, .{});
        std.process.exit(0);
    } else if (std.mem.eql(u8, subcommand, "extract-all")) {
        const extract_all_args = parseExtractAllCommandArgs(args[2..]) catch {
            fatal(help_text, .{});
        };
        extractAllCommand(gpa, extract_all_args) catch |err| switch(err) {
            error.FailedToCreateOrOpenOutputDir => fatal("Failed to create/open output directory \"{s}\"\n", .{extract_all_args.output_dir_path}),
            error.FailedToOpenRom => fatal("Failed to open input rom \"{s}\"\n", .{extract_all_args.input_rom_path}),
            error.FailedToReadRom => fatal("Failed to read input rom \"{s}\"\n", .{extract_all_args.input_rom_path}),
            error.InvalidDataWhileDecoding => fatal("Failed to decompress level data\n", .{}),
            error.FailedToDisassembleEcl => fatal("Failed to disassemble level data\n", .{}),
            error.FailedToWriteEcl => fatal("Failed to write output file\n", .{}),
            error.OutOfMemory => @panic("Out of memory\n"),
        };
    } else if (std.mem.eql(u8, subcommand, "patch-rom")) {
        const patch_rom_args = parsePatchRomCommandArgs(args[2..]) catch {
            fatal(help_text, .{});
        };
        patchRomCommand(gpa, patch_rom_args) catch |err| switch(err) {
            error.OutOfMemory => @panic("Out of memory\n"),
            error.FailedToOpenRom => fatal("Failed to open rom file \"{s}\"\n", .{patch_rom_args.input_rom_path}),
            error.FailedToReadRom => fatal("Failed to read rom file \"{s}\"\n", .{patch_rom_args.input_rom_path}),
            error.FailedToOpenEcl => fatal("Failed to open ecl file \"{s}\"\n", .{patch_rom_args.input_ecl_path}),
            error.EclFileTooBig => fatal("Ecl file \"{s}\" too big\n", .{patch_rom_args.input_ecl_path}),
            error.FailedToReadEcl => fatal("Failed to read ecl file \"{s}\"\n", .{patch_rom_args.input_ecl_path}),
            error.FailedToParseEcl => fatal("Failed to parse ecl file \"{s}\"\n", .{patch_rom_args.input_ecl_path}),
            error.TextDataTooBig => fatal("Patch text section too large\n", .{}),
            error.FailedToCreateRom => fatal("Patch script section too large\n", .{}),
        };
    } else if (std.mem.eql(u8, subcommand, "fix-mariposa")) {
        const fix_mariposa_args = parseFixMariposaCommandArgs(args[2..]) catch {
            fatal(help_text, .{});
        };
        fixMariposaCommand(fix_mariposa_args) catch |err| switch(err) {
            error.FailedToOpenRom => {
                fatal("Failed to open rom file \"{s}\"\n", .{fix_mariposa_args.rom_path});
            },
            error.FailedToWriteToRom => {
                fatal("Failed to to write mariposa patch to rom file \"{s}\"\n", .{fix_mariposa_args.rom_path});
            },
        };
    } else {
        fatal(help_text, .{});
    }
}

fn calculateSegaHeaderChecksum(rom_bytes: []const u8) !u16 {
    if (rom_bytes.len % 2 != 0) return error.RomOddLegth;

    var checksum: u16 = 0;
    var i: usize = 0x200;
    while (i < rom_bytes.len) : (i += 2) {
        checksum +%= std.mem.readInt(u16, rom_bytes[i..][0..2], .big);
    }

    return checksum;
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
    dest_level_id: u8,
    output_rom_path: []const u8,
};

fn parsePatchRomCommandArgs(args: []const []const u8) !PatchRomCommandArgs {
    var input_rom_path: ?[]const u8 = null;
    var input_ecl_path: ?[]const u8 = null;
    var dest_level_id: ?u8 = null;
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
                dest_level_id = std.fmt.parseUnsigned(u8, arg, 0) catch {
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

    const result = PatchRomCommandArgs{
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

    return result;
}

const ExtractAllCommandError = error{
    FailedToCreateOrOpenOutputDir,
    FailedToOpenRom,
    FailedToReadRom,
    InvalidDataWhileDecoding,
    FailedToDisassembleEcl,
    FailedToWriteEcl,
    OutOfMemory,
};

fn extractAllCommand(gpa: std.mem.Allocator, args: ExtractAllCommandArgs) ExtractAllCommandError!void {
    var rom_file = std.fs.cwd().openFile(args.input_rom_path, .{}) catch return error.FailedToOpenRom;
    defer rom_file.close();
    
    var out_dir = std.fs.cwd().makeOpenPath(args.output_dir_path, .{}) catch return error.FailedToCreateOrOpenOutputDir;
    defer out_dir.close();

    const address_table = try readRomEclAddressTable(&rom_file);
    
    var read_buf: [1024]u8 = undefined;
    var rom_reader = rom_file.reader(&read_buf);
    var decoder = try lzw.Decoder.init(gpa);
    defer decoder.deinit(gpa);
    for (level_ids) |id| {
        decoder.reset();
        const bin_script = blk: {
            const script_start_addr, _ = address_table.getScriptAddressAndLenById(id) catch panic("encountered invalid level id {d}\n", .{id});
            rom_reader.seekTo(script_start_addr) catch return error.FailedToReadRom;
            
            var allocating_writer = std.io.Writer.Allocating.init(gpa);
            defer allocating_writer.deinit();
            
            decoder.decompress(&rom_reader.interface, &allocating_writer.writer, null) catch |err| switch(err) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.FailedToReadRom,
                error.EndOfStream => return error.InvalidDataWhileDecoding,
                error.InvalidCode => return error.InvalidDataWhileDecoding,
            };
            break :blk try allocating_writer.toOwnedSlice();
        };
        defer gpa.free(bin_script);
        
        decoder.reset();
        const bin_text = blk: {
            const text_start_addr, _ = address_table.getTextAddressAndLenById(id) catch panic("encountered invalid level id {d}\n", .{id});
            rom_reader.seekTo(text_start_addr) catch return error.FailedToReadRom;
            
            var allocating_writer = std.io.Writer.Allocating.init(gpa);
            defer allocating_writer.deinit();
            
            decoder.decompress(&rom_reader.interface, &allocating_writer.writer, null) catch |err| switch(err) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.FailedToReadRom,
                error.EndOfStream => return error.InvalidDataWhileDecoding,
                error.InvalidCode => return error.InvalidDataWhileDecoding,
            };
            break :blk try allocating_writer.toOwnedSlice();
        };
        defer gpa.free(bin_text);
        
        const initial_highest = if (id == 0x60) 0x907 + ecl_base else null;
        var ast = ecl.binary_parser.parseAlloc(gpa, bin_script, bin_text, initial_highest) catch |err| switch(err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FailedToDisassembleEcl,
        };
        defer ast.deinit();

        var buf: [6]u8 = undefined;
        const filename = std.fmt.bufPrint(&buf, "{d:0>2}.ecl", .{id}) catch unreachable;
        var out_file = out_dir.createFile(filename, .{}) catch return error.FailedToWriteEcl;
        defer out_file.close();
        
        var write_buf: [1024]u8 = undefined;
        var out_writer = out_file.writer(&write_buf);
        ast.serializeText(&out_writer.interface) catch |err| switch(err) {
            error.WriteFailed => return error.FailedToWriteEcl,
        };
    }
}

fn patchRomCommand(gpa: std.mem.Allocator, args: PatchRomCommandArgs) !void {
    var in_rom = std.fs.cwd().openFile(args.input_rom_path, .{}) catch return error.FailedToOpenRom;
    defer in_rom.close();
    const address_table = try readRomEclAddressTable(&in_rom);

    var out_rom_bytes = blk: {
        var in_rom_reader = in_rom.reader(&.{});
        const in_rom_size = in_rom_reader.getSize() catch return error.FailedToReadRom;
        const rom_bytes = in_rom_reader.interface.readAlloc(gpa, in_rom_size) catch |err| switch(err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.FailedToReadRom,
            error.EndOfStream => unreachable,
        };
        break :blk rom_bytes;
    };
    defer gpa.free(out_rom_bytes);

    var in_ecl = std.fs.cwd().openFile(args.input_ecl_path, .{}) catch return error.FailedToOpenEcl;
    defer in_ecl.close();

    const in_ecl_bytes = in_ecl.readToEndAlloc(gpa, 1024 * 1024 * 1024) catch |err| switch(err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooBig => return error.EclFileTooBig,
        else => return error.FailedToReadEcl,
    };
    defer gpa.free(in_ecl_bytes);

    var parsed_ecl = blk: {
        var parser = ecl.TextParser.init(gpa);
        defer parser.deinit();

        break :blk parser.parse(in_ecl_bytes) catch |err| switch(err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TokenizationFailed, error.ParsingFailed => return error.FailedToParseEcl,
        };
    };
    defer parsed_ecl.deinit();

    const ecl_binary = parsed_ecl.serializeBinary(gpa) catch |err| switch(err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    defer gpa.free(ecl_binary.script);
    defer gpa.free(ecl_binary.text);

    {
        const compressed_script = blk: {
            var encoder = try lzw.Encoder.init(gpa);
            defer encoder.deinit(gpa);
            var fbs = std.io.fixedBufferStream(ecl_binary.script);
            var output = std.array_list.Managed(u8).init(gpa);
            defer output.deinit();
            encoder.compress(output.writer(), fbs.reader()) catch |err| switch(err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => unreachable,
            };
            break :blk try output.toOwnedSlice();
        };
        defer gpa.free(compressed_script);

        const dest_start, const dest_len = address_table.getScriptAddressAndLenById(args.dest_level_id) catch {
            panic("invalid destination level id {d}\n", .{ args.dest_level_id });
        };
        if (compressed_script.len > dest_len) {
            fatal("resulting script data larger than original data: {d} bytes (original {d})\n", .{ compressed_script.len, dest_len });
            return error.ScriptDataTooBig;
        }

        std.mem.copyForwards(u8, out_rom_bytes[dest_start..][0..dest_len], compressed_script);
    }

    {
        const compressed_text = blk: {
            var encoder = try lzw.Encoder.init(gpa);
            defer encoder.deinit(gpa);
            var fbs = std.io.fixedBufferStream(ecl_binary.text);
            var output = std.array_list.Managed(u8).init(gpa);
            defer output.deinit();
            encoder.compress(output.writer(), fbs.reader()) catch |err| switch(err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => unreachable,
            };
            break :blk output.toOwnedSlice() catch fatal("out of memory\n", .{});
        };
        defer gpa.free(compressed_text);

        const dest_start, const dest_len = address_table.getTextAddressAndLenById(args.dest_level_id) catch {
            panic("invalid destination level id {d}\n", .{ args.dest_level_id });
        };
        
        if (compressed_text.len > dest_len) {
            return error.TextDataTooBig;
            // fatal("resulting text data larger than original data: {d} bytes (original {d})\n", .{ compressed_text.len, dest_len });
        }

        std.mem.copyForwards(u8, out_rom_bytes[dest_start..][0..dest_len], compressed_text);
    }

    {
        fixRomChecksum(out_rom_bytes);
    }

    var out_rom = std.fs.cwd().createFile(args.output_rom_path, .{}) catch return error.FailedToCreateRom;
    defer out_rom.close();

    out_rom.writeAll(out_rom_bytes) catch return error.FailedToCreateRom;
}

const FixMariposaError = error {
    FailedToOpenRom,
    FailedToWriteToRom,
};

fn fixMariposaCommand(args: FixMariposaCommandArgs) FixMariposaError!void {
    var rom = std.fs.cwd().openFile(args.rom_path, .{ .mode = .write_only }) catch return error.FailedToOpenRom;
    defer rom.close();

    var write_buf: [2]u8 = undefined;
    var w = rom.writer(&write_buf);
    w.seekTo(0x4fadb) catch return error.FailedToWriteToRom;
    w.interface.writeInt(u16, 0x1010, .big) catch return error.FailedToWriteToRom;
    w.interface.flush() catch return error.FailedToWriteToRom;
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

fn fixRomChecksum(rom_bytes: []u8) void {
    // first overwrite game-specific checksum code with some no-ops
    const m68k_nop_code: u16 = 0x4e71;
    std.mem.writeInt(u16, rom_bytes[0x300..][0..2], m68k_nop_code, .big);
    std.mem.writeInt(u16, rom_bytes[0x302..][0..2], m68k_nop_code, .big);
    std.mem.writeInt(u16, rom_bytes[0x304..][0..2], m68k_nop_code, .big);

    // calculate standard sega header checksum and patch the rom with that
    const sega_checksum = calculateSegaHeaderChecksum(rom_bytes) catch |err| {
        fatal("failed to calculate rom checksum, error: {s}\n", .{@errorName(err)});
    };
    std.mem.writeInt(u16, rom_bytes[0x18e..][0..2], sega_checksum, .big);
}

const num_levels = 27;
const level_ids = [num_levels]u8{ 0x00, 0x01, 0x03, 0x10, 0x11, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x34, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63 };

const RomEclAddressTable = struct {
    
    const script_section_end_addr = 0x42b0a;
    const text_section_end_addr = 0x51102;
    
    script_addrs: [num_levels]u32,
    text_addrs: [num_levels]u32,

    pub fn getScriptAddressAndLenById(table: *const RomEclAddressTable, level_id: u8) Error!struct {u32, u32} {
        const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.InvalidLevelId;

        const is_last_level = level_index == num_levels - 1;
        
        const start_addr = table.script_addrs[level_index];
        const end_addr = if (is_last_level) script_section_end_addr else table.script_addrs[level_index + 1];
        
        return .{start_addr, end_addr - start_addr};
    }

    pub fn getTextAddressAndLenById(table: *const RomEclAddressTable, level_id: u8) Error!struct {u32, u32} {
        const level_index = std.mem.indexOfScalar(u8, &level_ids, level_id) orelse return error.InvalidLevelId;

        const is_last_level = level_index == num_levels - 1;
        
        const start_addr = table.text_addrs[level_index];
        const end_addr = if (is_last_level) text_section_end_addr else table.text_addrs[level_index + 1];
        
        return .{start_addr, end_addr - start_addr};
    }

    const Error = error{
        InvalidLevelId,
    };
};

fn readRomEclAddressTable(rom_file: *std.fs.File) error{FailedToReadRom}!RomEclAddressTable {
    const script_offset_table_addr = 0x38d02;
    const text_offset_table_addr = 0x42b2a;
    const old_pos = rom_file.getPos() catch return error.FailedToReadRom;

    var result = RomEclAddressTable { .script_addrs = undefined, .text_addrs = undefined, };

    var read_buf: [512]u8 = undefined;
    var r = rom_file.reader(&read_buf);

    r.seekTo(script_offset_table_addr) catch return error.FailedToReadRom;
    for (&result.script_addrs) |*address| {
        const offset = r.interface.takeInt(u32, .big) catch return error.FailedToReadRom;
        address.* = script_offset_table_addr + offset;
    }
    
    r.seekTo(text_offset_table_addr) catch return error.FailedToReadRom;
    for (&result.text_addrs) |*address| {
        const offset = r.interface.takeInt(u32, .big) catch return error.FailedToReadRom;
        address.* = text_offset_table_addr + offset;
    }

    rom_file.seekTo(old_pos) catch return error.FailedToReadRom;

    return result;
}

const help_text =
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
;

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

    var compressed = std.array_list.Managed(u8).init(allocator);
    defer compressed.deinit();
    {
        var fbs = std.io.fixedBufferStream(input);
        try encoder.compress(compressed.writer(), fbs.reader());
        // try compressed.appendSlice("\x00\x00\x00\x00");
    }
    
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    {
        var fbs = std.io.fixedBufferStream(compressed.items);
        try decoder.decompress(fbs.reader(), output.writer(), null);
    }
    try std.testing.expectEqualSlices(u8, std.mem.trimRight(u8, input, "\x00"), std.mem.trimRight(u8, output.items, "\x00"));
    // try std.testing.expectEqualSlices(u8, input, output.items);
}

const std = @import("std");

const File = std.fs.File;

const ecl = @import("ecl.zig");
const lzw = @import("lzw.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_base: u16 = 0x6af6;

const tokenize = @import("ecl/tokenize.zig");

const input_ecl_path = "new_16.ecl";
const input_rom_path = "buck.md";
const output_rom_path = "buck rodgers buc05.u1"; // crazy default name for MAME

pub fn main() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Parsing \"{s}\"\n", .{input_ecl_path});
    var ast = try parseFile(allocator, input_ecl_path);
    defer ast.deinit();

    const ecl_binary = try ast.serializeBinary(allocator);
    defer allocator.free(ecl_binary.script);
    defer allocator.free(ecl_binary.text);

    std.debug.print("Reading rom data from \"{s}\"\n", .{input_rom_path});
    const in_rom = try std.fs.cwd().openFile(input_rom_path, .{});
    defer in_rom.close();

    var rom_bytes = try in_rom.readToEndAlloc(allocator, 1024 * 1024 * 4);
    defer allocator.free(rom_bytes);

    {
        const compressed_script = blk: {
            var encoder = try lzw.Encoder.init(allocator);
            defer encoder.deinit();
            break :blk try encoder.compressAlloc(allocator, ecl_binary.script);
        };
        defer allocator.free(compressed_script);

        const dest_start, const dest_end = try ecl.getScriptAddrs(in_rom, 0x10);
        const max_script_size = dest_end - dest_start;
        if (compressed_script.len > max_script_size) {
            std.debug.print("resulting script too long: {d} (max {d})\n", .{ compressed_script.len, max_script_size });
            return;
        }

        std.mem.copyForwards(u8, rom_bytes[dest_start..dest_end], compressed_script);
    }

    {
        const compressed_text = blk: {
            var encoder = try lzw.Encoder.init(allocator);
            defer encoder.deinit();
            break :blk try encoder.compressAlloc(allocator, ecl_binary.text);
        };
        defer allocator.free(compressed_text);

        const dest_start, const dest_end = try ecl.getTextAddrs(in_rom, 0x10);
        const max_text_size = dest_end - dest_start;

        if (compressed_text.len > max_text_size) {
            std.debug.print("resulting text too long: {d} (max {d})\n", .{ compressed_text.len, max_text_size });
        }

        std.mem.copyForwards(u8, rom_bytes[dest_start..dest_end], compressed_text);
    }

    // turn checksum check into NOP
    rom_bytes[0xfffd0] = 0x4e;
    rom_bytes[0xfffd1] = 0x71;

    var out_rom = try std.fs.cwd().createFile(output_rom_path, .{});
    defer out_rom.close();

    try out_rom.writeAll(rom_bytes);
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

const std = @import("std");

const CommandParser = @import("command.zig").CommandParser;

const GPA = std.heap.GeneralPurposeAllocator(.{});

// const ecl_offset = 0x6af6;
// const level_text_offset = 0x731c;
const memdump_path = "memdump";

pub fn main() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile(memdump_path, .{});
    defer file.close();

    const genesis_mem = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(genesis_mem);

    var parser = CommandParser.init(allocator, genesis_mem);
    defer parser.deinit();

    const ecl_header = parser.parseEclHeader();

    try parser.parseCommandsRecursively(ecl_header.first_command_address);
    try parser.parseCommandsRecursively(0x6c13);

    {
        var it = parser.vars.iterator();
        while (it.next()) |e| {
            std.debug.print("{s} {x}\n", .{ @tagName(e.value_ptr.*), e.key_ptr.* });
        }
    }

    for (parser.blocks.items) |block| {
        std.debug.print("\nBLOCK {x} - {x}\n", .{ block.start_addr, block.end_addr });
        for (parser.getBlockCommands(block)) |command| {
            std.debug.print("{s}", .{@tagName(command.tag)});
            for (parser.getCommandArgs(command)) |arg| {
                std.debug.print(" ", .{});
                try arg.writeString(std.io.getStdErr().writer());
            }
            std.debug.print("\n", .{});
        }
    }
}

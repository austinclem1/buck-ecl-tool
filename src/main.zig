const std = @import("std");

const CommandParser = @import("command.zig").CommandParser;

const GPA = std.heap.GeneralPurposeAllocator(.{});

// const ecl_offset = 0x6af6;
// const level_text_offset = 0x731c;
const memdump_path = "shipmemdump";

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

    try parser.parseCommandsRecursively(ecl_header.a);
    try parser.parseCommandsRecursively(ecl_header.b);
    try parser.parseCommandsRecursively(ecl_header.c);
    try parser.parseCommandsRecursively(ecl_header.d);
    try parser.parseCommandsRecursively(ecl_header.first_command_address);

    parser.sortLabelsByAddress();

    parser.sortVarsByAddress();
    var it = parser.vars.iterator();
    while (it.next()) |e| {
        std.debug.print("{s} {x}\n", .{ @tagName(e.value_ptr.*), e.key_ptr.* });
    }

    std.debug.print("\nblocks:\n", .{});
    for (parser.blocks.items, 0..) |block, i| {
        if (i > 0) {
            const last_block = parser.blocks.items[i - 1];
            if (block.start_addr > last_block.end_addr) {
                std.debug.print("found gap between {x} and {x}\n", .{ last_block.end_addr, block.start_addr });
            }
        }
        std.debug.print("BLOCK {x} - {x}\n", .{ block.start_addr, block.end_addr });
    }
    var labels_it = parser.labels.iterator();
    var next_label = labels_it.next();
    for (parser.blocks.items) |block| {
        std.debug.print("\nBLOCK {x} - {x}\n", .{ block.start_addr, block.end_addr });
        for (parser.getBlockCommands(block)) |command| {
            if (next_label) |label| {
                if (command.address == label.key_ptr.*) {
                    std.debug.print("LABEL_{x}:\n", .{label.key_ptr.*});
                    next_label = labels_it.next();
                }
            }
            std.debug.print("{s}", .{@tagName(command.tag)});
            for (parser.getCommandArgs(command)) |arg| {
                std.debug.print(" ", .{});
                try arg.writeString(std.io.getStdErr().writer());
            }
            std.debug.print("\n", .{});
        }
    }
}

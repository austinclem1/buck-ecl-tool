const std = @import("std");

const command = @import("command.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_offset = 0x6af6;
const level_text_offset = 0x731c;
const memdump_path = "memdump";

pub fn main() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile(memdump_path, .{});
    defer file.close();

    const genesis_mem = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(genesis_mem);

    const command_blocks = try command.parseCommandsRecursively(allocator, genesis_mem);
    for (command_blocks) |block| {
        std.debug.print("{x} - {x}\n", .{ block.start_addr, block.end_addr });
        for (block.commands) |cmd| {
            std.debug.print("{any}\n", .{cmd});
        }
    }
    for (command_blocks) |block| {
        for (block.commands) |cmd| {
            allocator.free(cmd.args);
        }
        allocator.free(block.commands);
    }
    allocator.free(command_blocks);
}

const EclHeader = struct {
    a: u16,
    b: u16,
    c: u16,
    d: u16,
    first_command_offset: u16,
};

fn parseEclHeader(reader: anytype) !EclHeader {
    try reader.skipBytes(2, .{});
    const a = try reader.readIntLittle(u16);

    try reader.skipBytes(2, .{});
    const b = try reader.readIntLittle(u16);

    try reader.skipBytes(2, .{});
    const c = try reader.readIntLittle(u16);

    try reader.skipBytes(2, .{});
    const d = try reader.readIntLittle(u16);

    try reader.skipBytes(2, .{});
    const first_command_offset = try reader.readIntLittle(u16);

    return .{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
        .first_command_offset = first_command_offset,
    };
}

// fn parseCommand(reader: anytype) !Command {
//     const code = try reader.readByte();
//     const tag: CommandTag = @enumFromInt(code);
//     // switch (tag) {
//     //     inline else => |t| {
//     //         // const CommandData = std.meta.TagPayload(Command, t);
//     //         // var data: CommandData = undefined;
//     //         // inline for (std.meta.fields(CommandData)) |field| {
//     //         // inline for (@typeInfo(CommandData).Struct.fields) |field| {
//     //         //     @field(data, field.name) = try parseCommandArg(reader);
//     //         // }
//     //         // return @unionInit(Command, @tagName(t), data);
//     //         @compileLog(t);
//     //         @compileLog(std.meta.TagPayload(Command, t));
//     //         @compileLog(std.meta.fields(std.meta.TagPayload(Command, t)));
//     //         inline for (std.meta.fields(std.meta.TagPayload(Command, t))) |field| {
//     //             @compileLog(field);
//     //         }
//     //
//     //         // return t;
//     //         return .EXIT;
//     //     },
//     // }
//     switch (tag) {
//         .EXIT => {
//             return .EXIT;
//         },
//         .GOTO => {
//             return .{ .GOTO = .{
//                 .dest = try parseCommandArg(reader),
//             } };
//         },
//         .SOUND => {
//             return .{ .SOUND = .{
//                 .sound = try parseCommandArg(reader),
//             } };
//         },
//         else => {
//             return .ICONMENU;
//         },
//     }
// }

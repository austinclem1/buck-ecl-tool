const std = @import("std");

const command = @import("command3.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});
//6bac

const ecl_offset = 0x6af6;
const level_text_offset = 0x731c;
const memdump_path = "memdump";

pub fn main() !void {
    command.printCommandNamesAndArgCount();
    var gpa = GPA{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile(memdump_path, .{});
    defer file.close();

    const genesis_ram = try file.reader().readAllAlloc(allocator, 64 * 1024);
    defer allocator.free(genesis_ram);

    // var buf_reader = std.io.bufferedReader(file.reader());
    // const reader = buf_reader.reader();
    var fbs = std.io.fixedBufferStream(genesis_ram);
    const reader = fbs.reader();

    try fbs.seekTo(ecl_offset);
    const header = try parseEclHeader(reader);

    std.debug.print("{any}\n", .{header});

    try fbs.seekTo(header.first_command_offset);
    // try fbs.seekTo(header.b);
    // try fbs.seekTo(0x6ce3);

    // while (fbs.pos < header.c) {
    while (true) {
        const c = try command.readCommandBinary(reader);
        std.debug.print("{x} {}\n", .{ fbs.pos, c });

        // if (c == .EXIT) break;
    }

    // // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    //
    // // stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    //
    // try stdout.print("Run `zig build test` to run the tests.\n", .{});
    //
    // try bw.flush(); // don't forget to flush!
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

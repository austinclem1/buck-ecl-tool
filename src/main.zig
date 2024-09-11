const std = @import("std");

const File = std.fs.File;

const ecl = @import("ecl.zig");
const LzwDecoder = @import("LzwDecoder.zig");

const GPA = std.heap.GeneralPurposeAllocator(.{});

const ecl_base: u16 = 0x6af6;

const tokenize = @import("ecl/tokenize.zig");

pub fn main() !void {}

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Encoder = @This();

bit_buffer: BitBuffer = .{},
arena: std.heap.ArenaAllocator,
dict: std.MultiArrayList(DictEntry),
code_width: u4 = initial_code_width,
cur_prefix: u16 = 0,
on_first_byte: bool = true,

const initial_code_width = 9;
const max_code_width = 12;
const clear_code = 0x100;
const end_code = 0x101;
const dict_max_len = (@as(u16, 1) << @intCast(max_code_width)) - 1;

const DictEntry = struct {
    prefix: u16,
    suffix: u8,
};

pub fn init(backing_allocator: Allocator) Allocator.Error!Encoder {
    var e = Encoder{
        .arena = std.heap.ArenaAllocator.init(backing_allocator),
        .dict = .{},
    };
    errdefer e.arena.deinit();

    try e.dict.ensureUnusedCapacity(e.arena.allocator(), end_code + 1);
    for (0..0x100) |i| {
        e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = @intCast(i) });
    }
    // add dummy entries for CLEAR and END codes
    e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });
    e.dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });

    return e;
}

pub fn deinit(self: *Encoder) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn compressAlloc(self: *Encoder, allocator: Allocator, input_bytes: []const u8) ![]u8 {
    var out_buffer = std.ArrayList(u8).init(allocator);
    defer out_buffer.deinit();

    for (input_bytes) |ch| {
        if (self.on_first_byte) {
            self.on_first_byte = false;
            self.cur_prefix = ch;
            continue;
        }

        if (self.indexOfMatchingEntry(self.cur_prefix, ch)) |match| {
            self.cur_prefix = match;
        } else {
            try self.writeCode(self.cur_prefix, out_buffer.writer());
            try self.maybeUpdateDictAndCodeWidth(ch);
            self.cur_prefix = ch;
        }
    }

    try self.writeCode(self.cur_prefix, out_buffer.writer());
    try self.writeCode(end_code, out_buffer.writer());

    const remaining_bits = self.bit_buffer.readAll();
    try out_buffer.writer().writeInt(u32, remaining_bits, .big);
    if (out_buffer.items.len % 2 == 1) try out_buffer.append(0);

    return try out_buffer.toOwnedSlice();
}

fn writeCode(self: *Encoder, code: u16, writer: anytype) !void {
    while (self.bit_buffer.readByte()) |byte| {
        try writer.writeByte(byte);
    }

    const lower_bits_mask = (@as(u16, 1) << @intCast(self.code_width - 1)) - 1;

    const dict_len_masked = (self.dict.len - 1) & lower_bits_mask;
    const code_masked = code & lower_bits_mask;

    try self.bit_buffer.writeBits(code_masked, self.code_width - 1);
    if (code_masked <= dict_len_masked) {
        const most_sig_bit = getBitAt(code, @intCast(self.code_width - 1));
        try self.bit_buffer.writeBits(most_sig_bit, 1);
    }
}

fn maybeUpdateDictAndCodeWidth(self: *Encoder, suffix: u8) Allocator.Error!void {
    if (self.dict.len >= dict_max_len) {
        return;
    }

    const new_entry = .{ .prefix = self.cur_prefix, .suffix = suffix };
    try self.dict.append(self.arena.allocator(), new_entry);

    const code_widening_threshold = (@as(u16, 1) << @intCast(self.code_width));
    if (self.dict.len >= code_widening_threshold and self.code_width < max_code_width) {
        self.code_width += 1;
    }
}

fn indexOfMatchingEntry(self: *Encoder, prefix: u16, suffix: u8) ?u16 {
    const dict_prefixes = self.dict.items(.prefix);
    const dict_suffixes = self.dict.items(.suffix);

    var i: u16 = @max(prefix + 1, end_code + 1);
    while (i < self.dict.len) : (i += 1) {
        if (dict_prefixes[i] == prefix and dict_suffixes[i] == suffix) {
            return i;
        }
    }

    return null;
}

fn getBitAt(val: u16, index: u4) u1 {
    return @intCast((val >> index) & 1);
}

const BitBuffer = struct {
    backing_int: u32 = 0,
    open_bits: u6 = bit_size,

    const bit_size = 32;

    pub fn writeBits(self: *BitBuffer, val: u32, bit_count: u6) !void {
        if (self.open_bits < bit_count) return error.OutOfSpace;

        const shift_amt: u5 = @intCast(self.open_bits - bit_count);
        self.backing_int |= (val << shift_amt);
        self.open_bits -= bit_count;
    }

    pub fn readByte(self: *BitBuffer) ?u8 {
        if (self.open_bits > (bit_size - 8)) return null;

        const byte: u8 = @intCast(self.backing_int >> (bit_size - 8));

        self.backing_int <<= 8;
        self.open_bits += 8;

        return byte;
    }

    pub fn readAll(self: *BitBuffer) u32 {
        const result = self.backing_int;
        self.backing_int = 0;
        self.open_bits = bit_size;
        return result;
    }
};

// pub fn debugPrintDict(self: *const Self) void {
//     var start: usize = end_code + 1;
//     while (start < self.dict.len) : (start += 0x10) {
//         const end = @min(start + 0x10, self.dict.len);
//
//         std.debug.print("0x{x}:\n", .{start});
//         for (self.dict.items(.suffix)[start..end]) |s| {
//             if (std.ascii.isPrint(s)) {
//                 std.debug.print("\'{c}\' ", .{s});
//             } else {
//                 std.debug.print("{x:0>3} ", .{s});
//             }
//         }
//         std.debug.print("\n", .{});
//
//         for (self.dict.items(.prefix)[start..end]) |p| {
//             if (p < 128 and std.ascii.isPrint(@intCast(p))) {
//                 std.debug.print("\'{c}\' ", .{@as(u8, @intCast(p))});
//             } else {
//                 std.debug.print("{x:0>3} ", .{p});
//             }
//         }
//         std.debug.print("\n\n", .{});
//     }
// }

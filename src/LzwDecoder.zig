const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const LzwDecoder = @This();

allocator: Allocator,
bit_buffer: u32,
bit_buffer_open_bits: u6,
dict: MultiArrayList(DictEntry),
decoding_scratch_space: ArrayListUnmanaged(u8),

cur_code_width: u4,

const initial_code_width = 9;
const max_code_width = 12;

const clear_code = 0x100;
const end_code = 0x101;

const max_prefix_len = 0x1000;
const prefix_end_sentinal = std.math.maxInt(u16);

const bit_buffer_capacity = @bitSizeOf(u32);

const dict_initial_len = end_code + 1;
const dict_initial_capacity: u16 = (1 << initial_code_width) - 1;
const dict_max_len: u16 = (1 << max_code_width) - 1;

const DictEntry = struct {
    prefix: u16,
    suffix: u8,
};

pub fn init(allocator: Allocator) Allocator.Error!LzwDecoder {
    var dict = MultiArrayList(DictEntry){};
    errdefer dict.deinit(allocator);

    try dict.ensureTotalCapacity(allocator, dict_initial_capacity);

    for (0..0x100) |i| {
        dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = @intCast(i) });
    }
    // append dummy values for CLEAR and END codes
    dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = 0 });
    dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = 0 });

    return LzwDecoder{
        .allocator = allocator,
        .bit_buffer = 0,
        .bit_buffer_open_bits = bit_buffer_capacity,
        .dict = dict,
        .decoding_scratch_space = ArrayListUnmanaged(u8){},
        .cur_code_width = initial_code_width,
    };
}

pub fn deinit(self: *LzwDecoder) void {
    self.dict.deinit(self.allocator);
    self.decoding_scratch_space.deinit(self.allocator);
    self.* = undefined;
}

pub fn resetClearingCapacity(self: *LzwDecoder) void {
    self.bit_buffer = 0;
    self.bit_buffer_open_bits = bit_buffer_capacity;
    self.dict.shrinkAndFree(self.allocator, dict_initial_len);
    self.decoding_scratch_space.clearAndFree(self.allocator);
    self.cur_code_width = initial_code_width;
}

pub fn resetRetainingCapacity(self: *LzwDecoder) void {
    self.bit_buffer = 0;
    self.bit_buffer_open_bits = bit_buffer_capacity;
    self.dict.shrinkRetainingCapacity(dict_initial_len);
    self.decoding_scratch_space.clearRetainingCapacity();
    self.cur_code_width = initial_code_width;
}

pub fn decompressAlloc(self: *LzwDecoder, result_allocator: Allocator, reader: anytype) ![]u8 {
    var out_buffer = ArrayList(u8).init(result_allocator);
    errdefer out_buffer.deinit();

    var on_first_code = true;
    var last_code: u16 = undefined;
    while (true) {
        const code = try self.readCode(reader);

        if (code == end_code) break;

        if (code == clear_code) {
            self.dict.shrinkRetainingCapacity(dict_initial_len);
            self.cur_code_width = initial_code_width;
            last_code = undefined;
            on_first_code = true;
            continue;
        }

        try self.decodeCode(code, last_code);

        const new_entry_suffix = self.decoding_scratch_space.getLast();

        while (self.decoding_scratch_space.popOrNull()) |ch| {
            try out_buffer.append(ch);
        }

        if (on_first_code) {
            on_first_code = false;
            last_code = code;
            continue;
        }

        if (self.dict.len < dict_max_len) {
            self.dict.appendAssumeCapacity(.{ .prefix = last_code, .suffix = new_entry_suffix });

            const code_widening_threshold = (@as(u16, 1) << self.cur_code_width) - 1;
            const should_widen_code = self.dict.len == code_widening_threshold and self.cur_code_width < max_code_width;
            if (should_widen_code) {
                self.cur_code_width += 1;
                const new_capacity = (@as(u16, 1) << self.cur_code_width) - 1;
                try self.dict.ensureTotalCapacity(self.allocator, new_capacity);
            }
        }

        last_code = code;
    }

    // The decompression code in-game actually keeps this final byte, but then returns the
    // length of the decompressed bytes NOT including this last odd byte
    // Every example I've seen so far from ECL scripts and text just have a null byte as
    // the last one if it happens to be an odd number of decompressed bytes
    if (out_buffer.items.len % 2 == 1) {
        _ = out_buffer.pop();
    }

    return try out_buffer.toOwnedSlice();
}

pub fn decodeCode(self: *LzwDecoder, code: u16, last_code: u16) (Allocator.Error || error{ReachedPrefixLengthLimit})!void {
    // this can the length of the dictionary, indexing the entry that's about to be created
    std.debug.assert(code <= self.dict.len);
    var cur_node: u16 = blk: {
        if (code == self.dict.len) {
            std.debug.print("dict_len: {x}, code: {x}\n", .{ self.dict.len, code });
            const prev_suffix = self.dict.items(.suffix)[self.dict.len - 1];
            try self.decoding_scratch_space.append(self.allocator, prev_suffix);
            break :blk last_code;
        } else {
            break :blk code;
        }
    };

    while (cur_node != prefix_end_sentinal) {
        const character = self.dict.items(.suffix)[cur_node];
        try self.decoding_scratch_space.append(self.allocator, character);

        if (self.decoding_scratch_space.items.len >= max_prefix_len) {
            return error.ReachedPrefixLengthLimit;
        }

        cur_node = self.dict.items(.prefix)[cur_node];
    }
}

fn readCode(self: *LzwDecoder, reader: anytype) (@TypeOf(reader).Error || error{EndOfStream})!u16 {
    // read bytes until bit_buffer is too full to add any more
    while (self.bit_buffer_open_bits >= 8) {
        const new_byte = try reader.readByte();

        const initial_offset = 8;
        const desired_offset = self.bit_buffer_open_bits;
        const desired_offset_delta: u5 = @intCast(desired_offset - initial_offset);

        const new_byte_shifted = @as(u32, new_byte) << desired_offset_delta;

        self.bit_buffer |= new_byte_shifted;

        self.bit_buffer_open_bits -= 8;
    }

    const short_code_width = self.cur_code_width - 1;
    const shift_right_amount: u5 = @intCast(@as(u6, bit_buffer_capacity) - short_code_width);
    var code: u16 = @intCast(self.bit_buffer >> shift_right_amount);

    self.bit_buffer <<= short_code_width;
    self.bit_buffer_open_bits += short_code_width;

    const might_index_dict_upper_portion = blk: {
        // the wrapping subtraction is necessary, right after the cur_code_width widens this will
        // wrap around to maxInt(u16) causing this to always break with `true`
        const lower_portion_len = @as(u16, 1) << (self.cur_code_width - 1);
        const upper_portion_len = self.dict.len -% lower_portion_len;
        break :blk code <= upper_portion_len;
    };

    if (might_index_dict_upper_portion) {
        const ov = @shlWithOverflow(self.bit_buffer, 1);
        self.bit_buffer = ov[0];

        self.bit_buffer_open_bits += 1;

        const code_most_sig_bit = ov[1];
        const most_sig_bit_shifted = @as(u16, code_most_sig_bit) << (self.cur_code_width - 1);
        code |= most_sig_bit_shifted;
    }

    return code;
}

fn debugPrintDict(self: *const LzwDecoder) void {
    var stack = ArrayList(u8).init(self.allocator);
    defer stack.deinit();
    for (0x102..self.dict.len) |i| {
        std.debug.print("{x:0>4}: ", .{i});
        var cur_node = i;
        while (cur_node != prefix_end_sentinal) {
            const char = self.dict.items(.suffix)[cur_node];
            stack.append(char) catch unreachable;
            cur_node = self.dict.items(.prefix)[cur_node];
        }
        while (stack.popOrNull()) |char| {
            std.debug.print("{c}", .{char});
        }
        std.debug.print("\n", .{});
    }
}

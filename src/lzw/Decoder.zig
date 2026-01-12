const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const BitBuffer = @import("BitBuffer.zig");

pub const Decoder = @This();

bit_buffer: BitBuffer,
dict: MultiArrayList(DictEntry),
decoding_buffer: ArrayListUnmanaged(u8),
cur_code_width: u4,
on_first_code: bool,
previous_code: u16,
new_entry_suffix: u8,

const initial_code_width = 9;
const max_code_width = 12;

const clear_code = 0x100;
const end_code = 0x101;

const dict_initial_len = 0x100 + 2; // all u8 vals + clear and end codes
const dict_max_len: u16 = (1 << max_code_width) - 1;

const max_prefix_len = 0x1000;
const prefix_end_sentinal = std.math.maxInt(u16);

const DictEntry = struct {
    prefix: u16,
    suffix: u8,
};

pub fn init(allocator: Allocator) Allocator.Error!Decoder {
    var dict: MultiArrayList(DictEntry) = .empty;
    errdefer dict.deinit(allocator);

    try dict.setCapacity(allocator, dict_max_len);

    for (0..0x100) |i| {
        dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = @intCast(i) });
    }
    // append dummy values for CLEAR and END codes
    dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = 0 });
    dict.appendAssumeCapacity(.{ .prefix = prefix_end_sentinal, .suffix = 0 });

    std.debug.assert(dict.len == dict_initial_len);

    var decoding_buffer = try ArrayListUnmanaged(u8).initCapacity(allocator, max_prefix_len);
    errdefer decoding_buffer.deinit(allocator);

    return Decoder{
        .bit_buffer = .empty,
        .dict = dict,
        .decoding_buffer = decoding_buffer,
        .cur_code_width = initial_code_width,
        .on_first_code = true,
        .previous_code = undefined,
        .new_entry_suffix = undefined,
    };
}

pub fn deinit(self: *Decoder, allocator: Allocator) void {
    self.dict.deinit(allocator);
    self.decoding_buffer.deinit(allocator);
    self.* = undefined;
}

pub fn reset(self: *Decoder) void {
    self.dict.shrinkRetainingCapacity(dict_initial_len);
    self.decoding_buffer.clearRetainingCapacity();
    self.* = .{
        .bit_buffer = .empty,
        .dict = self.dict,
        .decoding_buffer = self.decoding_buffer,
        .cur_code_width = initial_code_width,
        .on_first_code = true,
        .previous_code = undefined,
        .new_entry_suffix = undefined,
    };
}

const DecompressError = error{
    InvalidCode,
    WriteFailed,
    ReadFailed,
    EndOfStream,
};

pub fn decompress(self: *Decoder, reader: *std.Io.Reader, writer: *std.Io.Writer, optional_max_size: ?usize) DecompressError!void {
    var bytes_written: usize = 0;

    main_loop: while (true) {
        if (optional_max_size) |max_size| {
            const space_remaining = max_size - bytes_written;
            const bytes_to_write = @min(self.decoding_buffer.items.len, space_remaining);
            for (0..bytes_to_write) |_| {
                const ch = self.decoding_buffer.pop().?;
                try writer.writeByte(ch);
                bytes_written += 1;
            }
            if (bytes_written >= max_size) break :main_loop;
        } else {
            while (self.decoding_buffer.pop()) |ch| {
                try writer.writeByte(ch);
            }
        }

        const code = try self.readCode(reader);

        if (code == end_code) break :main_loop;

        if (code == clear_code) {
            // `bit_buffer` and `decoding_buffer` may still have data that
            // hasn't been flushed yet, so they aren't reinitialized
            self.dict.shrinkRetainingCapacity(dict_initial_len);
            self.* = .{
                .bit_buffer = self.bit_buffer,
                .dict = self.dict,
                .decoding_buffer = self.decoding_buffer,
                .cur_code_width = initial_code_width,
                .on_first_code = true,
                .previous_code = undefined,
                .new_entry_suffix = undefined,
            };
            continue :main_loop;
        }

        try self.expandCode(code);
        self.new_entry_suffix = self.decoding_buffer.getLast();

        if (self.on_first_code) {
            self.on_first_code = false;
            self.previous_code = code;
            continue :main_loop;
        }

        if (self.dict.len < dict_max_len) {
            self.dict.appendAssumeCapacity(.{ .prefix = self.previous_code, .suffix = self.new_entry_suffix });

            const code_widening_threshold = (@as(u16, 1) << self.cur_code_width) - 1;
            const should_widen_code = self.dict.len >= code_widening_threshold and self.cur_code_width < max_code_width;
            if (should_widen_code) {
                self.cur_code_width += 1;
            }
        }

        self.previous_code = code;
    }

    try writer.flush();
}

fn expandCode(self: *Decoder, code: u16) error{ InvalidCode }!void {
    std.debug.assert(code != clear_code);
    std.debug.assert(code != end_code);

    // this can be the length of the dictionary, indexing the entry that's about to be created
    if (code > self.dict.len) {
        return error.InvalidCode;
    }
    
    var cur_node_idx: u16 = undefined;
    if (code == self.dict.len) {
        if (self.on_first_code) return error.InvalidCode;
        self.decoding_buffer.appendAssumeCapacity(self.new_entry_suffix);
        cur_node_idx = self.previous_code;
    } else {
        cur_node_idx = code;
    }

    while (cur_node_idx != prefix_end_sentinal) {
        const entry = self.dict.get(cur_node_idx);
        self.decoding_buffer.appendAssumeCapacity(entry.suffix);
        cur_node_idx = entry.prefix;
    }
}

fn readCode(self: *Decoder, reader: *std.Io.Reader) !u16 {
    try self.bit_buffer.fill(reader);

    const short_code_width = self.cur_code_width - 1;
    var code: u16 = @intCast(self.bit_buffer.takeNBits(short_code_width));

    const might_index_dict_upper_portion = blk: {
        // the wrapping subtraction is necessary, right after the cur_code_width widens this will
        // wrap around to maxInt(u16) causing this to always break with `true`
        const lower_portion_len = @as(u16, 1) << (self.cur_code_width - 1);
        const upper_portion_len = self.dict.len -% lower_portion_len;
        break :blk code <= upper_portion_len;
    };

    if (might_index_dict_upper_portion) {
        const code_most_sig_bit = self.bit_buffer.takeNBits(1);
        const shifted_bit: u16 = @intCast(code_most_sig_bit << (self.cur_code_width - 1));
        code |= shifted_bit;
    }

    return code;
}

fn debugPrintDict(self: *const Decoder) void {
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
        while (stack.pop()) |char| {
            std.debug.print("{c}", .{char});
        }
        std.debug.print("\n", .{});
    }
}

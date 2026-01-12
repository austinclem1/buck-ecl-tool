const std = @import("std");

const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const BitBuffer = @import("BitBuffer.zig");

pub const Encoder = @This();

bit_buffer: BitBuffer,
dict: std.MultiArrayList(DictEntry),
code_width: u4,
cur_prefix: u16,
on_first_byte: bool,

const initial_code_width = 9;
const max_code_width = 12;
const clear_code = 0x100;
const end_code = 0x101;
const dict_max_len = (@as(u16, 1) << @intCast(max_code_width)) - 1;
const dict_initial_len = 0x100 + 2; // all u8 vals + clear and end codes

const DictEntry = struct {
    prefix: u16,
    suffix: u8,
};

pub fn init(allocator: Allocator) Allocator.Error!Encoder {
    var dict: MultiArrayList(DictEntry) = .empty;
    errdefer dict.deinit(allocator);
    try dict.setCapacity(allocator, dict_max_len);

    for (0..0x100) |i| {
        dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = @intCast(i) });
    }
    // add dummy entries for CLEAR and END codes
    dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });
    dict.appendAssumeCapacity(.{ .prefix = 0, .suffix = 0 });

    std.debug.assert(dict.len == dict_initial_len);

    return .{
        .bit_buffer = .empty,
        .dict = dict,
        .code_width = initial_code_width,
        .cur_prefix = 0,
        .on_first_byte = true,
    };
}

pub fn deinit(self: *Encoder, allocator: Allocator) void {
    self.dict.deinit(allocator);
    self.* = undefined;
}

pub fn compress(self: *Encoder, writer: anytype, reader: anytype) !void {
    var bytes_written: usize = 0;

    while (reader.readByte()) |ch| {
        if (self.on_first_byte) {
            self.on_first_byte = false;
            self.cur_prefix = ch;
            continue;
        }

        if (self.indexOfMatchingEntry(self.cur_prefix, ch)) |match| {
            self.cur_prefix = match;
        } else {
            try self.writeCode(self.cur_prefix);
            bytes_written += try self.bit_buffer.flushFinishedBytes(writer);
            try self.maybeUpdateDictAndCodeWidth(ch);
            self.cur_prefix = ch;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    try self.writeCode(self.cur_prefix);
    bytes_written += try self.bit_buffer.flushFinishedBytes(writer);
    try self.writeCode(end_code);
    bytes_written += try self.bit_buffer.flushFinishedBytes(writer);

    bytes_written += try self.bit_buffer.flushAll(writer);
    if (bytes_written % 2 == 1) try writer.writeByte(0);
}

fn writeCode(self: *Encoder, code: u16) !void {
    const lower_bits_mask = (@as(u16, 1) << @intCast(self.code_width - 1)) - 1;

    const dict_len_masked = (self.dict.len - 1) & lower_bits_mask;
    const code_masked = code & lower_bits_mask;

    self.bit_buffer.writeNBits(code_masked, self.code_width - 1) catch std.debug.panic("BitBuffer overfilled\n", .{});
    if (code_masked <= dict_len_masked) {
        const most_sig_bit = code >> (self.code_width - 1);
        self.bit_buffer.writeNBits(most_sig_bit, 1) catch std.debug.panic("BitBuffer overfilled\n", .{});
    }
}

fn maybeUpdateDictAndCodeWidth(self: *Encoder, suffix: u8) Allocator.Error!void {
    if (self.dict.len >= dict_max_len) {
        return;
    }

    const new_entry = DictEntry{ .prefix = self.cur_prefix, .suffix = suffix };
    self.dict.appendAssumeCapacity(new_entry);

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

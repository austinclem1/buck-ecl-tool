const std = @import("std");
const BitBuffer = @This();

bits: u32,
bits_in_use: u32,

pub const empty = BitBuffer{
    .bits = 0,
    .bits_in_use = 0,
};

pub const bit_capacity = @bitSizeOf(@FieldType(BitBuffer, "bits"));

pub fn bitsFree(self: *const BitBuffer) u32 {
    return bit_capacity - self.bits_in_use;
}

// read bytes until bit_buffer is too full to fit another full byte
pub fn fill(self: *BitBuffer, reader: *std.Io.Reader) !void {
    while (self.bitsFree() >= 8) {
        // const byte = try reader.readByte();
        const byte = try reader.takeByte();

        const initial_offset = 8;
        const desired_offset = self.bitsFree();
        const offset_delta = desired_offset - initial_offset;

        const shifted_byte = @as(u32, byte) << @intCast(offset_delta);

        self.bits |= shifted_byte;
        self.bits_in_use += 8;
    }
}

pub fn takeNBits(self: *BitBuffer, n: u32) u32 {
    std.debug.assert(self.bits_in_use >= n);
    const right_shift_amt = bit_capacity - n;
    const val = self.bits >> @intCast(right_shift_amt);
    self.bits <<= @intCast(n);
    self.bits_in_use -= n;

    return val;
}

pub fn writeNBits(self: *BitBuffer, val: u32, n: u32) error{NotEnoughSpace}!void {
    if (self.bitsFree() < n) return error.NotEnoughSpace;

    const shift_amt = self.bitsFree() - n;
    self.bits |= (val << @intCast(shift_amt));
    self.bits_in_use += n;
}

pub fn flushFinishedBytes(self: *BitBuffer, writer: anytype) !usize {
    var bytes_written: usize = 0;
    while (self.bits_in_use >= 8) : (bytes_written += 1) {
        const byte = self.takeNBits(8);
        try writer.writeByte(@intCast(byte));
    }
    return bytes_written;
}

pub fn flushAll(self: *BitBuffer, writer: anytype) !usize {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, self.bits, .big);
    try writer.writeAll(&bytes);
    self.* = .empty;
    return 4;
}

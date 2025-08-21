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
pub fn fill(self: *BitBuffer, reader: anytype) !void {
    while (self.bitsFree() >= 8) {
        // const byte = try reader.readByte();
        const byte = reader.readByte() catch @panic("read failed\n");

        const initial_offset = 8;
        const desired_offset = self.bitsFree();
        const offset_delta = desired_offset - initial_offset;

        const shifted_byte = @as(u32, byte) << @intCast(offset_delta);

        self.bits |= shifted_byte;
        self.bits_in_use += 8;
    }
}

pub fn takeNBitsWithReader(self: *BitBuffer, n: u32, reader: anytype) u32 {
    while (self.bits_in_use < n) {
        const byte = reader.readByte() catch @panic("read failed\n");

        const initial_offset = 8;
        const desired_offset = self.bitsFree();
        const offset_delta = desired_offset - initial_offset;

        const shifted_byte = @as(u32, byte) << @intCast(offset_delta);

        self.bits |= shifted_byte;
        self.bits_in_use += 8;
    }
    return self.takeNBits(n);
}

pub fn takeNBits(self: *BitBuffer, n: u32) u32 {
    std.debug.assert(self.bits_in_use >= n);
    const right_shift_amt = bit_capacity - n;
    const val = self.bits >> @intCast(right_shift_amt);
    self.bits <<= @intCast(n);
    self.bits_in_use -= n;

    return val;
}

pub fn writeNBits(self: *BitBuffer, val: u32, n: u32, downstream_writer: anytype) !void {
    std.debug.assert(self.bitsFree() >= n);

    const shift_amt = self.bitsFree() - n;
    self.bits |= (val << @intCast(shift_amt));
    self.bits_in_use += n;
    
    while (self.bits_in_use >= 8) {
        const byte = self.takeNBits(8);
        try downstream_writer.writeByte(@intCast(byte));
    }
}

pub fn flush(self: *BitBuffer, writer: anytype) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, self.bits, .big);
    try writer.writeAll(&bytes);
    self.* = .empty;
}

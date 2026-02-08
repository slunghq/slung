//! Gorilla encoding for time series data.
//!
//! Implements the compression algorithms from Facebook's 2015 paper:
//! "Gorilla: A Fast, Scalable, In-Memory Time Series Database"
//!
//! Two main compression techniques:
//! 1. Timestamps: Delta-of-delta encoding with variable bit-width
//! 2. Floats: XOR-based compression exploiting temporal locality

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// BitWriter for writing individual bits to a byte buffer.
/// Bits are written from MSB to LSB within each byte.
pub const BitWriter = struct {
    buffer: []u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0, // 0-7, position within current byte (0 = MSB)

    pub fn init(buffer: []u8) BitWriter {
        @memset(buffer, 0);
        return .{ .buffer = buffer };
    }

    /// Write a single bit (0 or 1)
    pub fn writeBit(self: *BitWriter, bit: u1) void {
        if (self.byte_pos >= self.buffer.len) return;

        if (bit == 1) {
            self.buffer[self.byte_pos] |= @as(u8, 1) << (7 - @as(u3, self.bit_pos));
        }

        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }
    }

    /// Write multiple bits from a u64 value (up to 63 bits)
    /// Writes the least significant `num_bits` bits, MSB first
    pub fn writeBits(self: *BitWriter, value: u64, num_bits: u6) void {
        if (num_bits == 0) return;

        var remaining = num_bits;
        while (remaining > 0) {
            remaining -= 1;
            const bit: u1 = @intCast((value >> remaining) & 1);
            self.writeBit(bit);
        }
    }

    /// Write a full 64 bits from a u64 value
    pub fn writeBits64(self: *BitWriter, value: u64) void {
        // Write in two 32-bit chunks to avoid u6 overflow
        self.writeBits(value >> 32, 32);
        self.writeBits(value & 0xFFFFFFFF, 32);
    }

    /// Write a full i64 (64 bits)
    pub fn writeI64(self: *BitWriter, value: i64) void {
        self.writeBits64(@bitCast(value));
    }

    /// Write a full f64 (64 bits)
    pub fn writeF64(self: *BitWriter, value: f64) void {
        self.writeBits64(@bitCast(value));
    }

    /// Get the total number of bits written
    pub fn bitsWritten(self: *const BitWriter) usize {
        return self.byte_pos * 8 + @as(usize, self.bit_pos);
    }

    /// Get the number of bytes used (rounded up)
    pub fn bytesUsed(self: *const BitWriter) usize {
        if (self.bit_pos == 0) {
            return self.byte_pos;
        }
        return self.byte_pos + 1;
    }

    /// Get the written data as a slice
    pub fn getWrittenData(self: *const BitWriter) []const u8 {
        return self.buffer[0..self.bytesUsed()];
    }
};

/// BitReader for reading individual bits from a byte buffer.
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Read a single bit
    pub inline fn readBit(self: *BitReader) ?u1 {
        if (self.byte_pos >= self.data.len) return null;

        const bit: u1 = @intCast((self.data[self.byte_pos] >> (7 - @as(u3, self.bit_pos))) & 1);

        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return bit;
    }

    /// Read multiple bits into a u64 (up to 63 bits) - optimized version
    pub fn readBits(self: *BitReader, num_bits: u6) ?u64 {
        if (num_bits == 0) return 0;
        if (self.byte_pos >= self.data.len) return null;

        var result: u64 = 0;
        var remaining: u6 = num_bits;

        // Fast path: read whole bytes when we can
        while (remaining >= 8 and self.bit_pos == 0) {
            if (self.byte_pos >= self.data.len) return null;
            result = (result << 8) | self.data[self.byte_pos];
            self.byte_pos += 1;
            remaining -= 8;
        }

        // Read remaining bits
        while (remaining > 0) : (remaining -= 1) {
            if (self.byte_pos >= self.data.len) return null;
            const bit: u64 = (self.data[self.byte_pos] >> (7 - @as(u3, self.bit_pos))) & 1;
            result = (result << 1) | bit;

            if (self.bit_pos == 7) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            } else {
                self.bit_pos += 1;
            }
        }

        return result;
    }

    /// Read a full 64 bits into a u64 - optimized for byte-aligned reads
    pub fn readBits64(self: *BitReader) ?u64 {
        // Fast path: if byte-aligned, read 8 bytes directly
        if (self.bit_pos == 0) {
            if (self.byte_pos + 8 > self.data.len) return null;
            var result: u64 = 0;
            inline for (0..8) |_| {
                result = (result << 8) | self.data[self.byte_pos];
                self.byte_pos += 1;
            }
            return result;
        }

        // Slow path: read in two 32-bit chunks
        const high = self.readBits(32) orelse return null;
        const low = self.readBits(32) orelse return null;
        return (high << 32) | low;
    }

    /// Read a full i64 (64 bits)
    pub fn readI64(self: *BitReader) ?i64 {
        const bits = self.readBits64() orelse return null;
        return @bitCast(bits);
    }

    /// Read a full f64 (64 bits)
    pub fn readF64(self: *BitReader) ?f64 {
        const bits = self.readBits64() orelse return null;
        return @bitCast(bits);
    }

    /// Get total bits read
    pub fn bitsRead(self: *const BitReader) usize {
        return self.byte_pos * 8 + @as(usize, self.bit_pos);
    }
};

/// Gorilla timestamp encoder using delta-of-delta compression.
///
/// Encoding scheme:
/// - First timestamp: stored as full 64-bit value
/// - Second timestamp: delta stored as full 64-bit (or 14-bit if small)
/// - Subsequent: delta-of-delta with variable bit encoding:
///   - 0: single '0' bit (dod == 0)
///   - [-63, 64]: '10' + 7 bits
///   - [-255, 256]: '110' + 9 bits
///   - [-2047, 2048]: '1110' + 12 bits
///   - Otherwise: '1111' + 64 bits (full value)
pub const TimestampEncoder = struct {
    prev_timestamp: i64 = 0,
    prev_delta: i64 = 0,
    count: usize = 0,

    pub fn init() TimestampEncoder {
        return .{};
    }

    /// Encode a timestamp and write to the BitWriter
    pub fn encode(self: *TimestampEncoder, writer: *BitWriter, timestamp: i64) void {
        if (self.count == 0) {
            // First timestamp: write full value
            writer.writeI64(timestamp);
            self.prev_timestamp = timestamp;
            self.count = 1;
            return;
        }

        const delta = timestamp - self.prev_timestamp;

        if (self.count == 1) {
            // Second timestamp: write full delta
            // Using 64 bits for simplicity; paper uses block header
            writer.writeI64(delta);
            self.prev_delta = delta;
            self.prev_timestamp = timestamp;
            self.count = 2;
            return;
        }

        // Delta-of-delta encoding
        const dod = delta - self.prev_delta;
        self.encodeDeltaOfDelta(writer, dod);

        self.prev_delta = delta;
        self.prev_timestamp = timestamp;
        self.count += 1;
    }

    fn encodeDeltaOfDelta(self: *TimestampEncoder, writer: *BitWriter, dod: i64) void {
        _ = self;

        if (dod == 0) {
            // Case 1: dod == 0, write single '0' bit
            writer.writeBit(0);
        } else if (dod >= -63 and dod <= 64) {
            // Case 2: '10' prefix + 7 bits
            writer.writeBits(0b10, 2);
            // Convert to unsigned 7-bit representation
            const encoded: u64 = @bitCast(@as(i64, dod) + 63);
            writer.writeBits(encoded, 7);
        } else if (dod >= -255 and dod <= 256) {
            // Case 3: '110' prefix + 9 bits
            writer.writeBits(0b110, 3);
            const encoded: u64 = @bitCast(@as(i64, dod) + 255);
            writer.writeBits(encoded, 9);
        } else if (dod >= -2047 and dod <= 2048) {
            // Case 4: '1110' prefix + 12 bits
            writer.writeBits(0b1110, 4);
            const encoded: u64 = @bitCast(@as(i64, dod) + 2047);
            writer.writeBits(encoded, 12);
        } else {
            // Case 5: '1111' prefix + full 64-bit value
            writer.writeBits(0b1111, 4);
            writer.writeI64(dod);
        }
    }

    /// Reset the encoder state for a new block
    pub fn reset(self: *TimestampEncoder) void {
        self.prev_timestamp = 0;
        self.prev_delta = 0;
        self.count = 0;
    }
};

/// Gorilla timestamp decoder
pub const TimestampDecoder = struct {
    prev_timestamp: i64 = 0,
    prev_delta: i64 = 0,
    count: usize = 0,

    pub fn init() TimestampDecoder {
        return .{};
    }

    /// Decode the next timestamp from the BitReader
    pub inline fn decode(self: *TimestampDecoder, reader: *BitReader) ?i64 {
        if (self.count == 0) {
            // First timestamp: full 64-bit value
            const timestamp = reader.readI64() orelse return null;
            self.prev_timestamp = timestamp;
            self.count = 1;
            return timestamp;
        }

        if (self.count == 1) {
            // Second timestamp: full delta
            const delta = reader.readI64() orelse return null;
            self.prev_delta = delta;
            self.prev_timestamp = self.prev_timestamp + delta;
            self.count = 2;
            return self.prev_timestamp;
        }

        // Delta-of-delta decoding
        const dod = self.decodeDeltaOfDelta(reader) orelse return null;
        const delta = self.prev_delta + dod;
        const timestamp = self.prev_timestamp + delta;

        self.prev_delta = delta;
        self.prev_timestamp = timestamp;
        self.count += 1;

        return timestamp;
    }

    inline fn decodeDeltaOfDelta(self: *TimestampDecoder, reader: *BitReader) ?i64 {
        _ = self;

        const bit0 = reader.readBit() orelse return null;

        if (bit0 == 0) {
            // Case 1: dod == 0
            return 0;
        }

        const bit1 = reader.readBit() orelse return null;
        if (bit1 == 0) {
            // Case 2: '10' prefix, 7 bits follow
            const encoded = reader.readBits(7) orelse return null;
            return @as(i64, @intCast(encoded)) - 63;
        }

        const bit2 = reader.readBit() orelse return null;
        if (bit2 == 0) {
            // Case 3: '110' prefix, 9 bits follow
            const encoded = reader.readBits(9) orelse return null;
            return @as(i64, @intCast(encoded)) - 255;
        }

        const bit3 = reader.readBit() orelse return null;
        if (bit3 == 0) {
            // Case 4: '1110' prefix, 12 bits follow
            const encoded = reader.readBits(12) orelse return null;
            return @as(i64, @intCast(encoded)) - 2047;
        }

        // Case 5: '1111' prefix, full 64-bit value
        return reader.readI64();
    }

    pub fn reset(self: *TimestampDecoder) void {
        self.prev_timestamp = 0;
        self.prev_delta = 0;
        self.count = 0;
    }
};

/// Gorilla float encoder using XOR compression.
///
/// Encoding scheme:
/// - First value: stored as full 64-bit IEEE 754
/// - Subsequent values: XOR with previous value
///   - If XOR == 0: write single '0' bit
///   - If XOR != 0:
///     - Write '1' bit
///     - If leading zeros >= prev_leading and trailing zeros >= prev_trailing:
///       - Write '0' bit (control bit)
///       - Write meaningful bits using previous window
///     - Otherwise:
///       - Write '1' bit (control bit)
///       - Write 5 bits for leading zeros count
///       - Write 6 bits for meaningful bits length
///       - Write the meaningful bits
pub const FloatEncoder = struct {
    prev_value: u64 = 0,
    prev_leading: u6 = 0,
    prev_trailing: u6 = 0,
    count: usize = 0,

    pub fn init() FloatEncoder {
        return .{};
    }

    /// Encode a float and write to the BitWriter
    pub fn encode(self: *FloatEncoder, writer: *BitWriter, value: f64) void {
        const bits: u64 = @bitCast(value);

        if (self.count == 0) {
            // First value: write full 64 bits
            writer.writeF64(value);
            self.prev_value = bits;
            self.count = 1;
            return;
        }

        const xor = bits ^ self.prev_value;

        if (xor == 0) {
            // Values are identical: single '0' bit
            writer.writeBit(0);
        } else {
            // Values differ: '1' bit + XOR encoding
            writer.writeBit(1);

            const leading: u6 = @intCast(@clz(xor));
            const trailing: u6 = @intCast(@ctz(xor));

            // Check if we can reuse the previous window
            if (self.count > 1 and leading >= self.prev_leading and trailing >= self.prev_trailing) {
                // Reuse previous window: '0' control bit
                writer.writeBit(0);

                // Write only the meaningful bits using the previous window
                const meaningful_bits: u7 = 64 - @as(u7, self.prev_leading) - @as(u7, self.prev_trailing);
                const shifted = xor >> self.prev_trailing;
                if (meaningful_bits == 64) {
                    writer.writeBits64(shifted);
                } else {
                    writer.writeBits(shifted, @intCast(meaningful_bits));
                }
            } else {
                // New window: '1' control bit
                writer.writeBit(1);

                // Write leading zeros (5 bits, max 31 - but we cap at 31)
                const capped_leading: u5 = if (leading > 31) 31 else @intCast(leading);
                writer.writeBits(capped_leading, 5);

                // Calculate meaningful bits (use u7 for intermediate calculation)
                const meaningful_bits: u7 = 64 - @as(u7, leading) - @as(u7, trailing);

                // Write meaningful bits length (6 bits)
                // We store (meaningful_bits - 1) to fit in 6 bits (1-64 -> 0-63)
                writer.writeBits(meaningful_bits -| 1, 6);

                // Write the meaningful bits
                const shifted = xor >> trailing;
                if (meaningful_bits == 64) {
                    writer.writeBits64(shifted);
                } else {
                    writer.writeBits(shifted, @intCast(meaningful_bits));
                }

                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
        }

        self.prev_value = bits;
        self.count += 1;
    }

    pub fn reset(self: *FloatEncoder) void {
        self.prev_value = 0;
        self.prev_leading = 0;
        self.prev_trailing = 0;
        self.count = 0;
    }
};

/// Gorilla float decoder
pub const FloatDecoder = struct {
    prev_value: u64 = 0,
    prev_leading: u6 = 0,
    prev_trailing: u6 = 0,
    count: usize = 0,

    pub fn init() FloatDecoder {
        return .{};
    }

    /// Decode the next float from the BitReader
    pub inline fn decode(self: *FloatDecoder, reader: *BitReader) ?f64 {
        if (self.count == 0) {
            // First value: full 64 bits
            const value = reader.readF64() orelse return null;
            self.prev_value = @bitCast(value);
            self.count = 1;
            return value;
        }

        const control_bit = reader.readBit() orelse return null;

        if (control_bit == 0) {
            // XOR is 0, value unchanged
            self.count += 1;
            return @bitCast(self.prev_value);
        }

        // XOR is non-zero
        const reuse_bit = reader.readBit() orelse return null;

        var xor: u64 = undefined;

        if (reuse_bit == 0) {
            // Reuse previous window
            const meaningful_bits: u7 = 64 - @as(u7, self.prev_leading) - @as(u7, self.prev_trailing);
            const bits = if (meaningful_bits == 64)
                reader.readBits64() orelse return null
            else
                reader.readBits(@intCast(meaningful_bits)) orelse return null;
            xor = bits << self.prev_trailing;
        } else {
            // New window
            const leading_raw = reader.readBits(5) orelse return null;
            const meaningful_minus_one = reader.readBits(6) orelse return null;

            const leading: u6 = @intCast(leading_raw);
            const meaningful_bits: u7 = @intCast(meaningful_minus_one + 1);
            const trailing: u6 = @intCast(64 - @as(u7, leading) - meaningful_bits);

            const bits = if (meaningful_bits == 64)
                reader.readBits64() orelse return null
            else
                reader.readBits(@intCast(meaningful_bits)) orelse return null;
            xor = bits << trailing;

            self.prev_leading = leading;
            self.prev_trailing = trailing;
        }

        self.prev_value = self.prev_value ^ xor;
        self.count += 1;

        return @bitCast(self.prev_value);
    }

    pub fn reset(self: *FloatDecoder) void {
        self.prev_value = 0;
        self.prev_leading = 0;
        self.prev_trailing = 0;
        self.count = 0;
    }
};

/// Combined Gorilla block encoder for a series of (timestamp, float) pairs.
pub const GorillaEncoder = struct {
    ts_encoder: TimestampEncoder,
    float_encoder: FloatEncoder,

    pub fn init() GorillaEncoder {
        return .{
            .ts_encoder = TimestampEncoder.init(),
            .float_encoder = FloatEncoder.init(),
        };
    }

    /// Encode a timestamp-value pair
    pub fn encode(self: *GorillaEncoder, writer: *BitWriter, timestamp: i64, value: f64) void {
        self.ts_encoder.encode(writer, timestamp);
        self.float_encoder.encode(writer, value);
    }

    pub fn reset(self: *GorillaEncoder) void {
        self.ts_encoder.reset();
        self.float_encoder.reset();
    }
};

/// Combined Gorilla block decoder
pub const GorillaDecoder = struct {
    ts_decoder: TimestampDecoder,
    float_decoder: FloatDecoder,

    pub fn init() GorillaDecoder {
        return .{
            .ts_decoder = TimestampDecoder.init(),
            .float_decoder = FloatDecoder.init(),
        };
    }

    /// Decode a timestamp-value pair
    pub fn decode(self: *GorillaDecoder, reader: *BitReader) ?struct { timestamp: i64, value: f64 } {
        const timestamp = self.ts_decoder.decode(reader) orelse return null;
        const value = self.float_decoder.decode(reader) orelse return null;
        return .{ .timestamp = timestamp, .value = value };
    }

    pub fn reset(self: *GorillaDecoder) void {
        self.ts_decoder.reset();
        self.float_decoder.reset();
    }
};

// ============================================================================
// Convenience functions for encoding/decoding arrays
// ============================================================================

/// Encode an array of timestamps using Gorilla delta-of-delta compression.
/// Returns the number of bytes used.
pub fn encodeTimestamps(timestamps: []const i64, buffer: []u8) usize {
    var writer = BitWriter.init(buffer);
    var encoder = TimestampEncoder.init();

    for (timestamps) |ts| {
        encoder.encode(&writer, ts);
    }

    return writer.bytesUsed();
}

/// Decode timestamps from a Gorilla-encoded buffer.
/// Returns allocated slice of timestamps.
pub fn decodeTimestamps(allocator: Allocator, data: []const u8, count: usize) ![]i64 {
    var reader = BitReader.init(data);
    var decoder = TimestampDecoder.init();

    const timestamps = try allocator.alloc(i64, count);
    errdefer allocator.free(timestamps);

    for (0..count) |i| {
        timestamps[i] = decoder.decode(&reader) orelse return error.DecodeError;
    }

    return timestamps;
}

/// Encode an array of floats using Gorilla XOR compression.
/// Returns the number of bytes used.
pub fn encodeFloats(values: []const f64, buffer: []u8) usize {
    var writer = BitWriter.init(buffer);
    var encoder = FloatEncoder.init();

    for (values) |v| {
        encoder.encode(&writer, v);
    }

    return writer.bytesUsed();
}

/// Decode floats from a Gorilla-encoded buffer.
/// Returns allocated slice of floats.
pub fn decodeFloats(allocator: Allocator, data: []const u8, count: usize) ![]f64 {
    var reader = BitReader.init(data);
    var decoder = FloatDecoder.init();

    const values = try allocator.alloc(f64, count);
    errdefer allocator.free(values);

    for (0..count) |i| {
        values[i] = decoder.decode(&reader) orelse return error.DecodeError;
    }

    return values;
}

// ============================================================================
// Tests
// ============================================================================

test "BitWriter and BitReader basic" {
    var buffer: [16]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write some bits
    writer.writeBit(1);
    writer.writeBit(0);
    writer.writeBit(1);
    writer.writeBit(1);
    writer.writeBits(0b1010, 4); // 4 bits

    try testing.expectEqual(@as(usize, 8), writer.bitsWritten());
    try testing.expectEqual(@as(u8, 0b1011_1010), buffer[0]);

    // Read back
    var reader = BitReader.init(&buffer);
    try testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try testing.expectEqual(@as(u1, 0), reader.readBit().?);
    try testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try testing.expectEqual(@as(u64, 0b1010), reader.readBits(4).?);
}

test "BitWriter multi-byte" {
    var buffer: [16]u8 = undefined;
    var writer = BitWriter.init(&buffer);

    // Write 12 bits: 0b1111_0000_1111
    writer.writeBits(0b111100001111, 12);

    try testing.expectEqual(@as(usize, 12), writer.bitsWritten());
    try testing.expectEqual(@as(usize, 2), writer.bytesUsed());
    try testing.expectEqual(@as(u8, 0b11110000), buffer[0]);
    try testing.expectEqual(@as(u8, 0b11110000), buffer[1]); // 1111 in upper 4 bits

    var reader = BitReader.init(&buffer);
    try testing.expectEqual(@as(u64, 0b111100001111), reader.readBits(12).?);
}

test "Timestamp encoder/decoder - regular intervals" {
    var buffer: [256]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = TimestampEncoder.init();

    // Simulate regular 60-second intervals (common for time series)
    const base: i64 = 1609459200; // Some epoch time
    const timestamps = [_]i64{
        base,
        base + 60,
        base + 120,
        base + 180,
        base + 240,
        base + 300,
    };

    for (timestamps) |ts| {
        encoder.encode(&writer, ts);
    }

    const bytes_used = writer.bytesUsed();

    // Decode
    var reader = BitReader.init(buffer[0..bytes_used]);
    var decoder = TimestampDecoder.init();

    for (timestamps) |expected| {
        const decoded = decoder.decode(&reader).?;
        try testing.expectEqual(expected, decoded);
    }
}

test "Timestamp encoder/decoder - irregular intervals" {
    var buffer: [512]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = TimestampEncoder.init();

    const timestamps = [_]i64{
        1000000,
        1000060,
        1000125, // +65 (delta changed)
        1000200, // +75
        1000280, // +80
        1005000, // big jump
        1005060,
    };

    for (timestamps) |ts| {
        encoder.encode(&writer, ts);
    }

    var reader = BitReader.init(buffer[0..writer.bytesUsed()]);
    var decoder = TimestampDecoder.init();

    for (timestamps) |expected| {
        const decoded = decoder.decode(&reader).?;
        try testing.expectEqual(expected, decoded);
    }
}

test "Float encoder/decoder - identical values" {
    var buffer: [64]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = FloatEncoder.init();

    // Same value repeated - should compress to 1 bit each after first
    const value: f64 = 3.14159;
    for (0..10) |_| {
        encoder.encode(&writer, value);
    }

    const bytes_used = writer.bytesUsed();
    // First value = 64 bits, rest = 1 bit each = 64 + 9 = 73 bits = 10 bytes
    try testing.expect(bytes_used <= 10);

    var reader = BitReader.init(buffer[0..bytes_used]);
    var decoder = FloatDecoder.init();

    for (0..10) |_| {
        const decoded = decoder.decode(&reader).?;
        try testing.expectEqual(value, decoded);
    }
}

test "Float encoder/decoder - similar values" {
    var buffer: [256]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = FloatEncoder.init();

    // Values that differ slightly - XOR should have few bits set
    const values = [_]f64{
        25.5,
        25.6,
        25.55,
        25.52,
        25.58,
        26.0,
    };

    for (values) |v| {
        encoder.encode(&writer, v);
    }

    var reader = BitReader.init(buffer[0..writer.bytesUsed()]);
    var decoder = FloatDecoder.init();

    for (values) |expected| {
        const decoded = decoder.decode(&reader).?;
        try testing.expectEqual(expected, decoded);
    }
}

test "Float encoder/decoder - special values" {
    var buffer: [256]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = FloatEncoder.init();

    const values = [_]f64{
        0.0,
        -0.0,
        std.math.inf(f64),
        -std.math.inf(f64),
        1.0,
        std.math.floatMin(f64),
        std.math.floatMax(f64),
    };

    for (values) |v| {
        encoder.encode(&writer, v);
    }

    var reader = BitReader.init(buffer[0..writer.bytesUsed()]);
    var decoder = FloatDecoder.init();

    for (values) |expected| {
        const decoded = decoder.decode(&reader).?;
        // Handle special float comparisons
        if (std.math.isNan(expected)) {
            try testing.expect(std.math.isNan(decoded));
        } else if (std.math.isInf(expected)) {
            try testing.expect(std.math.isInf(decoded));
            try testing.expectEqual(std.math.sign(expected), std.math.sign(decoded));
        } else {
            try testing.expectEqual(expected, decoded);
        }
    }
}

test "Combined GorillaEncoder/Decoder" {
    var buffer: [1024]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = GorillaEncoder.init();

    const DataPoint = struct { ts: i64, val: f64 };
    const points = [_]DataPoint{
        .{ .ts = 1000000, .val = 25.5 },
        .{ .ts = 1000060, .val = 25.6 },
        .{ .ts = 1000120, .val = 25.55 },
        .{ .ts = 1000180, .val = 25.52 },
        .{ .ts = 1000240, .val = 25.58 },
    };

    for (points) |p| {
        encoder.encode(&writer, p.ts, p.val);
    }

    var reader = BitReader.init(buffer[0..writer.bytesUsed()]);
    var decoder = GorillaDecoder.init();

    for (points) |expected| {
        const decoded = decoder.decode(&reader).?;
        try testing.expectEqual(expected.ts, decoded.timestamp);
        try testing.expectEqual(expected.val, decoded.value);
    }
}

test "encodeTimestamps/decodeTimestamps" {
    const allocator = testing.allocator;

    const timestamps = [_]i64{ 1000, 1060, 1120, 1180, 1240 };
    var buffer: [256]u8 = undefined;

    const bytes_used = encodeTimestamps(&timestamps, &buffer);
    try testing.expect(bytes_used > 0);

    const decoded = try decodeTimestamps(allocator, buffer[0..bytes_used], timestamps.len);
    defer allocator.free(decoded);

    for (timestamps, 0..) |expected, i| {
        try testing.expectEqual(expected, decoded[i]);
    }
}

test "encodeFloats/decodeFloats" {
    const allocator = testing.allocator;

    const values = [_]f64{ 1.0, 1.1, 1.2, 1.3, 1.4 };
    var buffer: [256]u8 = undefined;

    const bytes_used = encodeFloats(&values, &buffer);
    try testing.expect(bytes_used > 0);

    const decoded = try decodeFloats(allocator, buffer[0..bytes_used], values.len);
    defer allocator.free(decoded);

    for (values, 0..) |expected, i| {
        try testing.expectEqual(expected, decoded[i]);
    }
}

test "Compression ratio - regular time series" {
    var buffer: [8192]u8 = undefined;
    var writer = BitWriter.init(&buffer);
    var encoder = GorillaEncoder.init();

    // Simulate typical time series: regular 60s intervals, slowly changing values
    const base_ts: i64 = 1609459200;
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    var base_value: f64 = 50.0;
    const count: usize = 1000;

    for (0..count) |i| {
        const ts = base_ts + @as(i64, @intCast(i)) * 60;
        // Small random walk
        base_value += (random.float(f64) - 0.5) * 0.1;
        encoder.encode(&writer, ts, base_value);
    }

    const compressed_size = writer.bytesUsed();
    const uncompressed_size = count * (8 + 8); // 8 bytes timestamp + 8 bytes float

    // Gorilla should achieve significant compression
    // Paper reports ~1.37 bytes per value on average
    const compression_ratio = @as(f64, @floatFromInt(uncompressed_size)) / @as(f64, @floatFromInt(compressed_size));

    // We should get at least 2x compression for regular data
    try testing.expect(compression_ratio > 2.0);
}

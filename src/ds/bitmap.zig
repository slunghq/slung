//! A simple bitmap data structure implementation.
//! It can be used to store a set of bits of a given fixed size with support to
//! set and clear ranges of bits as well as common bitwise operations.
//!
//! Bitwise operations are implemented using the bitwise AND, OR, XOR, NOT, and
//! AND NOT logical operators. Bitwise operations modifies the bitmap in place and
//! returns the modified bitmap. Bitwise operations can be performed on two bitmaps
//! of the same size.
//!
//! Warning: Ensure to always stage your changes via commit() before reading and prepare() before writing.

const std = @import("std");
const testing = std.testing;

fn BitmapImpl(size: usize) type {
    return struct {
        const Self = @This();
        const byte_size = if (size % 8 == 0) size / 8 else (size / 8) + 1;
        const bit_size = size;

        bits: [byte_size]u8,
        dirty_bits: [byte_size]u8,

        /// Initialise a bitmap with a given size.
        pub fn init() Self {
            return Self{
                .bits = std.mem.zeroes([byte_size]u8),
                .dirty_bits = std.mem.zeroes([byte_size]u8),
            };
        }

        /// Deinitialise the bitmap.
        pub fn deinit(self: *Self) void {
            self.bits = undefined;
            self.dirty_bits = undefined;
        }

        // -------- Write operations --------
        /// Set the bit at the given index to 1.
        pub fn set(self: *Self, index: usize) void {
            if (index >= bit_size) {
                return;
            }
            self.dirty_bits[index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
        }

        /// Clear the bit at the given index to 0.
        pub fn clear(self: *Self, index: usize) void {
            if (index >= bit_size) {
                return;
            }
            self.dirty_bits[index / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(index % 8)));
        }

        /// Get the bit at the given index.
        pub fn get(self: *Self, index: usize) bool {
            if (index >= bit_size) {
                return false;
            }
            return self.bits[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
        }

        /// Set all bits to 1.
        pub fn set_all(self: *Self) void {
            for (&self.dirty_bits) |*byte| {
                byte.* = 0xff;
            }
        }

        /// Set a range of bits from index start to end to 1.
        pub fn set_range(self: *Self, start: usize, end: usize) void {
            if (start > end or end >= bit_size) {
                return;
            }
            var i = start;
            while (i <= end) : (i += 1) {
                self.set(i);
            }
        }

        /// Clear all bits to 0.
        pub fn clear_all(self: *Self) void {
            for (&self.dirty_bits) |*byte| {
                byte.* = 0x00;
            }
        }

        /// Clear a range of bits from index start to end to 0.
        pub fn clear_range(self: *Self, start: usize, end: usize) void {
            if (start > end or end >= bit_size) {
                return;
            }
            var i = start;
            while (i <= end) : (i += 1) {
                self.clear(i);
            }
        }

        /// Commit the dirty bits to the bits array.
        /// All read ops before commit won't return set/cleared bits.
        pub fn commit(self: *Self) void {
            @memcpy(self.bits[0..], self.dirty_bits[0..]);
            self.clear_all();
        }

        /// Prepares the bitmap for write operations.
        /// Call this to ensure that previous commits are not overwritten.
        pub fn prepare(self: *Self) void {
            @memcpy(self.dirty_bits[0..], self.bits[0..]);
        }

        // -------- Read operations --------
        /// Check if the bitmap is dirty.
        pub fn is_dirty(self: *Self) bool {
            for (self.dirty_bits) |bit| {
                if (bit != 0) {
                    return true;
                }
            }
            return false;
        }

        /// Get the length of the bitmap.
        pub fn len(_: *Self) usize {
            return bit_size;
        }

        /// Get the length of the bitmap in bytes.
        pub fn len_bytes(self: *Self) usize {
            return self.bits.len;
        }

        /// Get the number of set bits in the bitmap.
        pub fn count_bits_set(self: *Self) usize {
            var count: usize = 0;
            for (self.bits) |byte| {
                count += @popCount(byte);
            }
            return count;
        }

        /// Get the number of cleared bits in the bitmap.
        pub fn count_bits_clear(self: *Self) usize {
            return self.len() - self.count_bits_set();
        }

        // -------- Bitwise operations --------
        /// Get the bitwise AND of two bitmaps.
        pub fn set_and(self: *Self, other: *Self) void {
            if (self.bits.len != other.bits.len) {
                return;
            }
            for (self.bits, 0..self.bits.len) |bit, i| {
                self.bits[i] = bit & other.bits[i];
            }
        }

        /// Get the bitwise OR of two bitmaps.
        pub fn set_or(self: *Self, other: *Self) void {
            if (self.bits.len != other.bits.len) {
                return;
            }
            for (self.bits, 0..self.bits.len) |bit, i| {
                self.bits[i] = bit | other.bits[i];
            }
        }

        /// Get the bitwise XOR of two bitmaps.
        pub fn set_xor(self: *Self, other: *Self) void {
            if (self.bits.len != other.bits.len) {
                return;
            }
            for (self.bits, 0..self.bits.len) |bit, i| {
                self.bits[i] = bit ^ other.bits[i];
            }
        }

        /// Get the bitwise NOT of a bitmap.
        pub fn set_not(self: *Self) void {
            if (self.bits.len == 0) {
                return;
            }
            for (self.bits, 0..self.bits.len) |bit, i| {
                self.bits[i] = ~bit;
            }
        }

        /// Get the bitwise AND NOT of two bitmaps.
        pub fn set_and_not(self: *Self, other: *Self) void {
            if (self.bits.len != other.bits.len) {
                return;
            }
            for (self.bits, 0..self.bits.len) |bit, i| {
                self.bits[i] = bit & ~other.bits[i];
            }
        }
    };
}

pub const Bitmap = BitmapImpl;

test "mutate bitmap" {
    var bitmap = Bitmap(80).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.commit(); // assertions panic without commit
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(3));
    try testing.expect(!bitmap.get(4));
    bitmap.prepare();
    bitmap.set(4);
    bitmap.set(5);
    bitmap.set(6);
    bitmap.set(7);
    bitmap.set(8);
    bitmap.set(19);
    bitmap.commit();
    try testing.expect(bitmap.get(2)); // still set
    try testing.expect(bitmap.get(4));
    try testing.expect(bitmap.get(5));
    try testing.expect(bitmap.get(6));
    try testing.expect(bitmap.get(7));
    try testing.expect(bitmap.get(8));
    try testing.expect(bitmap.get(19));
    try testing.expect(!bitmap.get(10));
}

test "read ops" {
    var bitmap = Bitmap(80).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    try testing.expect(bitmap.is_dirty());
    bitmap.commit();
    try testing.expect(!bitmap.is_dirty());
    try testing.expect(bitmap.len() == 80);
    try testing.expect(bitmap.len_bytes() == 10);
    try testing.expect(bitmap.count_set_bits() == 4);
    try testing.expect(bitmap.count_clear_bits() == 76);
}

test "set/clear range" {
    var bitmap = Bitmap(80).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set_range(0, 10);
    bitmap.commit();
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(3));
    try testing.expect(bitmap.get(4));
    try testing.expect(bitmap.get(5));
    try testing.expect(bitmap.get(6));
    try testing.expect(bitmap.get(7));
    try testing.expect(bitmap.get(8));
    try testing.expect(bitmap.get(9));
    try testing.expect(bitmap.get(10));
    bitmap.prepare();
    bitmap.clear_range(0, 8);
    bitmap.commit();
    try testing.expect(!bitmap.get(0));
    try testing.expect(!bitmap.get(1));
    try testing.expect(!bitmap.get(2));
    try testing.expect(!bitmap.get(3));
    try testing.expect(!bitmap.get(4));
    try testing.expect(!bitmap.get(5));
    try testing.expect(!bitmap.get(6));
    try testing.expect(!bitmap.get(7));
    try testing.expect(!bitmap.get(8));
    try testing.expect(bitmap.get(9));
    try testing.expect(bitmap.get(10));
}

test "set/clear all" {
    var bitmap = Bitmap(80).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set_all();
    bitmap.commit();
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(79));
    bitmap.prepare();
    bitmap.clear_all();
    bitmap.commit();
    try testing.expect(!bitmap.get(0));
    try testing.expect(!bitmap.get(1));
    try testing.expect(!bitmap.get(2));
    try testing.expect(!bitmap.get(79));
}

// TODO: fix bitwise ops and test
test "bitwise ops and" {
    var bitmap = Bitmap(8).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.commit();
    var bitmap2 = Bitmap(8).init();
    defer bitmap2.deinit();
    bitmap2.prepare();
    bitmap2.set(4);
    bitmap2.set(5);
    bitmap2.set(6);
    bitmap2.set(7);
    bitmap2.commit();
    bitmap.set_and(&bitmap2);
    try testing.expect(!bitmap.get(0));
    try testing.expect(!bitmap.get(1));
    try testing.expect(!bitmap.get(2));
    try testing.expect(!bitmap.get(3));
    try testing.expect(!bitmap.get(4));
    try testing.expect(!bitmap.get(5));
    try testing.expect(!bitmap.get(6));
    try testing.expect(!bitmap.get(7));
}

test "bitwise ops or" {
    var bitmap = Bitmap(8).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.commit();
    var bitmap2 = Bitmap(8).init();
    defer bitmap2.deinit();
    bitmap2.prepare();
    bitmap2.set(4);
    bitmap2.set(5);
    bitmap2.set(6);
    bitmap2.set(7);
    bitmap2.commit();
    bitmap.set_or(&bitmap2);
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(3));
    try testing.expect(bitmap.get(4));
    try testing.expect(bitmap.get(5));
    try testing.expect(bitmap.get(6));
    try testing.expect(bitmap.get(7));
}

test "bitwise ops xor" {
    var bitmap = Bitmap(8).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.set(4);
    bitmap.commit();
    var bitmap2 = Bitmap(8).init();
    defer bitmap2.deinit();
    bitmap2.prepare();
    bitmap2.set(4);
    bitmap2.set(5);
    bitmap2.set(6);
    bitmap2.set(7);
    bitmap2.commit();
    bitmap.set_xor(&bitmap2);
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(3));
    try testing.expect(!bitmap.get(4));
    try testing.expect(bitmap.get(5));
    try testing.expect(bitmap.get(6));
    try testing.expect(bitmap.get(7));
}

test "bitwise ops not" {
    var bitmap = Bitmap(8).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.commit();
    bitmap.set_not();
    try testing.expect(!bitmap.get(0));
    try testing.expect(!bitmap.get(1));
    try testing.expect(!bitmap.get(2));
    try testing.expect(!bitmap.get(3));
}

test "bitwise ops and not" {
    var bitmap = Bitmap(8).init();
    defer bitmap.deinit();
    bitmap.prepare();
    bitmap.set(0);
    bitmap.set(1);
    bitmap.set(2);
    bitmap.set(3);
    bitmap.commit();
    var bitmap2 = Bitmap(8).init();
    defer bitmap2.deinit();
    bitmap2.prepare();
    bitmap2.set(4);
    bitmap2.set(5);
    bitmap2.set(6);
    bitmap2.set(7);
    bitmap2.commit();
    bitmap.set_and_not(&bitmap2);
    try testing.expect(bitmap.get(0));
    try testing.expect(bitmap.get(1));
    try testing.expect(bitmap.get(2));
    try testing.expect(bitmap.get(3));
    try testing.expect(!bitmap.get(4));
    try testing.expect(!bitmap.get(5));
    try testing.expect(!bitmap.get(6));
    try testing.expect(!bitmap.get(7));
}

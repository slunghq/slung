//! A simple bloom filter implementation.
//!
//! Bloom filter is a space-efficient probabilistic data structure that is used to test whether an element is a member of a set. False positives are possible, but false negatives are not.
//! This has insertion and membership checking. There are 2 variants of this data structure:
//!
//! * `Bloom`: A bloom filter with a fixed size and a single hash function.
//! * `BloomMultiHash`: A bloom filter with a fixed size and multiple hash functions.
//!
//! There's plans for a counting bloom filter and eventually a cuckoo filter.

const std = @import("std");
const bitmap = @import("bitmap.zig");
const testing = std.testing;

fn BloomImpl(comptime size: usize, comptime HashFn: type) type {
    return struct {
        const Self = @This();

        mask: bitmap.Bitmap(size),
        /// Initialise a bloom filter with a given size and hash function.
        pub fn init() Self {
            return Self{
                .mask = bitmap.Bitmap(size).init(),
            };
        }

        /// Deinitialise the bloom filter.
        pub fn deinit(self: *Self) void {
            self.mask.deinit();
        }

        /// Insert a value into the bloom filter.
        pub fn insert(self: *Self, value: []const u8) void {
            const hash_value = HashFn.hash(value);
            const index = if (comptime std.math.isPowerOfTwo(size))
                hash_value & (size - 1)
            else
                hash_value % size;
            self.mask.prepare();
            self.mask.set(index);
            self.mask.commit();
        }

        /// Check if a value is in the bloom filter.
        pub fn contains(self: *Self, value: []const u8) bool {
            const hash_value = HashFn.hash(value);
            const index = if (comptime std.math.isPowerOfTwo(size))
                hash_value & (size - 1)
            else
                hash_value % size;
            return self.mask.get(index);
        }

        /// Get the length of the bloom filter.
        pub fn len(self: *Self) usize {
            return self.mask.len();
        }
    };
}

fn BloomMutliHashFn(comptime size: usize, comptime HashFn: []const type) type {
    comptime {
        if (HashFn.len == 0) {
            @compileError("Need at least one hash function");
        } else if (HashFn.len == 1) {
            @compileLog("It's suggested to use `Bloom` instead of `BloomMutliHash` for a single hash function");
        }
    }
    return struct {
        const Self = @This();

        mask: bitmap.Bitmap(size),

        /// Initialise a bloom filter with a given size and hash functions.
        pub fn init() Self {
            return Self{
                .mask = bitmap.Bitmap(size).init(),
            };
        }

        /// Deinitialise the bloom filter.
        pub fn deinit(self: *Self) void {
            self.mask.deinit();
        }

        /// Insert a value into the bloom filter.
        pub fn insert(self: *Self, value: []const u8) void {
            inline for (HashFn) |hash_fn| {
                const hash_value = hash_fn.hash(value);
                const index = if (comptime std.math.isPowerOfTwo(size))
                    hash_value & (size - 1)
                else
                    hash_value % size;
                self.mask.prepare();
                self.mask.set(index);
                self.mask.commit();
            }
        }

        /// Check if a value is in the bloom filter.
        pub fn contains(self: *Self, value: []const u8) bool {
            inline for (HashFn) |hash_fn| {
                const hash_value = hash_fn.hash(value);
                const index = if (comptime std.math.isPowerOfTwo(size))
                    hash_value & (size - 1)
                else
                    hash_value % size;
                if (!self.mask.get(index)) {
                    return false;
                }
            }
            return true;
        }

        /// Get the length of the bloom filter.
        pub fn len(self: *Self) usize {
            return self.mask.len();
        }

        /// Get the number of hash functions.
        pub fn hashers(_: *Self) usize {
            return HashFn.len;
        }
    };
}

/// A bloom filter with a fixed size and a single hash function.
pub const Bloom = BloomImpl;
/// A bloom filter with a fixed size and multiple hash functions.
pub const BloomMultiHash = BloomMutliHashFn;

pub const DefaultHashFn = struct {
    pub fn hash(value: []const u8) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, value)));
    }
};

pub const AlternateHashFn = struct {
    pub fn hash(value: []const u8) usize {
        return @as(usize, @truncate(std.hash.XxHash3.hash(0, value)));
    }
};

test "bloom" {
    var bloom = Bloom(100, DefaultHashFn).init();
    defer bloom.deinit();

    bloom.insert("hello");
    bloom.insert("world");

    try testing.expect(bloom.contains("hello"));
    try testing.expect(bloom.contains("world"));
    try testing.expect(!bloom.contains("foo"));
    try testing.expect(bloom.len() == 100);
}

test "bloom multi hash" {
    var bloom = BloomMultiHash(100, &.{ DefaultHashFn, AlternateHashFn }).init();
    defer bloom.deinit();

    bloom.insert("hello");
    bloom.insert("world");

    try testing.expect(bloom.contains("hello"));
    try testing.expect(bloom.contains("world"));
    try testing.expect(!bloom.contains("foo"));
    try testing.expect(bloom.len() == 100);
    try testing.expect(bloom.hashers() == 2);
}

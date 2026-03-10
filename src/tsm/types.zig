pub const TimestampEncoding = enum {
    /// Zigzag varint delta encoding - faster queries
    delta,
    /// Delta-of-delta bit encoding - better compression
    gorilla,
};

pub const Value = union(enum) {
    Bool: bool,
    Int: i64,
    Float: f64,
    Bytes: []const u8,

    pub fn compare(self: Value, b: Value) @import("std").math.Order {
        const std = @import("std");
        return switch (self) {
            .Int => |val| std.math.order(val, b.Int),
            .Float => |val| std.math.order(val, b.Float),
            .Bytes => |val| std.mem.order(u8, val, b.Bytes),
            .Bool => |val| std.math.order(@intFromBool(val), @intFromBool(b.Bool)),
        };
    }
};

pub const DataPoint = struct {
    timestamp: i64,
    value: Value,
};

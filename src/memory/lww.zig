//! Last-Write-Wins Registry with HLC + Causal Tags
//!
//! Stores the latest value for any key, determined by HLC timestamps.
//! A write is accepted only if its HLC is > the stored HLC (total order via node_id).
//! Each entry tracks the causal tag (rule/source id) that produced the write.
//!
//! Design:
//! - StringHashMapUnmanaged(Entry) - O(1) avg point lookup, no ordering needed
//! - Entry now holds HLC timestamp + causal tag instead of u64 marker
//! - Bloom filter for O(1) definite-miss short-circuit on get()
//! - Bytes values are owned (duped on insert, freed on remove/deinit)
//! - Keys are owned (duped on first insert, freed on remove/deinit)

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const bloom = @import("../primitives/bloom.zig");
const Bloom = bloom.Bloom;
const CausalTag = @import("../types.zig").CausalTag;
const DefaultHashFn = bloom.DefaultHashFn;
const hlc = @import("../primitives/hlc.zig");
const Timestamp = hlc.Timestamp;

pub const LwwRegistry = struct {
    const Self = @This();

    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(Entry),
    bloom: Bloom(4096, DefaultHashFn),

    pub const Value = union(enum) {
        Bool: bool,
        Int: i64,
        Float: f64,
        Bytes: []const u8,
    };

    pub const Entry = struct {
        hlc: Timestamp,
        value: Value,
        cause: CausalTag,
    };

    pub fn init(allocator: Allocator) LwwRegistry {
        return .{
            .allocator = allocator,
            .entries = .{},
            .bloom = Bloom(4096, DefaultHashFn).init(),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.freeValue(kv.value_ptr.value);
        }
        self.entries.deinit(self.allocator);
        self.bloom.deinit();
    }

    /// Pre-allocate capacity for n keys.
    pub fn reserve(self: *Self, n: u32) !void {
        try self.entries.ensureTotalCapacity(self.allocator, n);
    }

    /// Insert or update a key if hlc > existing hlc (via total order comparison).
    /// Returns true if the write was accepted.
    pub inline fn put(self: *Self, key: []const u8, hlc_ts: Timestamp, value: Value, cause: CausalTag) !bool {
        const owned_value = try self.dupeValue(value);
        errdefer self.freeValue(owned_value);

        if (self.entries.getPtr(key)) |existing| {
            if (hlc_ts.compare(existing.hlc) != .gt) {
                self.freeValue(owned_value);
                return false;
            }
            self.freeValue(existing.value);
            existing.hlc = hlc_ts;
            existing.value = owned_value;
            existing.cause = cause;
            return true;
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.entries.put(self.allocator, owned_key, .{
            .hlc = hlc_ts,
            .value = owned_value,
            .cause = cause,
        });
        self.bloom.insert(key);
        return true;
    }

    /// Get the latest entry for a key, or null if not present.
    pub inline fn get(self: *Self, key: []const u8) ?Entry {
        if (!self.bloom.contains(key)) return null;
        return self.entries.get(key);
    }

    /// Remove a key. Returns true if it existed.
    pub inline fn remove(self: *Self, key: []const u8) bool {
        if (!self.bloom.contains(key)) return false;
        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.freeValue(kv.value.value);
            return true;
        }
        return false;
    }

    /// Number of keys currently held.
    pub fn count(self: *const Self) u32 {
        return self.entries.count();
    }

    /// Merge remote entries into this registry using HLC-based LWW semantics.
    /// For each key in `other`, apply the entry if its HLC is strictly greater.
    pub fn merge(self: *Self, other: *const LwwRegistry) !void {
        var it = other.entries.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const remote_entry = kv.value_ptr.*;
            _ = try self.put(key, remote_entry.hlc, remote_entry.value, remote_entry.cause);
        }
    }

    inline fn dupeValue(self: *Self, value: Value) !Value {
        return switch (value) {
            .Bytes => |b| .{ .Bytes = try self.allocator.dupe(u8, b) },
            else => value,
        };
    }

    inline fn freeValue(self: *Self, value: Value) void {
        if (value == .Bytes) self.allocator.free(value.Bytes);
    }
};

test "LwwRegistry: basic put and get" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    try testing.expect(try reg.put("cpu", ts, .{ .Float = 0.75 }, .{ .cause = 1, .entity = 1, .node = "" }));
    const e = reg.get("cpu").?;
    try testing.expect(e.hlc.eql(ts));
    try testing.expectApproxEqAbs(@as(f64, 0.75), e.value.Float, 0.001);
    try testing.expectEqual(CausalTag{ .cause = 1, .entity = 1, .node = "" }, e.cause);
}

test "LwwRegistry: newer HLC write wins" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const ts2 = Timestamp{ .wall = 200, .logical = 0, .node_id = 1 };

    try testing.expect(try reg.put("k", ts1, .{ .Int = 100 }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expect(try reg.put("k", ts2, .{ .Int = 200 }, .{ .cause = 2, .entity = 1, .node = "2" }));
    try testing.expectEqual(@as(i64, 200), reg.get("k").?.value.Int);
    try testing.expect(reg.get("k").?.hlc.eql(ts2));
    try testing.expectEqual(CausalTag{ .cause = 2, .entity = 1, .node = "2" }, reg.get("k").?.cause);
}

test "LwwRegistry: older HLC write is rejected" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts_old = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const ts_new = Timestamp{ .wall = 200, .logical = 0, .node_id = 1 };

    try testing.expect(try reg.put("k", ts_new, .{ .Int = 42 }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expect(!try reg.put("k", ts_old, .{ .Int = 99 }, .{ .cause = 2, .entity = 1, .node = "2" }));
    try testing.expectEqual(@as(i64, 42), reg.get("k").?.value.Int);
}

test "LwwRegistry: equal HLC is rejected (requires strict >)" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };

    try testing.expect(try reg.put("k", ts, .{ .Int = 1 }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expect(!try reg.put("k", ts, .{ .Int = 2 }, .{ .cause = 2, .entity = 1, .node = "2" }));
    try testing.expectEqual(@as(i64, 1), reg.get("k").?.value.Int);
    try testing.expectEqual(CausalTag{ .cause = 1, .entity = 1, .node = "1" }, reg.get("k").?.cause);
}

test "LwwRegistry: node_id breaks ties in HLC" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts_node1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const ts_node2 = Timestamp{ .wall = 100, .logical = 0, .node_id = 2 };

    try testing.expect(try reg.put("k", ts_node1, .{ .Int = 1 }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expect(try reg.put("k", ts_node2, .{ .Int = 2 }, .{ .cause = 2, .entity = 1, .node = "2" }));
    try testing.expectEqual(@as(i64, 2), reg.get("k").?.value.Int);
    try testing.expectEqual(CausalTag{ .cause = 2, .entity = 1, .node = "2" }, reg.get("k").?.cause);
}

test "LwwRegistry: missing key returns null" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    try testing.expect(reg.get("nope") == null);
}

test "LwwRegistry: remove" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    try testing.expect(try reg.put("x", ts, .{ .Bool = true }, .{ .cause = 1, .entity = 1, .node = "" }));
    try testing.expect(reg.remove("x"));
    try testing.expectEqual(@as(u32, 0), reg.count());
}

test "LwwRegistry: remove frees memory" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const ts = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    try testing.expect(try reg.put("key", ts, .{ .Bytes = "hello" }, .{ .cause = 1, .entity = 1, .node = "" }));
    try testing.expect(reg.remove("key"));
    try testing.expectEqual(@as(u32, 0), reg.count());
    try testing.expect(reg.get("key") == null);
}

test "LwwRegistry: bytes value ownership" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    const s = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(s);

    const ts1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const ts2 = Timestamp{ .wall = 200, .logical = 0, .node_id = 1 };

    try testing.expect(try reg.put("key", ts1, .{ .Bytes = s }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expectEqualStrings("hello", reg.get("key").?.value.Bytes);

    try testing.expect(try reg.put("key", ts2, .{ .Bytes = "world" }, .{ .cause = 2, .entity = 1, .node = "2" }));
    try testing.expectEqualStrings("world", reg.get("key").?.value.Bytes);
}

test "LwwRegistry: reserve" {
    var reg = LwwRegistry.init(testing.allocator);
    defer reg.deinit();

    try reg.reserve(1000);
    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        const ts = Timestamp{ .wall = 100 + @as(u64, @intCast(i)), .logical = 0, .node_id = 1 };
        try testing.expect(try reg.put(key, ts, .{ .Int = @intCast(i) }, .{ .cause = 1, .entity = 1, .node = "" }));
    }
    try testing.expectEqual(@as(u32, 100), reg.count());
}

test "LwwRegistry: merge applies HLC-based LWW" {
    var reg_a = LwwRegistry.init(testing.allocator);
    defer reg_a.deinit();

    var reg_b = LwwRegistry.init(testing.allocator);
    defer reg_b.deinit();

    const ts1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const ts2 = Timestamp{ .wall = 200, .logical = 0, .node_id = 2 };

    try testing.expect(try reg_a.put("shared", ts1, .{ .Int = 10 }, .{ .cause = 1, .entity = 1, .node = "1" }));
    try testing.expect(try reg_b.put("shared", ts2, .{ .Int = 20 }, .{ .cause = 2, .entity = 1, .node = "2" }));

    try reg_a.merge(&reg_b);

    const merged = reg_a.get("shared").?;
    try testing.expectEqual(@as(i64, 20), merged.value.Int);
    try testing.expectEqual(CausalTag{ .cause = 2, .entity = 1, .node = "2" }, merged.cause);
}

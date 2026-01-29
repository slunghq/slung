const std = @import("std");
const testing = std.testing;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
const Skiplist = ds.skiplist.SkipList;
const ColumnTable = @import("table.zig").ColumnTable;

pub const Cache = struct {
    allocator: Allocator,
    index_series: HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)),
    page_size: u32,

    pub const DataPoint = struct {
        timestamp: i64,
        value: Value,
    };

    pub const Value = union(enum) {
        Bool: bool,
        Int: i64,
        Float: f64,
        Bytes: []const u8,

        pub fn compare(self: Value, b: Value) std.math.Order {
            return switch (self) {
                .Int => |val| std.math.order(val, b.Int),
                .Float => |val| std.math.order(val, b.Float),
                .Bytes => |val| std.mem.order(u8, val, b.Bytes),
                .Bool => |val| std.math.order(@intFromBool(val), @intFromBool(b.Bool)),
            };
        }
    };

    pub fn init(allocator: Allocator, page_size: u32) Cache {
        return Cache{
            .allocator = allocator,
            .index_series = HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)).init(allocator),
            .page_size = page_size,
        };
    }

    pub fn deinit(self: *Cache) void {
        var iter = self.index_series.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.index_series.deinit();
    }

    pub fn insert(self: *Cache, series_key: []const u8, data_point: DataPoint) !void {
        const series = try self.index_series.getOrPut(series_key);
        if (!series.found_existing) {
            const skiplist = try Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).init(self.allocator, @intCast(std.time.microTimestamp()));
            series.value_ptr.* = skiplist;
        }
        _ = try series.value_ptr.*.insert(data_point.timestamp, data_point.value);
    }

    pub fn get(self: *Cache, series_key: []const u8, timestamp: i64) ?Value {
        var skiplist = self.index_series.get(series_key) orelse return null;

        return skiplist.search(timestamp).?.value;
    }

    pub fn getRange(self: *Cache, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
        const skiplist = self.index_series.get(series_key) orelse return error.SeriesNotFound;

        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(self.allocator);

        var iter: ?*Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).Node = skiplist.head.next();
        while (iter) |node| : (iter = node.next()) {
            if (node.key >= timestamp_start and node.key <= timestamp_end) {
                try values.append(self.allocator, node.value);
            }
            if (node.key > timestamp_end) break;
        }

        return values.toOwnedSlice(self.allocator);
    }

    /// Snapshot the cache to columnar table
    pub fn snapshot(self: *Cache, table: *ColumnTable(self.page_size)) !void {
        _ = table;
        // table.flush();
        // impl flushing logic
    }
};

test "cache" {
    const allocator = testing.allocator;
    var cache = Cache.init(allocator, 4096);
    defer cache.deinit();

    const series_key = "series1";

    const timestamp1 = std.time.microTimestamp();
    const timestamp2 = std.time.microTimestamp();
    const timestamp3 = std.time.microTimestamp();
    try cache.insert(series_key, Cache.DataPoint{ .timestamp = timestamp1, .value = Cache.Value{ .Int = 10 } });
    try cache.insert(series_key, Cache.DataPoint{ .timestamp = timestamp2, .value = Cache.Value{ .Int = 21 } });
    try cache.insert(series_key, Cache.DataPoint{ .timestamp = timestamp3, .value = Cache.Value{ .Int = 36 } });

    const result1 = cache.get("series1", timestamp1).?;
    try testing.expectEqual(10, result1.Int);

    const result2 = try cache.getRange(series_key, 0, std.time.microTimestamp());
    defer allocator.free(result2);
    try testing.expectEqual(36, result2[2].Int);
    try testing.expectEqual(21, result2[1].Int);
    try testing.expectEqual(10, result2[0].Int);
}

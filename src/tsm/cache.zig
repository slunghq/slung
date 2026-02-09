const std = @import("std");
const testing = std.testing;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringArrayHashMap;
const Skiplist = ds.skiplist.SkipList;
const Bloom = ds.bloom.Bloom;
const Hasher = ds.bloom.DefaultHashFn;
const entry_mod = @import("entry.zig");
const DiskEntry = entry_mod.DiskEntry;
const TimestampEncoding = entry_mod.TimestampEncoding;

fn CacheImpl(comptime page_size: u32, comptime ts_encoding: TimestampEncoding) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        index_series: HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)),
        bloom: Bloom(1024, Hasher),
        count: u64 = 0,

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

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .index_series = HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)).init(allocator),
                .bloom = Bloom(1024, Hasher).init(),
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.index_series.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.deinit();
                self.allocator.free(kv.key_ptr.*);
            }
            self.index_series.deinit();
            self.bloom.deinit();
        }

        pub fn insert(self: *Self, series_key: []const u8, data_point: DataPoint) !void {
            const series = try self.index_series.getOrPut(series_key);
            if (!series.found_existing) {
                const owned_key = try self.allocator.dupe(u8, series_key);
                series.key_ptr.* = owned_key;
                const skiplist = try Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).init(self.allocator, @intCast(std.time.microTimestamp()));
                series.value_ptr.* = skiplist;
                self.bloom.insert(series_key);
            }
            _ = try series.value_ptr.*.insert(data_point.timestamp, data_point.value);
            self.count += 1;
        }

        pub fn mayContainSeries(self: *Self, series_key: []const u8) bool {
            return self.bloom.contains(series_key);
        }

        pub fn get(self: *Self, series_key: []const u8, timestamp: i64) ?Value {
            var skiplist = self.index_series.get(series_key) orelse return null;

            return if (skiplist.search(timestamp)) |node| node.value else null;
        }

        pub fn getRange(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            if (!self.bloom.contains(series_key)) {
                return error.SeriesNotFound;
            }

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

        pub fn flush(self: *Self, tsm_name: []const u8, level: usize) !*DiskEntry(page_size, ts_encoding) {
            return try DiskEntry(page_size, ts_encoding).flush(self.allocator, self, tsm_name, level);
        }
    };
}

pub const Cache = CacheImpl;

test "Cache" {
    const allocator = testing.allocator;
    const page_size = 4096;
    var cache = CacheImpl(page_size, .delta).init(allocator);
    defer cache.deinit();

    const timestamp1 = std.time.microTimestamp();

    const TestCache = CacheImpl(page_size, .delta);
    try cache.insert("series1", TestCache.DataPoint{ .timestamp = timestamp1, .value = TestCache.Value{ .Int = 10 } });
    try cache.insert("series1", TestCache.DataPoint{ .timestamp = std.time.microTimestamp(), .value = TestCache.Value{ .Int = 21 } });
    try cache.insert("series1", TestCache.DataPoint{ .timestamp = std.time.microTimestamp(), .value = TestCache.Value{ .Int = 36 } });
    try cache.insert("series2", TestCache.DataPoint{ .timestamp = timestamp1, .value = TestCache.Value{ .Int = 36 } });

    const result1 = cache.get("series1", timestamp1).?;
    try testing.expectEqual(10, result1.Int);
    const result2 = cache.get("series2", timestamp1).?;
    try testing.expectEqual(36, result2.Int);

    const result3 = try cache.getRange("series1", 0, std.time.microTimestamp());
    defer allocator.free(result3);
    try testing.expectEqual(36, result3[2].Int);
    try testing.expectEqual(21, result3[1].Int);
    try testing.expectEqual(10, result3[0].Int);
}

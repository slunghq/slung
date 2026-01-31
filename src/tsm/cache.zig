const std = @import("std");
const testing = std.testing;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
const Skiplist = ds.skiplist.SkipList;
const ColumnTable = @import("table.zig").ColumnTable;
const DiskEntry = @import("entry.zig").DiskEntry;

pub fn CacheImpl(comptime page_size: u32) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        index_series: HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)),

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
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.index_series.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.index_series.deinit();
        }

        pub fn insert(self: *Self, series_key: []const u8, data_point: DataPoint) !void {
            const series = try self.index_series.getOrPut(series_key);
            if (!series.found_existing) {
                const skiplist = try Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).init(self.allocator, @intCast(std.time.microTimestamp()));
                series.value_ptr.* = skiplist;
            }
            _ = try series.value_ptr.*.insert(data_point.timestamp, data_point.value);
        }

        pub fn get(self: *Self, series_key: []const u8, timestamp: i64) ?Value {
            var skiplist = self.index_series.get(series_key) orelse return null;

            return if (skiplist.search(timestamp)) |node| node.value else null;
        }

        pub fn getRange(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
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

        /// Snapshot the cache to columnar table and return disk entry
        pub fn snapshot(self: *Self, tsm_name: []const u8, level: usize, table: *ColumnTable(page_size)) !?*DiskEntry {
            // the key here is that during a snapshot we check if our existing table is populated and flush that first
            const entry = if (table.columns.len != 0) try DiskEntry(page_size).flush(self.allocator, table, tsm_name, level) else null;

            // we're ignoring tags for now
            const column_names = [_][]const u8{ "time", "series_key", "value" };
            table.deinit();
            table.* = try ColumnTable(page_size).init(self.allocator, &column_names);

            var iter = self.index_series.iterator();
            while (iter.next()) |series| {
                var iter_series: ?*Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).Node = series.value_ptr.head.next();
                while (iter_series) |node| : (iter_series = node.next()) {
                    const key = try std.fmt.allocPrint(self.allocator, "{d}", .{node.key});
                    defer self.allocator.free(key);

                    const values = try self.allocator.alloc(ColumnTable(page_size).Value, 3);
                    values[0] = .{ .Int = node.key };
                    values[1] = .{ .Bytes = series.key_ptr.* };
                    values[2] = switch (node.value) {
                        .Bool => |v| .{ .Bool = v },
                        .Int => |v| .{ .Int = v },
                        .Float => |v| .{ .Float = v },
                        .Bytes => |v| .{ .Bytes = v },
                    };
                    const row = ColumnTable(page_size).Row{
                        .key = key,
                        .values = values,
                    };
                    try table.insert(row);
                }
            }

            return entry;
        }
    };
}

const Cache = CacheImpl;

test "cache" {
    const allocator = testing.allocator;
    const page_size = 4096;
    var cache = Cache(page_size).init(allocator);
    defer cache.deinit();

    const timestamp1 = std.time.microTimestamp();

    try cache.insert("series1", Cache(page_size).DataPoint{ .timestamp = timestamp1, .value = Cache(page_size).Value{ .Int = 10 } });
    try cache.insert("series1", Cache(page_size).DataPoint{ .timestamp = std.time.microTimestamp(), .value = Cache(page_size).Value{ .Int = 21 } });
    try cache.insert("series1", Cache(page_size).DataPoint{ .timestamp = std.time.microTimestamp(), .value = Cache(page_size).Value{ .Int = 36 } });
    try cache.insert("series2", Cache(page_size).DataPoint{ .timestamp = timestamp1, .value = Cache(page_size).Value{ .Int = 36 } });

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

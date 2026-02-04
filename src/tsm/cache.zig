const std = @import("std");
const testing = std.testing;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringArrayHashMap;
const Skiplist = ds.skiplist.SkipList;
const ColumnTable = @import("table.zig").ColumnTable;
const DiskEntry = @import("entry.zig").DiskEntry;

pub fn CacheImpl(comptime page_size: u32) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        // TODO: maybe store skiplist alongside tags??
        index_series: HashMap(Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64)),

        pub const DataPoint = struct {
            timestamp: i64,
            value: Value,
        };

        pub const Value = ColumnTable(page_size).Value;

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
        pub fn snapshot(self: *Self, tsm_name: []const u8, level: usize, table: *ColumnTable(page_size)) !?*DiskEntry(page_size) {
            // the key here is that during a snapshot we check if our existing table is populated and flush that first
            // TODO: should we populate first, then flush?
            const entry = if (table.metadata.number_rows != 0) try DiskEntry(page_size).flush(self.allocator, table, tsm_name, level) else null;

            table.clear();

            var iter = self.index_series.iterator();
            var index_count: u64 = 0;
            while (iter.next()) |series| {
                var iter_series: ?*Skiplist(i64, Value, 16, std.Random.Pcg, ds.skiplist.compareI64).Node = series.value_ptr.head.next();
                var index_series: [2]u64 = undefined;
                index_series[0] = index_count;
                while (iter_series) |node| : (iter_series = node.next()) {
                    const key = try std.fmt.allocPrint(self.allocator, "{d}", .{node.key});
                    defer self.allocator.free(key);

                    const values = try self.allocator.alloc(ColumnTable(page_size).Value, 3);
                    defer self.allocator.free(values);
                    values[0] = .{ .Int = node.key };
                    values[1] = .{ .Bytes = series.key_ptr.* };
                    values[2] = node.value;
                    const row = ColumnTable(page_size).Row{
                        .key = key,
                        .values = values,
                    };
                    try table.insert(row);
                    index_count += 1;
                }

                // the prior index_count belongs to the last item of the given series
                index_series[1] = index_count - 1;

                try table.index_series.put(series.key_ptr.*, index_series);
            }

            return entry;
        }
    };
}

const Cache = CacheImpl;

// TODO: clean up test
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

    const column_names = [_][]const u8{ "time", "series_key", "value" };
    var table = try ColumnTable(page_size).init(allocator, &column_names);
    defer table.deinit();

    const values1 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values1[0] = .{ .Int = 1 };
    values1[1] = .{ .Bytes = "series1" };
    values1[2] = .{ .Float = 23.1 };
    defer allocator.free(values1);
    const row1 = ColumnTable(page_size).Row{
        .key = "user1",
        .values = values1,
    };
    try table.insert(row1);

    const values2 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values2[0] = .{ .Int = 2 };
    values2[1] = .{ .Bytes = "series1" };
    values2[2] = .{ .Float = 25.8 };
    defer allocator.free(values2);
    const row2 = ColumnTable(page_size).Row{
        .key = "user2",
        .values = values2,
    };
    try table.insert(row2);

    const values3 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values3[0] = .{ .Int = 3 };
    values3[1] = .{ .Bytes = "series1" };
    values3[2] = .{ .Float = 21.7 };
    defer allocator.free(values3);
    const row3 = ColumnTable(page_size).Row{
        .key = "user3",
        .values = values3,
    };
    try table.insert(row3);

    const entry = try cache.snapshot("tsm", 0, table);
    if (entry) |en| {
        defer en.deinit();

        const result = try en.getColumnById(1);
        defer {
            for (result) |value| {
                if (value == .Bytes) {
                    allocator.free(value.Bytes);
                }
            }
            allocator.free(result);
        }
        try testing.expectEqualStrings("series1", result[0].Bytes);
    }

    const result4 = try table.getColumn("time");
    defer allocator.free(result4);
    try testing.expectEqual(timestamp1, result4[3].Int);

    var discard_entry = try DiskEntry(page_size).flush(allocator, table, "tsm", 1);
    defer discard_entry.deinit();
    var entry2 = try DiskEntry(page_size).open(allocator, "tsm", 1);
    defer entry2.deinit();

    const result = try entry2.getColumn("series_key");
    defer {
        for (result) |value| {
            if (value == .Bytes) {
                allocator.free(value.Bytes);
            }
        }
        allocator.free(result);
    }
    try testing.expectEqualStrings("series2", result[3].Bytes);
}

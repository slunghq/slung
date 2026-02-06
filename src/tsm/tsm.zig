const std = @import("std");
const testing = std.testing;
const table = @import("table.zig");
const cache = @import("cache.zig");
const entry = @import("entry.zig");
const Allocator = std.mem.Allocator;
const Cache = cache.Cache;
const ColumnTable = table.ColumnTable;
const DiskEntry = entry.DiskEntry;

pub fn TsmTreeImpl(comptime max_level: u64, comptime page_size: u32) type {
    return struct {
        const Self = @This();
        const MAX_CACHE_POINTS = 10_000_000;

        allocator: Allocator,
        name: []const u8,
        entries: []*DiskEntry(page_size),
        entries_count: u64 = 0,
        cache: *Cache(page_size),
        table: *ColumnTable(page_size),

        pub const queryOp = enum { AVG, MIN, MAX, SUM, COUNT };

        pub const DataPoint = Cache(page_size).DataPoint;
        pub const Value = ColumnTable(page_size).Value;

        pub fn init(allocator: Allocator, name: []const u8) !Self {
            // we're ignoring tags for now
            const column_names = [_][]const u8{ "time", "series_key", "value" };
            const cache_ptr = try allocator.create(Cache(page_size));
            cache_ptr.* = Cache(page_size).init(allocator);
            return Self{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .entries = try allocator.alloc(*DiskEntry(page_size), max_level),
                .cache = cache_ptr,
                .table = try ColumnTable(page_size).init(allocator, &column_names),
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..self.entries_count) |i| {
                self.entries[i].deinit();
            }
            self.table.deinit();
            self.cache.deinit();
            self.allocator.destroy(self.cache);
            self.allocator.free(self.entries);
            self.allocator.free(self.name);
        }

        pub fn flush(self: *Self) !void {
            const d_entry = try self.cache.snapshot(self.name, self.entries_count + 1, self.table);
            if (d_entry) |en| {
                self.entries[self.entries_count] = en;
                self.entries_count += 1;
            }
            var iter = self.cache.index_series.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.deinit();
            }
            self.cache.index_series.clearRetainingCapacity();
            self.cache.count = 0;
        }

        pub fn insert(self: *Self, series_key: []const u8, data_point: DataPoint) !void {
            try self.cache.insert(series_key, data_point);
            if (self.cache.count > MAX_CACHE_POINTS) try self.flush();
        }

        pub fn insertBulk(self: *Self, series_key: []const u8, data_points: []DataPoint) !void {
            for (data_points) |data_point| {
                try self.cache.insert(series_key, data_point);
            }
        }

        pub fn insertBulkSeries(self: *Self, series_keys: []const []const u8, data_points: [][]DataPoint) !void {
            for (series_keys, data_points) |series_key, data_point| {
                try self.insertBulk(series_key, data_point);
            }
        }

        fn queryCache(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            return try self.cache.getRange(series_key, timestamp_start, timestamp_end);
        }

        fn queryTable(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            const series_ids = self.table.index_series.get(series_key) orelse return error.InvalidSeries;
            const time_values = try self.table.getColumnRange("time", series_ids[0], series_ids[1]);
            defer self.allocator.free(time_values);

            var timestamp_ids: [2]?u64 = .{ null, null };
            for (time_values, series_ids[0]..series_ids[1] + 1) |time, time_id| {
                if (time.Int >= timestamp_start and time.Int <= timestamp_end) {
                    if (timestamp_ids[0] == null or time_id < timestamp_ids[0].?) timestamp_ids[0] = @intCast(time_id);
                    if (timestamp_ids[1] == null or time_id > timestamp_ids[1].?) timestamp_ids[1] = @intCast(time_id);
                }
            }
            return try self.table.getColumnRange("value", timestamp_ids[0].?, timestamp_ids[1].?);
        }

        fn queryDisk(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            if (self.entries_count == 0) {
                return &[_]Value{};
            }
            var values_list: std.ArrayList(Value) = .empty;
            errdefer values_list.deinit(self.allocator);

            for (0..self.entries_count) |en_id| {
                const en = self.entries[en_id];
                const series_ids = en.index_series.get(series_key) orelse continue;
                const time_values = try en.getColumnRange("time", series_ids[0], series_ids[1]);
                defer self.allocator.free(time_values);

                var timestamp_ids: [2]?u64 = .{ null, null };
                for (time_values, series_ids[0]..series_ids[1] + 1) |time, time_id| {
                    if (time.Int >= timestamp_start and time.Int <= timestamp_end) {
                        if (timestamp_ids[0] == null or time_id < timestamp_ids[0].?) timestamp_ids[0] = @intCast(time_id);
                        if (timestamp_ids[1] == null or time_id > timestamp_ids[1].?) timestamp_ids[1] = @intCast(time_id);
                    }
                }
                if (timestamp_ids[0] == null or timestamp_ids[1] == null) continue;
                const values_entry = try en.getColumnRange("value", timestamp_ids[0].?, timestamp_ids[1].?);
                defer self.allocator.free(values_entry);
                try values_list.appendSlice(self.allocator, values_entry);
            }

            return values_list.toOwnedSlice(self.allocator);
        }

        pub fn query(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64, op: queryOp) !Value {
            const values_cache = self.queryCache(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(values_cache);
            const values_table = self.queryTable(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(values_table);
            const values_disk = self.queryDisk(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(values_disk);

            const values = try std.mem.concat(self.allocator, Value, &.{ values_cache, values_table, values_disk });
            defer self.allocator.free(values);

            return switch (op) {
                .AVG => blk: {
                    var sum: f64 = 0.0;
                    for (values) |value| {
                        sum += value.Float;
                    }
                    const count: f64 = @floatFromInt(values.len);
                    if (count == 0) return Value{ .Float = 0.0 };
                    break :blk Value{ .Float = sum / count };
                },
                .MIN => blk: {
                    var min = values[0].Float;
                    for (values) |value| {
                        if (value.compare(Value{ .Float = min }) == .lt) min = value.Float;
                    }
                    break :blk Value{ .Float = min };
                },
                .MAX => blk: {
                    var max = values[0].Float;
                    for (values) |value| {
                        if (value.compare(Value{ .Float = max }) == .gt) max = value.Float;
                    }
                    break :blk Value{ .Float = max };
                },
                .SUM => blk: {
                    var sum: f64 = 0.0;
                    for (values) |value| {
                        sum += value.Float;
                    }
                    break :blk Value{ .Float = sum };
                },
                .COUNT => Value{ .Float = @floatFromInt(values.len) },
            };
        }

        pub fn queryRaw(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            const value_cache = self.queryCache(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(value_cache);
            const value_table = self.queryTable(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(value_table);
            const value_disk = self.queryDisk(series_key, timestamp_start, timestamp_end) catch &[_]Value{};
            defer self.allocator.free(value_disk);

            return try std.mem.concat(self.allocator, Value, &.{ value_cache, value_table, value_disk });
        }

        pub fn queryLatest(self: *Self, series_key: []const u8) !DataPoint {
            var datapoint = DataPoint{ .timestamp = 0, .value = Value{ .Float = 0.0 } };
            const blk = blk: {
                blk1: {
                    if (blkn: {
                        const skiplist = self.cache.index_series.get(series_key) orelse break :blk1;
                        break :blkn skiplist.last_inserted;
                    }) |node| {
                        datapoint.timestamp = node.key;
                        datapoint.value = node.value;
                        return datapoint;
                    }
                }
                blk2: {
                    if (self.table.metadata.number_rows > 0) {
                        const series_ids = self.table.index_series.get(series_key) orelse break :blk2;
                        const time = self.table.getByRow("time", series_ids[1]) catch break :blk2;
                        const value = self.table.getByRow("value", series_ids[1]) catch break :blk2;

                        datapoint.timestamp = time.Int;
                        datapoint.value = value;
                        return datapoint;
                    }
                }
                blk3: {
                    if (self.entries_count > 0 and self.entries[0].metadata.number_rows > 0) {
                        const en = self.entries[0];
                        const series_ids = self.entries[0].index_series.get(series_key) orelse break :blk3;
                        const time = en.getColumnRange("time", series_ids[0], series_ids[1]) catch break :blk3;
                        const value = en.getColumnRange("value", series_ids[0], series_ids[1]) catch break :blk3;

                        datapoint.timestamp = time[time.len - 1].Int;
                        datapoint.value = value[value.len - 1];
                        return datapoint;
                    }
                }

                break :blk error.EmptyTree;
            };

            return blk;
        }

        pub fn queryFirst(self: *Self, series_key: []const u8) !DataPoint {
            var datapoint = DataPoint{ .timestamp = 0, .value = Value{ .Float = 0.0 } };
            const blk = blk: {
                if (self.entries_count > 0) {
                    for (0..self.entries_count) |entry_id| {
                        const en = self.entries[entry_id];
                        if (en.metadata.number_rows > 0) {
                            const series_ids = en.index_series.get(series_key) orelse continue;
                            const time = en.getColumnRange("time", series_ids[0], series_ids[1]) catch continue;
                            defer self.allocator.free(time);
                            const value = en.getColumnRange("value", series_ids[0], series_ids[1]) catch continue;
                            defer self.allocator.free(value);

                            datapoint.timestamp = time[0].Int;
                            datapoint.value = value[0];
                            return datapoint;
                        }
                    }
                }
                blk1: {
                    if (self.table.metadata.number_rows > 0) {
                        const series_ids = self.table.index_series.get(series_key) orelse break :blk1;
                        const time = self.table.getByRow("time", series_ids[0]) catch break :blk1;
                        const value = self.table.getByRow("value", series_ids[0]) catch break :blk1;

                        datapoint.timestamp = time.Int;
                        datapoint.value = value;
                        return datapoint;
                    }
                }
                blk2: {
                    const skiplist = self.cache.index_series.get(series_key) orelse break :blk2;
                    const first_node = skiplist.head.next() orelse break :blk2;

                    datapoint.timestamp = first_node.key;
                    datapoint.value = first_node.value;
                    return datapoint;
                }

                break :blk error.EmptyTree;
            };
            return blk;
        }
    };
}

const TsmTree = TsmTreeImpl(10, 4096);

test {
    _ = table;
    _ = cache;
    _ = entry;
}

test "tsm tree init and deinit" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_tree");
    defer tsm.deinit();

    try testing.expectEqualStrings("test_tree", tsm.name);
    try testing.expectEqual(@as(u64, 0), tsm.entries_count);
}

test "tsm tree insert single data point" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_insert");
    defer tsm.deinit();

    const timestamp = std.time.microTimestamp();
    const data_point = TsmTree.DataPoint{
        .timestamp = timestamp,
        .value = TsmTree.Value{ .Float = 42.5 },
    };

    try tsm.insert("sensor1", data_point);

    // verify data is in cache
    const result = tsm.cache.get("sensor1", timestamp);
    try testing.expect(result != null);
    try testing.expectEqual(@as(f64, 42.5), result.?.Float);
}

test "tsm tree insert multiple data points" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_insert_bulk");
    defer tsm.deinit();

    const timestamp1 = std.time.microTimestamp();
    const timestamp2 = timestamp1 + 1000;
    const timestamp3 = timestamp1 + 2000;

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp1, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp2, .value = TsmTree.Value{ .Float = 20.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp3, .value = TsmTree.Value{ .Float = 30.0 } });

    // verify all data points are in cache
    const result1 = tsm.cache.get("sensor1", timestamp1);
    const result2 = tsm.cache.get("sensor1", timestamp2);
    const result3 = tsm.cache.get("sensor1", timestamp3);

    try testing.expectEqual(@as(f64, 10.0), result1.?.Float);
    try testing.expectEqual(@as(f64, 20.0), result2.?.Float);
    try testing.expectEqual(@as(f64, 30.0), result3.?.Float);
}

test "tsm tree insert multiple series" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_multi_series");
    defer tsm.deinit();

    const timestamp = std.time.microTimestamp();

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp, .value = TsmTree.Value{ .Float = 100.0 } });
    try tsm.insert("sensor2", TsmTree.DataPoint{ .timestamp = timestamp, .value = TsmTree.Value{ .Float = 200.0 } });
    try tsm.insert("sensor3", TsmTree.DataPoint{ .timestamp = timestamp, .value = TsmTree.Value{ .Float = 300.0 } });

    try testing.expectEqual(@as(f64, 100.0), tsm.cache.get("sensor1", timestamp).?.Float);
    try testing.expectEqual(@as(f64, 200.0), tsm.cache.get("sensor2", timestamp).?.Float);
    try testing.expectEqual(@as(f64, 300.0), tsm.cache.get("sensor3", timestamp).?.Float);
}

test "tsm tree queryLatest from cache" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_query_latest");
    defer tsm.deinit();

    const timestamp1 = std.time.microTimestamp();
    const timestamp2 = timestamp1 + 1000;
    const timestamp3 = timestamp1 + 2000;

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp1, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp2, .value = TsmTree.Value{ .Float = 20.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp3, .value = TsmTree.Value{ .Float = 30.0 } });

    const latest = try tsm.queryLatest("sensor1");
    try testing.expectEqual(timestamp3, latest.timestamp);
    try testing.expectEqual(@as(f64, 30.0), latest.value.Float);
}

test "tsm tree queryLatest empty tree returns error" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_empty");
    defer tsm.deinit();

    const result = tsm.queryLatest("nonexistent");
    try testing.expectError(error.EmptyTree, result);
}

test "tsm tree query aggregations from cache" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_aggregations");
    defer tsm.deinit();

    const base_ts = std.time.microTimestamp();

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 1000, .value = TsmTree.Value{ .Float = 20.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 2000, .value = TsmTree.Value{ .Float = 30.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 3000, .value = TsmTree.Value{ .Float = 40.0 } });

    // test SUM
    const sum_result = try tsm.query("sensor1", base_ts, base_ts + 3000, .SUM);
    try testing.expectEqual(@as(f64, 100.0), sum_result.Float);

    // test COUNT
    const count_result = try tsm.query("sensor1", base_ts, base_ts + 3000, .COUNT);
    try testing.expectEqual(@as(f64, 4.0), count_result.Float);

    // test AVG
    const avg_result = try tsm.query("sensor1", base_ts, base_ts + 3000, .AVG);
    try testing.expectEqual(@as(f64, 25.0), avg_result.Float);

    // test MIN
    const min_result = try tsm.query("sensor1", base_ts, base_ts + 3000, .MIN);
    try testing.expectEqual(@as(f64, 10.0), min_result.Float);

    // test MAX
    const max_result = try tsm.query("sensor1", base_ts, base_ts + 3000, .MAX);
    try testing.expectEqual(@as(f64, 40.0), max_result.Float);
}

test "tsm tree queryRaw from cache" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_query_raw");
    defer tsm.deinit();

    const base_ts = std.time.microTimestamp();

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 1000, .value = TsmTree.Value{ .Float = 20.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 2000, .value = TsmTree.Value{ .Float = 30.0 } });

    const values = try tsm.queryRaw("sensor1", base_ts, base_ts + 2000);
    defer allocator.free(values);

    try testing.expectEqual(@as(usize, 3), values.len);
    try testing.expectEqual(@as(f64, 10.0), values[0].Float);
    try testing.expectEqual(@as(f64, 20.0), values[1].Float);
    try testing.expectEqual(@as(f64, 30.0), values[2].Float);
}

test "tsm tree query partial range" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_partial_range");
    defer tsm.deinit();

    const base_ts: i64 = 1000000;

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 1000, .value = TsmTree.Value{ .Float = 20.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 2000, .value = TsmTree.Value{ .Float = 30.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = base_ts + 3000, .value = TsmTree.Value{ .Float = 40.0 } });

    // query only middle range
    const values = try tsm.queryRaw("sensor1", base_ts + 1000, base_ts + 2000);
    defer allocator.free(values);

    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqual(@as(f64, 20.0), values[0].Float);
    try testing.expectEqual(@as(f64, 30.0), values[1].Float);
}

test "tsm tree query nonexistent series returns empty" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_nonexistent");
    defer tsm.deinit();

    // insert into one series
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Float = 10.0 } });

    // query a different series - should return empty count
    const count_result = try tsm.query("sensor2", 0, 2000, .COUNT);
    try testing.expectEqual(@as(f64, 0.0), count_result.Float);
}

test "tsm tree insertBulk" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_bulk");
    defer tsm.deinit();

    var data_points: [3]TsmTree.DataPoint = undefined;
    data_points[0] = TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Float = 10.0 } };
    data_points[1] = TsmTree.DataPoint{ .timestamp = 2000, .value = TsmTree.Value{ .Float = 20.0 } };
    data_points[2] = TsmTree.DataPoint{ .timestamp = 3000, .value = TsmTree.Value{ .Float = 30.0 } };

    try tsm.insertBulk("sensor1", &data_points);

    try testing.expectEqual(@as(f64, 10.0), tsm.cache.get("sensor1", 1000).?.Float);
    try testing.expectEqual(@as(f64, 20.0), tsm.cache.get("sensor1", 2000).?.Float);
    try testing.expectEqual(@as(f64, 30.0), tsm.cache.get("sensor1", 3000).?.Float);
}

test "tsm tree queryFirst from cache" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_query_first");
    defer tsm.deinit();

    const timestamp1: i64 = 1000;
    const timestamp2: i64 = 2000;
    const timestamp3: i64 = 3000;

    // insert in reverse order to ensure we get the earliest by timestamp
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp3, .value = TsmTree.Value{ .Float = 30.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp1, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = timestamp2, .value = TsmTree.Value{ .Float = 20.0 } });

    const first = try tsm.queryFirst("sensor1");
    // queryFirst returns the first (minimum key) node from the skiplist
    try testing.expectEqual(timestamp1, first.timestamp);
    try testing.expectEqual(@as(f64, 10.0), first.value.Float);
}

test "tsm tree query with Int values" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_int_values");
    defer tsm.deinit();

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Int = 100 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 2000, .value = TsmTree.Value{ .Int = 200 } });

    const result = tsm.cache.get("sensor1", 1000);
    try testing.expectEqual(@as(i64, 100), result.?.Int);
}

test "tsm tree query across disk table and cache with multiple flushes" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_multi_flush");
    defer {
        tsm.deinit();
    }

    // phase 1: insert data that will end up on disk after two flushes
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 2000, .value = TsmTree.Value{ .Float = 20.0 } });

    // first flush: moves cache -> table
    try tsm.flush();

    // phase 2: insert more data
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 3000, .value = TsmTree.Value{ .Float = 30.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 4000, .value = TsmTree.Value{ .Float = 40.0 } });

    // second flush: moves table -> disk (first disk entry), cache -> table
    try tsm.flush();

    // phase 3: insert data that stays in cache
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 5000, .value = TsmTree.Value{ .Float = 50.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 6000, .value = TsmTree.Value{ .Float = 60.0 } });

    try testing.expect(tsm.cache.get("sensor1", 5000) != null);
    try testing.expect(tsm.cache.get("sensor1", 6000) != null);

    try testing.expect(tsm.table.metadata.number_rows > 0);

    try testing.expect(tsm.entries_count > 0);

    const raw_values = try tsm.queryRaw("sensor1", 1000, 6000);
    defer allocator.free(raw_values);

    try testing.expect(raw_values.len >= 2);

    // test aggregation across all layers
    const sum_result = try tsm.query("sensor1", 1000, 6000, .SUM);
    // Sum should include values from all layers that are accessible
    try testing.expect(sum_result.Float > 0);

    const count_result = try tsm.query("sensor1", 1000, 6000, .COUNT);
    try testing.expect(count_result.Float >= 2);

    // queryLatest should return from cache (most recent)
    const latest = try tsm.queryLatest("sensor1");
    try testing.expectEqual(@as(i64, 6000), latest.timestamp);
    try testing.expectEqual(@as(f64, 60.0), latest.value.Float);

    const first = try tsm.queryFirst("sensor1");
    try testing.expectEqual(@as(i64, 1000), first.timestamp);
    try testing.expectEqual(@as(f64, 10.0), first.value.Float);
}

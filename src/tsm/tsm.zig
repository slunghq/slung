const std = @import("std");
const testing = std.testing;
const cache = @import("cache.zig");
const entry = @import("entry.zig");
const Allocator = std.mem.Allocator;
const Cache = cache.Cache;
const DiskEntry = entry.DiskEntry;
pub const TimestampEncoding = entry.TimestampEncoding;

pub fn TsmTreeImpl(comptime max_level: u64, comptime page_size: u32, comptime ts_encoding: TimestampEncoding) type {
    return struct {
        const Self = @This();
        const MAX_CACHE_POINTS = 1_000_000;
        pub const timestamp_encoding = ts_encoding;

        allocator: Allocator,
        name: []const u8,
        entries: []*DiskEntry(page_size, ts_encoding),
        entries_count: u64 = 0,
        cache: *Cache(page_size, ts_encoding),

        pub const QueryOp = enum { AVG, MIN, MAX, SUM, COUNT };

        pub const DataPoint = Cache(page_size, ts_encoding).DataPoint;
        pub const Value = Cache(page_size, ts_encoding).Value;

        pub fn init(allocator: Allocator, name: []const u8) !Self {
            const cache_ptr = try allocator.create(Cache(page_size, ts_encoding));
            cache_ptr.* = Cache(page_size, ts_encoding).init(allocator);
            return Self{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .entries = try allocator.alloc(*DiskEntry(page_size, ts_encoding), max_level),
                .cache = cache_ptr,
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..self.entries_count) |i| {
                self.entries[i].deinit();
            }
            self.cache.deinit();
            self.allocator.destroy(self.cache);
            self.allocator.free(self.entries);
            self.allocator.free(self.name);
        }

        pub fn flush(self: *Self) !void {
            if (self.cache.count == 0) return;

            const d_entry = try self.cache.flush(self.name, self.entries_count + 1);
            self.entries[self.entries_count] = d_entry;
            self.entries_count += 1;

            var iter = self.cache.index_series.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.deinit();
                self.allocator.free(kv.key_ptr.*);
            }
            self.cache.index_series.clearRetainingCapacity();
            self.cache.bloom.reset();
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

        fn queryDisk(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            if (self.entries_count == 0) {
                return &[_]Value{};
            }
            var values_list: std.ArrayList(Value) = .empty;
            errdefer values_list.deinit(self.allocator);

            for (0..self.entries_count) |en_id| {
                const en = self.entries[en_id];

                if (en.metadata.max_timestamp < timestamp_start or en.metadata.min_timestamp > timestamp_end) {
                    continue;
                }

                if (!en.mayContainSeries(series_key)) {
                    continue;
                }

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

        pub fn query(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64, op: QueryOp) !Value {
            const values_cache = self.queryCache(series_key, timestamp_start, timestamp_end) catch try self.allocator.alloc(Value, 0);
            defer self.allocator.free(values_cache);
            const values_disk = self.queryDisk(series_key, timestamp_start, timestamp_end) catch try self.allocator.alloc(Value, 0);
            defer self.allocator.free(values_disk);

            const values = try std.mem.concat(self.allocator, Value, &.{ values_cache, values_disk });
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
                    if (values.len == 0) break :blk Value{ .Float = 0.0 };
                    var min = values[0].Float;
                    for (values) |value| {
                        if (value.compare(Value{ .Float = min }) == .lt) min = value.Float;
                    }
                    break :blk Value{ .Float = min };
                },
                .MAX => blk: {
                    if (values.len == 0) break :blk Value{ .Float = 0.0 };
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
            const value_cache = self.queryCache(series_key, timestamp_start, timestamp_end) catch try self.allocator.alloc(Value, 0);
            defer self.allocator.free(value_cache);
            const value_disk = self.queryDisk(series_key, timestamp_start, timestamp_end) catch try self.allocator.alloc(Value, 0);
            defer self.allocator.free(value_disk);

            return try std.mem.concat(self.allocator, Value, &.{ value_cache, value_disk });
        }

        pub fn queryLatest(self: *Self, series_key: []const u8) !DataPoint {
            var datapoint = DataPoint{ .timestamp = 0, .value = Value{ .Float = 0.0 } };

            if (self.cache.index_series.get(series_key)) |skiplist| {
                if (skiplist.last_inserted) |node| {
                    datapoint.timestamp = node.key;
                    datapoint.value = node.value;
                    return datapoint;
                }
            }

            if (self.entries_count > 0) {
                const en = self.entries[self.entries_count - 1];
                if (en.index_series.get(series_key)) |series_ids| {
                    const time = en.getColumnRange("time", series_ids[0], series_ids[1]) catch return error.EmptyTree;
                    defer self.allocator.free(time);
                    const value = en.getColumnRange("value", series_ids[0], series_ids[1]) catch return error.EmptyTree;
                    defer self.allocator.free(value);
                    datapoint.timestamp = time[time.len - 1].Int;
                    datapoint.value = value[value.len - 1];
                    return datapoint;
                }
            }

            return error.EmptyTree;
        }

        pub fn queryFirst(self: *Self, series_key: []const u8) !DataPoint {
            var datapoint = DataPoint{ .timestamp = 0, .value = Value{ .Float = 0.0 } };

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

            if (self.cache.index_series.get(series_key)) |skiplist| {
                if (skiplist.head.next()) |first_node| {
                    datapoint.timestamp = first_node.key;
                    datapoint.value = first_node.value;
                    return datapoint;
                }
            }

            return error.EmptyTree;
        }
    };
}

pub const TsmTree = TsmTreeImpl(100_000, 4096, .gorilla);

test {
    _ = cache;
    _ = entry;
}

test "TsmTree init and deinit" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_tree");
    defer tsm.deinit();

    try testing.expectEqualStrings("test_tree", tsm.name);
    try testing.expectEqual(@as(u64, 0), tsm.entries_count);
}

test "TsmTree insert single data point" {
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

test "TsmTree insert multiple data points" {
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

test "TsmTree insert multiple series" {
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

test "TsmTree queryLatest from cache" {
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

test "TsmTree queryLatest empty tree returns error" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_empty");
    defer tsm.deinit();

    const result = tsm.queryLatest("nonexistent");
    try testing.expectError(error.EmptyTree, result);
}

test "TsmTree query aggregations from cache" {
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

test "TsmTree queryRaw from cache" {
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

test "TsmTree query partial range" {
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

test "TsmTree query nonexistent series returns empty" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_nonexistent");
    defer tsm.deinit();

    // insert into one series
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Float = 10.0 } });

    // query a different series - should return empty count
    const count_result = try tsm.query("sensor2", 0, 2000, .COUNT);
    try testing.expectEqual(@as(f64, 0.0), count_result.Float);
}

test "TsmTree insertBulk" {
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

test "TsmTree queryFirst from cache" {
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

test "TsmTree query with Int values" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_int_values");
    defer tsm.deinit();

    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Int = 100 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 2000, .value = TsmTree.Value{ .Int = 200 } });

    const result = tsm.cache.get("sensor1", 1000);
    try testing.expectEqual(@as(i64, 100), result.?.Int);
}

test "TsmTree query across disk and cache with single flush" {
    const allocator = testing.allocator;
    var tsm = try TsmTree.init(allocator, "test_single_flush");
    defer tsm.deinit();

    // phase 1: insert data that will end up on disk after flush
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 1000, .value = TsmTree.Value{ .Float = 10.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 2000, .value = TsmTree.Value{ .Float = 20.0 } });

    // flush: moves cache -> disk
    try tsm.flush();

    // phase 2: insert data that stays in cache
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 3000, .value = TsmTree.Value{ .Float = 30.0 } });
    try tsm.insert("sensor1", TsmTree.DataPoint{ .timestamp = 4000, .value = TsmTree.Value{ .Float = 40.0 } });

    // verify cache has the new data
    try testing.expect(tsm.cache.get("sensor1", 3000) != null);
    try testing.expect(tsm.cache.get("sensor1", 4000) != null);

    // verify we have disk entries
    try testing.expect(tsm.entries_count > 0);

    // query raw values across disk and cache
    const raw_values = try tsm.queryRaw("sensor1", 1000, 4000);
    defer allocator.free(raw_values);

    try testing.expect(raw_values.len >= 2);

    // test aggregation across disk and cache
    const sum_result = try tsm.query("sensor1", 1000, 4000, .SUM);
    try testing.expect(sum_result.Float > 0);

    const count_result = try tsm.query("sensor1", 1000, 4000, .COUNT);
    try testing.expect(count_result.Float >= 2);

    // queryLatest should return from cache (most recent)
    const latest = try tsm.queryLatest("sensor1");
    try testing.expectEqual(@as(i64, 4000), latest.timestamp);
    try testing.expectEqual(@as(f64, 40.0), latest.value.Float);

    // queryFirst should return from disk (earliest)
    const first = try tsm.queryFirst("sensor1");
    try testing.expectEqual(@as(i64, 1000), first.timestamp);
    try testing.expectEqual(@as(f64, 10.0), first.value.Float);
}

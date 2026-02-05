const std = @import("std");
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
        const MAX_CACHE_SIZE = 1024 * 1024;

        allocator: Allocator,
        name: []const u8,
        entries: [max_level]*DiskEntry(page_size),
        entries_count: u64 = 0,
        cache: *Cache(page_size),
        table: *ColumnTable(page_size),

        pub const QueryOp = enum { AVG, MIN, MAX, SUM, COUNT };

        pub const DataPoint = Cache(page_size).DataPoint;
        pub const Value = ColumnTable(page_size).Value;

        pub fn init(allocator: Allocator, name: []const u8) !Self {
            // we're ignoring tags for now
            const column_names = [_][]const u8{ "time", "series_key", "value" };
            return Self{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .entries = [_]*DiskEntry{page_size} ** max_level,
                .cache = Cache(page_size).init(allocator),
                .table = try ColumnTable(page_size).init(allocator, &column_names),
            };
        }

        pub fn deinit(self: *Self) void {
            self.table.deinit();
            self.cache.deinit();
            self.allocator.free(self.name);
            self.allocator.destroy(self);
        }

        pub fn insert(self: *Self, series_key: []const u8, data_point: DataPoint) !void {
            try self.cache.insert(series_key, data_point);
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

        pub fn queryCache(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            return try self.cache.getRange(series_key, timestamp_start, timestamp_end);
        }

        pub fn queryTable(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            const series_ids = self.table.index_series.get(series_key) orelse error.InvalidSeries;
            const time_values = try self.table.getColumnRange("time", series_ids[0], series_ids[1]);

            var timestamp_ids: [2]?u64 = .{ null, null };
            for (time_values, series_ids[0]..series_ids[1]) |time, time_id| {
                if (time.Int >= timestamp_start and time.Int <= timestamp_end) {
                    if (timestamp_ids[0] == null or time_id < timestamp_ids[0].?) timestamp_ids[0] = @intCast(time_id);
                    if (timestamp_ids[1] == null or time_id > timestamp_ids[1].?) timestamp_ids[1] = @intCast(time_id);
                }
            }
            return try self.table.getColumnRange("value", timestamp_ids[0], timestamp_ids[1]);
        }

        pub fn queryDisk(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            var values = try self.allocator.alloc(Value, self.entries.len);
            var offset: usize = 0;
            for (self.entries, 0..@as(usize, @intCast(self.entries_count))) |en, _| {
                const series_ids = en.index_series.get(series_key) orelse error.InvalidSeries;
                const time_values = try en.getColumnRange("time", series_ids[0], series_ids[1]);

                var timestamp_ids: [2]u64 = undefined;
                for (time_values, series_ids[0]..series_ids[1]) |time, time_id| {
                    if (time.Int >= timestamp_start and time.Int <= timestamp_end) {
                        if (timestamp_ids and time.Int <= timestamp_ids[0]) timestamp_ids[0] = @intCast(time_id);
                        if (timestamp_ids and time.Int >= timestamp_ids[1]) timestamp_ids[1] = @intCast(time_id);
                    }
                }
                const values_entry = try en.getColumnRange("value", timestamp_ids[0], timestamp_ids[1]);
                @memcpy(values[offset..][0..values_entry.len], &values_entry);
                offset += values_entry.len;
            }

            return values;
        }

        pub fn query(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64, op: QueryOp) !Value {
            const values_cache = try self.queryCache(series_key, timestamp_start, timestamp_end);
            defer self.allocator.free(values_cache);
            const values_table = try self.queryTable(series_key, timestamp_start, timestamp_end);
            defer self.allocator.free(values_table);
            const values_disk = try self.queryDisk(series_key, timestamp_start, timestamp_end);
            defer self.allocator.free(values_disk);

            const values = try std.mem.concat(self.allocator, Value, &.{ values_cache, values_table, values_disk });
            defer self.allocator.free(values);

            return switch (op) {
                .AVG => blk: {
                    var sum: f64 = 0.0;
                    for (values) |value| {
                        sum += value.Float;
                    }
                    break :blk Value{ .Float = sum / @as(f64, @intCast(values.len)) };
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
                .COUNT => Value{ .Float = @intCast(values.len) },
            };
        }

        pub fn queryRaw(self: *Self, series_key: []const u8, timestamp_start: i64, timestamp_end: i64) ![]Value {
            const value_cache = try self.queryCache(series_key, timestamp_start, timestamp_end);
            defer self.allocator.free(value_cache);
            const value_table = try self.queryTable(series_key, timestamp_start, timestamp_end);
            defer self.allocator.free(value_table);
            const value_disk = try self.queryDisk(series_key, timestamp_start, timestamp_end);
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
                    var entry_id = self.entries_count - 1;
                    while (entry_id > 0) {
                        const en = self.entries[entry_id];
                        if (en.metadata.number_rows > 0) {
                            const series_ids = en.index_series.get(series_key) orelse continue;
                            const time = en.getColumnRange("time", series_ids[0], series_ids[1]) catch continue;
                            const value = en.getColumnRange("value", series_ids[0], series_ids[1]) catch continue;

                            datapoint.timestamp = time[0].Int;
                            datapoint.value = value[0];
                            return datapoint;
                        }
                        entry_id -= 1;
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

                    datapoint.timestamp = skiplist.head.key;
                    datapoint.value = skiplist.head.value;
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

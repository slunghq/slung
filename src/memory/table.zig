//! Columnar table
//!
//! General-purpose append-oriented column store with arbitrary named columns
//! and typed values. Optimised for ingestion and column-oriented reads.
//!
//! Design:
//! + One ArrayListUnmanaged(Value) per column - no serialization, direct storage
//! + Row lookup by key via StringHashMap(u64) row_id index
//! + Column lookup by name via StringHashMap(u32) column index
//! + Bloom filter for O(1) definite-miss short-circuit on get()
//! + Bytes values are owned (duped on insert, freed on deinit/clear)
//! + Pre-allocate with reserve() before bulk ingestion to eliminate realloc churn

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const bloom = @import("../primitives/bloom.zig");
const Bloom = bloom.Bloom;
const DefaultHashFn = bloom.DefaultHashFn;

pub const ColumnTable = struct {
    const Self = @This();
    pub const Value = @import("../types.zig").Value;

    allocator: Allocator,
    num_rows: u64,
    columns: []Column,
    bloom: Bloom(4096, DefaultHashFn),
    index_row: std.StringHashMapUnmanaged(u64),
    index_column: std.StringHashMapUnmanaged(u32),

    pub const Row = struct {
        key: []const u8,
        values: []Value,

        pub fn deinit(self: Row, allocator: Allocator) void {
            allocator.free(self.key);
            for (self.values) |v| {
                if (v == .Bytes) allocator.free(v.Bytes);
            }
            allocator.free(self.values);
        }
    };

    pub const Column = struct {
        name: []const u8,
        data: std.ArrayListUnmanaged(Value),
    };

    pub fn init(allocator: Allocator, column_names: []const []const u8) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.num_rows = 0;
        self.bloom = Bloom(4096, DefaultHashFn).init();
        errdefer self.bloom.deinit();
        self.index_row = .{};
        self.index_column = .{};
        self.columns = try allocator.alloc(Column, column_names.len);
        errdefer allocator.free(self.columns);

        for (self.columns, 0..) |*col, i| {
            col.name = try allocator.dupe(u8, column_names[i]);
            errdefer allocator.free(col.name);
            col.data = .empty;
            try self.index_column.put(allocator, col.name, @intCast(i));
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.columns) |*col| {
            for (col.data.items) |v| {
                if (v == .Bytes) self.allocator.free(v.Bytes);
            }
            col.data.deinit(self.allocator);
            self.allocator.free(col.name);
        }
        self.allocator.free(self.columns);
        self.bloom.deinit();
        var iter = self.index_row.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.index_row.deinit(self.allocator);
        self.index_column.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn clear(self: *Self) void {
        for (self.columns) |*col| {
            for (col.data.items) |v| {
                if (v == .Bytes) self.allocator.free(v.Bytes);
            }
            col.data.clearRetainingCapacity();
        }
        self.bloom.reset();
        var iter = self.index_row.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.index_row.clearRetainingCapacity();
        self.num_rows = 0;
    }

    /// Pre-allocate capacity for n rows per column.
    /// Call before bulk ingestion to eliminate realloc churn.
    pub fn reserve(self: *Self, n: usize) !void {
        for (self.columns) |*col| {
            try col.data.ensureTotalCapacity(self.allocator, n);
        }
        try self.index_row.ensureTotalCapacity(self.allocator, @intCast(n));
    }

    pub fn insert(self: *Self, row: Row) !void {
        // TODO: tombstone
        if (row.values.len != self.columns.len) return error.ColumnCountMismatch;

        const row_id = self.num_rows;

        self.bloom.insert(row.key);

        for (row.values, 0..) |value, i| {
            const stored: Value = switch (value) {
                .Bytes => |b| blk: {
                    const owned = try self.allocator.dupe(u8, b);
                    errdefer self.allocator.free(owned);
                    break :blk .{ .Bytes = owned };
                },
                else => value,
            };
            try self.columns[i].data.append(self.allocator, stored);
        }

        const owned_key = try self.allocator.dupe(u8, row.key);
        errdefer self.allocator.free(owned_key);

        const gop = try self.index_row.getOrPut(self.allocator, owned_key);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
        } else {
            gop.key_ptr.* = owned_key;
        }
        gop.value_ptr.* = row_id;
        self.num_rows += 1;
    }

    pub fn get(self: *Self, key: []const u8) !?Row {
        if (!self.bloom.contains(key)) return null;
        const row_id = self.index_row.get(key) orelse return null;

        const vals = try self.allocator.alloc(Value, self.columns.len);
        var duped: usize = 0;

        errdefer {
            for (vals[0..duped]) |v| {
                if (v == .Bytes) self.allocator.free(v.Bytes);
            }
            self.allocator.free(vals);
        }

        for (self.columns, 0..) |*col, i| {
            const v = col.data.items[row_id];
            vals[i] = switch (v) {
                .Bytes => |b| .{ .Bytes = try self.allocator.dupe(u8, b) },
                else => v,
            };
            duped += 1;
        }

        return Row{
            .key = try self.allocator.dupe(u8, key),
            .values = vals,
        };
    }

    /// Returns a non-owning slice directly into the column's storage.
    pub fn getColumn(self: *Self, column_name: []const u8) ![]const Value {
        const col_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
        return self.columns[col_id].data.items;
    }

    /// Returns a non-owning slice directly into the column's storage.
    pub fn getColumnRange(self: *Self, column_name: []const u8, start_row: u64, end_row: u64) ![]const Value {
        const col_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
        return self.getColumnRangeById(col_id, start_row, end_row);
    }

    /// Returns a non-owning slice directly into the column's storage.
    pub fn getColumnById(self: *Self, column_id: u32) ![]const Value {
        if (column_id >= self.columns.len) return error.InvalidColumnId;
        return self.columns[column_id].data.items;
    }

    /// Returns a non-owning slice directly into the column's storage.
    pub fn getColumnRangeById(self: *Self, column_id: u32, start_row: u64, end_row: u64) ![]const Value {
        if (column_id >= self.columns.len) return error.InvalidColumnId;
        if (end_row >= self.num_rows) return error.RowOutOfBounds;
        if (start_row > end_row) return error.InvalidRange;
        return self.columns[column_id].data.items[start_row .. end_row + 1];
    }

    pub fn getLatest(self: *Self, column_name: []const u8) !Value {
        const col_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
        const col = &self.columns[col_id];
        if (col.data.items.len == 0) return error.EmptyColumn;
        return col.data.items[col.data.items.len - 1];
    }

    pub fn getByRow(self: *Self, column_name: []const u8, row: u64) !Value {
        if (row >= self.num_rows) return error.RowOutOfBounds;
        const col_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
        return self.columns[col_id].data.items[row];
    }
};

const Mutex = @import("../primitives/mutex.zig").Mutex(ColumnTable);
pub const SafeColumnTable = @import("../primitives/arc.zig").Arc(Mutex);

test "ColumnTable: insert and get" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{ "id", "name", "age" };
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    const v1 = [_]ColumnTable.Value{ .{ .Int = 1 }, .{ .Bytes = "Alice" }, .{ .Int = 19 } };
    try table.insert(.{ .key = "user1", .values = @constCast(&v1) });

    const v2 = [_]ColumnTable.Value{ .{ .Int = 2 }, .{ .Bytes = "Bob" }, .{ .Int = 25 } };
    try table.insert(.{ .key = "user2", .values = @constCast(&v2) });

    try testing.expectEqual(@as(u64, 2), table.num_rows);

    const row = (try table.get("user1")).?;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("user1", row.key);
    try testing.expectEqual(@as(i64, 1), row.values[0].Int);
    try testing.expectEqualStrings("Alice", row.values[1].Bytes);
    try testing.expectEqual(@as(i64, 19), row.values[2].Int);
}

test "ColumnTable: get column" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{ "id", "score" };
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    const v1 = [_]ColumnTable.Value{ .{ .Int = 1 }, .{ .Float = 9.5 } };
    const v2 = [_]ColumnTable.Value{ .{ .Int = 2 }, .{ .Float = 7.0 } };
    const v3 = [_]ColumnTable.Value{ .{ .Int = 3 }, .{ .Float = 8.25 } };
    try table.insert(.{ .key = "a", .values = @constCast(&v1) });
    try table.insert(.{ .key = "b", .values = @constCast(&v2) });
    try table.insert(.{ .key = "c", .values = @constCast(&v3) });

    const scores = try table.getColumn("score");
    try testing.expectEqual(@as(usize, 3), scores.len);
    try testing.expectApproxEqAbs(@as(f64, 9.5), scores[0].Float, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 7.0), scores[1].Float, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 8.25), scores[2].Float, 0.001);
}

test "ColumnTable: getColumnRange" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{"val"};
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    for (0..5) |i| {
        var v = [_]ColumnTable.Value{.{ .Int = @intCast(i * 10) }};
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "r{d}", .{i});
        try table.insert(.{ .key = key, .values = &v });
    }

    const range = try table.getColumnRange("val", 1, 3);
    try testing.expectEqual(@as(usize, 3), range.len);
    try testing.expectEqual(@as(i64, 10), range[0].Int);
    try testing.expectEqual(@as(i64, 20), range[1].Int);
    try testing.expectEqual(@as(i64, 30), range[2].Int);
}

test "ColumnTable: getLatest and getByRow" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{"v"};
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    var v1 = [_]ColumnTable.Value{.{ .Int = 100 }};
    var v2 = [_]ColumnTable.Value{.{ .Int = 200 }};
    try table.insert(.{ .key = "a", .values = &v1 });
    try table.insert(.{ .key = "b", .values = &v2 });

    try testing.expectEqual(@as(i64, 200), (try table.getLatest("v")).Int);
    try testing.expectEqual(@as(i64, 100), (try table.getByRow("v", 0)).Int);
    try testing.expectEqual(@as(i64, 200), (try table.getByRow("v", 1)).Int);
}

test "ColumnTable: reserve and bulk insert" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{ "ts", "val" };
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    try table.reserve(1000);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var v = [_]ColumnTable.Value{ .{ .Int = @intCast(i) }, .{ .Float = @as(f64, @floatFromInt(i)) * 1.5 } };
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "row{d}", .{i});
        try table.insert(.{ .key = key, .values = &v });
    }

    try testing.expectEqual(@as(u64, 1000), table.num_rows);
    try testing.expectEqual(@as(i64, 999), (try table.getLatest("ts")).Int);
}

test "ColumnTable: clear" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{"x"};
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    var v = [_]ColumnTable.Value{.{ .Int = 42 }};
    try table.insert(.{ .key = "k", .values = &v });
    try testing.expectEqual(@as(u64, 1), table.num_rows);

    table.clear();
    try testing.expectEqual(@as(u64, 0), table.num_rows);
    try testing.expectEqual(null, try table.get("k"));
}

test "ColumnTable: column count mismatch" {
    const allocator = testing.allocator;
    const col_names = [_][]const u8{ "a", "b" };
    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();

    var v = [_]ColumnTable.Value{.{ .Int = 1 }};
    try testing.expectError(error.ColumnCountMismatch, table.insert(.{ .key = "k", .values = &v }));
}

//! Columnar table
//!

const std = @import("std");
const time = std.time;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;
const ds = @import("../ds/ds.zig");
const Bloom = ds.bloom.Bloom;
const Bitmap = ds.bitmap.Bitmap;
const Hasher = ds.bloom.DefaultHashFn;

fn ColumnTableImpl(comptime page_size: u32) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        metadata: Metadata,
        columns: []Column,
        bloom: Bloom(1024, Hasher),

        index_row: HashMap(u64),
        index_column: HashMap(u64),
        /// the series index tracks the
        /// starting and ending position
        /// of a particular series entry.
        ///
        /// [start, end]
        series_index: HashMap([2]u64),

        pub const Metadata = struct {
            number_rows: u64,
            number_columns: u32,
            created_at: i64,
            updated_at: i64,
        };

        pub const Row = struct {
            key: []const u8,
            values: []Value,

            pub fn deinit(self: Row, allocator: Allocator) void {
                allocator.free(self.key);
                for (self.values) |value| {
                    switch (value) {
                        .Bytes => |bytes| allocator.free(bytes),
                        else => {},
                    }
                }
                allocator.free(self.values);
            }
        };

        pub const Column = struct {
            name: []const u8,
            pages: ArrayList(Page),
            null_bitmap: ?Bitmap(page_size),
            row_offsets: AutoHashMap(u64, RowOffset),
            current_offset: u32,

            pub const Page = struct {
                data: [page_size]u8 = std.mem.zeroes([page_size]u8),
                start: u64,
                end: u64,
                min_value: ?*Value,
                max_value: ?*Value,
            };

            pub const RowOffset = struct {
                row_id: u64,
                page_id: u64,
                offset: u64,
                len: u64,
            };
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

        pub fn init(allocator: Allocator, column_names: []const []const u8) !*Self {
            var table = try allocator.create(Self);
            table.allocator = allocator;
            table.metadata = Metadata{
                .number_rows = 0,
                .number_columns = @intCast(column_names.len),
                // TODO: consider using in-runtime clock to reduce io
                .created_at = time.timestamp(),
                .updated_at = time.timestamp(),
            };
            table.columns = try allocator.alloc(Column, column_names.len);
            table.bloom = Bloom(
                1024,
                Hasher,
            ).init();
            table.index_row = HashMap(u64).init(allocator);
            table.index_column = HashMap(u64).init(allocator);

            for (table.columns, 0..) |*column, i| {
                column.name = try allocator.dupe(u8, column_names[i]);
                column.pages = .empty;
                column.row_offsets = AutoHashMap(u64, Column.RowOffset).init(allocator);
                column.current_offset = 0;

                try column.pages.append(allocator, Column.Page{
                    .start = 0,
                    .end = 0,
                    .min_value = null,
                    .max_value = null,
                });

                try table.index_column.put(column.name, i);
            }
            return table;
        }

        pub fn deinit(self: *Self) void {
            for (self.columns) |*column| {
                self.allocator.free(column.name);
                for (column.pages.items) |page| {
                    if (page.min_value) |v| self.allocator.destroy(v);
                    if (page.max_value) |v| self.allocator.destroy(v);
                }
                column.pages.deinit(self.allocator);
                column.row_offsets.deinit();
            }

            self.allocator.free(self.columns);
            self.index_row.deinit();
            self.index_column.deinit();

            self.allocator.destroy(self);
        }

        fn serializeValue(self: *Self, value: Value) ![]u8 {
            var buffer: ArrayList(u8) = .empty;
            defer buffer.deinit(self.allocator);

            try buffer.append(self.allocator, @intFromEnum(value));

            switch (value) {
                .Bool => |v| try buffer.append(self.allocator, @intFromBool(v)),
                .Int => |v| try buffer.writer(self.allocator).writeInt(i64, v, .little),
                .Float => |v| try buffer.writer(self.allocator).writeAll(std.mem.asBytes(&v)),
                .Bytes => |v| {
                    try buffer.writer(self.allocator).writeInt(u32, @intCast(v.len), .little);
                    try buffer.writer(self.allocator).writeAll(v);
                },
            }

            return buffer.toOwnedSlice(self.allocator);
        }

        fn deserializeValue(self: *Self, data: []const u8, len: u64) !Value {
            _ = self;
            const tag = @as(std.meta.Tag(Value), @enumFromInt(data[0]));
            return switch (tag) {
                .Bool => Value{ .Bool = data[1] != 0 },
                .Int => Value{ .Int = std.mem.readInt(i64, data[1..9], .little) },
                .Float => blk: {
                    var val: f64 = undefined;
                    @memcpy(std.mem.asBytes(&val), data[1..9]);
                    break :blk Value{ .Float = val };
                },
                .Bytes => blk: {
                    break :blk Value{ .Bytes = data[5..len] };
                },
            };
        }

        fn copyValue(self: *Self, value: Value) !Value {
            return switch (value) {
                .Bool => |v| Value{ .Bool = v },
                .Int => |v| Value{ .Int = v },
                .Float => |v| Value{ .Float = v },
                .Bytes => |v| Value{ .Bytes = try self.allocator.dupe(u8, v) },
            };
        }

        fn getValueAt(self: *Self, column: *const Column, row_id: u64) !Value {
            const row_offset = column.row_offsets.get(row_id);
            const page = column.pages.items[row_offset.?.page_id];
            const data = page.data[row_offset.?.offset..];

            return try self.deserializeValue(data, row_offset.?.len);
        }

        pub fn insert(self: *Self, row: Row) !void {
            if (row.values.len != self.columns.len) {
                return error.ColumnCountMismatch;
            }

            const row_id = self.metadata.number_rows;

            self.bloom.insert(row.key);
            try self.index_row.put(row.key, row_id);

            for (row.values, 0..) |value, column_id| {
                var column = &self.columns[column_id];
                var page = &column.pages.items[column.pages.items.len - 1];

                const serialized = try self.serializeValue(value);
                defer self.allocator.free(serialized);

                if (column.current_offset + serialized.len > page_size) {
                    page.end = row_id - 1;

                    const new_page = Column.Page{
                        .data = std.mem.zeroes([page_size]u8),
                        .start = row_id,
                        .end = row_id,
                        .min_value = null,
                        .max_value = null,
                    };

                    try column.pages.append(self.allocator, new_page);
                    page = &column.pages.items[column.pages.items.len - 1];
                    column.current_offset = 0;
                }

                try column.row_offsets.put(row_id, Column.RowOffset{
                    .row_id = row_id,
                    .page_id = column.pages.items.len - 1,
                    .offset = column.current_offset,
                    .len = @intCast(serialized.len),
                });

                @memcpy(page.data[column.current_offset..][0..serialized.len], serialized);
                column.current_offset += @intCast(serialized.len);
                page.end = row_id;

                // if (page.min_value == null or value.compare(page.min_value.?.*) == .lt) {
                //     if (page.min_value) |old| self.allocator.destroy(old);
                //     page.min_value = try self.allocator.create(Value);
                //     page.min_value.?.* = try self.copyValue(value);
                // }
                // if (page.max_value == null or value.compare(page.max_value.?.*) == .gt) {
                //     if (page.max_value) |old| self.allocator.destroy(old);
                //     page.max_value = try self.allocator.create(Value);
                //     page.max_value.?.* = try self.copyValue(value);
                // }
            }

            self.metadata.number_rows += 1;
            self.metadata.updated_at = time.timestamp();
        }

        pub fn get(self: *Self, key: []const u8) !?Row {
            if (!self.bloom.contains(key)) {
                return null;
            }

            const row_id = self.index_row.get(key);
            if (row_id == null) return null;

            const values = try self.allocator.alloc(Value, self.columns.len);
            errdefer self.allocator.free(values);

            for (self.columns, 0..) |column, i| {
                const data = try self.getValueAt(&column, row_id.?);

                values[i] = switch (data) {
                    .Bytes => |bytes| Value{ .Bytes = try self.allocator.dupe(u8, bytes) },
                    else => data,
                };
            }

            return Row{
                .key = try self.allocator.dupe(u8, key),
                .values = values,
            };
        }

        pub fn getColumn(self: *Self, column_name: []const u8) ![]Value {
            const column_id = self.index_column.get(column_name);
            return self.getColumnById(column_id.?);
        }

        pub fn getColumnRange(self: *Self, column_name: []const u8, start_row: u64, end_row: u64) ![]Value {
            const column_id = self.index_column.get(column_name);
            return self.getColumnRangeById(column_id.?, start_row, end_row);
        }

        pub fn getColumnById(self: *Self, column_id: usize) ![]Value {
            if (column_id >= self.columns.len) return error.InvalidColumnId;

            const column = &self.columns[column_id];
            var values = try self.allocator.alloc(Value, @intCast(self.metadata.number_rows));
            errdefer self.allocator.free(values);

            var value_id: usize = 0;
            for (column.pages.items) |page| {
                var row = page.start;
                while (row <= page.end) : (row += 1) {
                    values[value_id] = try self.getValueAt(column, row);
                    value_id += 1;
                }
            }

            return values;
        }

        pub fn getColumnRangeById(self: *Self, column_id: usize, start_row: u64, end_row: u64) ![]Value {
            if (column_id >= self.columns.len) return error.InvalidColumnIndex;
            if (end_row >= self.metadata.number_rows) return error.RowOutOfBounds;
            if (start_row > end_row) return error.InvalidRange;

            const column = &self.columns[column_id];
            const count = end_row - start_row + 1;
            var values = try self.allocator.alloc(Value, @intCast(count));
            errdefer self.allocator.free(values);

            var value_id: usize = 0;

            var row = start_row;
            while (row <= end_row) : (row += 1) {
                values[value_id] = try self.getValueAt(column, row);
                value_id += 1;
            }

            return values;
        }

        // TODO: implement other get helpers
    };
}

pub const ColumnTable = ColumnTableImpl;

test "column table" {
    const allocator = std.testing.allocator;
    const page_size = 4096;
    const column_names = [_][]const u8{ "id", "name", "age" };
    var table = try ColumnTable(page_size).init(allocator, &column_names);
    defer table.deinit();

    const values1 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values1[0] = .{ .Int = 1 };
    values1[1] = .{ .Bytes = "Alice" };
    values1[2] = .{ .Bool = false };
    defer allocator.free(values1);
    const row1 = ColumnTable(page_size).Row{
        .key = "user1",
        .values = values1,
    };
    try table.insert(row1);

    const values2 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values2[0] = .{ .Int = 2 };
    values2[1] = .{ .Bytes = "Bob" };
    values2[2] = .{ .Int = 25 };
    defer allocator.free(values2);
    const row2 = ColumnTable(page_size).Row{
        .key = "user2",
        .values = values2,
    };
    try table.insert(row2);

    const result = try table.get("user1");
    defer result.?.deinit(allocator);
    try std.testing.expectEqualStrings("Alice", result.?.values[1].Bytes);
    try std.testing.expectEqual(1, result.?.values[0].Int);
    try std.testing.expect(!result.?.values[2].Bool);
}

test "column table get column" {
    const allocator = std.testing.allocator;
    const page_size = 4096;
    const column_names = [_][]const u8{ "id", "name", "age" };
    var table = try ColumnTable(page_size).init(allocator, &column_names);
    defer table.deinit();

    const values1 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values1[0] = .{ .Int = 1 };
    values1[1] = .{ .Bytes = "Alice" };
    values1[2] = .{ .Int = 19 };
    defer allocator.free(values1);
    const row1 = ColumnTable(page_size).Row{
        .key = "user1",
        .values = values1,
    };
    try table.insert(row1);

    const values2 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values2[0] = .{ .Int = 2 };
    values2[1] = .{ .Bytes = "Bob" };
    values2[2] = .{ .Int = 25 };
    defer allocator.free(values2);
    const row2 = ColumnTable(page_size).Row{
        .key = "user2",
        .values = values2,
    };
    try table.insert(row2);

    const result = try table.getColumn("name");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Alice", result[0].Bytes);
    try std.testing.expectEqualStrings("Bob", result[1].Bytes);

    const result2 = try table.getColumn("age");
    defer allocator.free(result2);
    try std.testing.expectEqual(25, result2[1].Int);
    try std.testing.expectEqual(19, result2[0].Int);

    const values3 = try allocator.alloc(ColumnTable(page_size).Value, 3);
    values3[0] = .{ .Int = 3 };
    values3[1] = .{ .Bytes = "Jake" };
    values3[2] = .{ .Int = 21 };
    defer allocator.free(values3);
    const row3 = ColumnTable(page_size).Row{
        .key = "user3",
        .values = values3,
    };
    try table.insert(row3);

    const result3 = try table.getColumnRange("age", 0, 2);
    defer allocator.free(result3);
    try std.testing.expectEqual(21, result3[2].Int);
    try std.testing.expectEqual(25, result3[1].Int);
    try std.testing.expectEqual(19, result3[0].Int);
}

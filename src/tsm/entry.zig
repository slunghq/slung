//! Disk entry
//!
//! Used for flushing and querying the columnar table to and from disk
//!

const std = @import("std");
const fs = std.fs;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;
const ColumnTable = @import("table.zig").ColumnTable;
const Bloom = ds.bloom.Bloom;
const Hasher = ds.bloom.DefaultHashFn;

fn DiskEntryImpl(comptime page_size: u32) type {
    return struct {
        const Self = @This();
        const MAGIC = "SLZ01";
        const VERSION = 1;

        allocator: Allocator,
        file_path: []const u8,
        file_data: fs.File,
        file_index: fs.File,
        index_row: HashMap(u64),
        index_series: HashMap([2]u64),
        bloom: Bloom(1024, Hasher),

        metadata: Metadata,
        column_descriptors: []ColumnDescriptor,

        pub const Metadata = struct {
            number_rows: u64,
            number_columns: u32,
            created_at: i64,
            page_size: u32,
            /// helps with versioning and compatibility
            version: u32,
        };

        pub const ColumnDescriptor = struct {
            name: []const u8,
            data_offset: u64,
            data_size: u64,
            num_pages: u32,
            offset_index_page: u64,
            offset_offsets_row: u64,
        };

        pub const PageDescriptor = struct {
            data_offset: u64,
            data_size: u32,
            start_row: u64,
            end_row: u64,
        };

        pub const RowOffset = struct {
            row_id: u64,
            page_id: u64,
            offset: u64,
            len: u64,
        };

        const Value = ColumnTable(page_size).Value;

        pub fn flush(allocator: Allocator, table: *ColumnTable(page_size), file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);

            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.dat", .{ level, file_path });
            defer allocator.free(path_data);
            entry.file_data = try fs.cwd().createFile(path_data, .{ .read = true });

            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx", .{ level, file_path });
            defer allocator.free(path_index);
            entry.file_index = try fs.cwd().createFile(path_index, .{ .read = true });

            entry.index_row = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();

            entry.metadata = Metadata{
                .number_rows = table.metadata.number_rows,
                .number_columns = table.metadata.number_columns,
                .created_at = table.metadata.created_at,
                .page_size = page_size,
                .version = VERSION,
            };
            entry.column_descriptors = try allocator.alloc(
                ColumnDescriptor,
                table.columns.len,
            );

            // use a single writer and track positions manually
            var buffer_index: [8192]u8 = undefined;
            var writer_index = entry.file_index.writer(&buffer_index);
            var pos_index: u64 = 0;
            var pos_data: u64 = 0;
            var buffer_data: [8192]u8 = undefined;
            var writer_data = entry.file_data.writer(&buffer_data);

            for (table.columns, 0..) |*column, column_id| {
                pos_index = try entry.writeColumn(&writer_data, &writer_index, &pos_index, column, column_id, &pos_data);
            }

            const offset_bloom = pos_index;
            pos_index = try entry.writeBloomFilter(&writer_index, &pos_index, &table.bloom);

            const offset_index_row = pos_index;
            pos_index = try entry.writeRowIndex(&writer_index, &pos_index, &table.index_row);

            const offset_index_series = pos_index;
            pos_index = try entry.writeSeriesIndex(&writer_index, &pos_index, &table.index_series);

            _ = try entry.writeFooter(&writer_index, &pos_index, offset_bloom, offset_index_row, offset_index_series);

            try writer_data.interface.flush();
            try writer_index.interface.flush();

            return entry;
        }

        pub fn deinit(self: *Self) void {
            self.file_data.close();
            self.file_index.close();
            self.allocator.free(self.file_path);
            self.index_row.deinit();
            self.index_series.deinit();
            self.bloom.deinit();
            for (self.column_descriptors) |column_descriptor| {
                self.allocator.free(column_descriptor.name);
            }
            self.allocator.free(self.column_descriptors);
            self.allocator.destroy(self);
        }

        fn writeColumn(self: *Self, writer_data: anytype, writer_index: anytype, pos_index: *u64, column: *ColumnTable(page_size).Column, column_id: usize, data_offset: *u64) !u64 {
            const data_start: u64 = data_offset.*;
            const offset_index_page = pos_index.*;
            var total_data_size: u64 = 0;

            try writer_index.interface.writeInt(u32, @intCast(column.pages.items.len), .little);
            pos_index.* += @sizeOf(u32);

            var pos_data: u64 = data_start;

            for (column.pages.items, 0..) |page, page_id| {
                const page_offset = pos_data;
                const actual_size = if (page_id == column.pages.items.len - 1) column.current_offset else page_size;
                total_data_size += actual_size;

                try writer_data.interface.writeAll(page.data[0..actual_size]);
                pos_data += actual_size;

                try writer_index.interface.writeInt(u64, page_offset, .little);
                try writer_index.interface.writeInt(u32, actual_size, .little);
                try writer_index.interface.writeInt(u64, page.start, .little);
                try writer_index.interface.writeInt(u64, page.end, .little);
                pos_index.* += @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64);
            }

            try writer_index.interface.writeInt(u64, column.row_offsets.count(), .little);
            pos_index.* += @sizeOf(u64);

            var iter = column.row_offsets.iterator();
            while (iter.next()) |entry| {
                try writer_index.interface.writeInt(u64, entry.key_ptr.*, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.row_id, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.page_id, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.offset, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.len, .little);
                pos_index.* += @sizeOf(u64) * 5;
            }

            const offset_offsets_row = pos_index.*;

            self.column_descriptors[column_id] = ColumnDescriptor{
                .name = try self.allocator.dupe(u8, column.name),
                .data_offset = data_start,
                .data_size = total_data_size,
                .num_pages = @intCast(column.pages.items.len),
                .offset_index_page = offset_index_page,
                .offset_offsets_row = offset_offsets_row,
            };

            data_offset.* = pos_data;

            return pos_index.*;
        }

        fn writeBloomFilter(self: *Self, writer_index: anytype, pos_index: *u64, bloom: *Bloom(1024, Hasher)) !u64 {
            _ = self;
            try writer_index.interface.writeInt(u64, bloom.len(), .little);
            pos_index.* += @sizeOf(u64);

            try writer_index.interface.writeAll(&bloom.mask.bits);
            pos_index.* += bloom.mask.bits.len;

            return pos_index.*;
        }

        fn writeSeriesIndex(self: *Self, writer_index: anytype, pos_index: *u64, index: *const HashMap([2]u64)) !u64 {
            _ = self;
            try writer_index.interface.writeInt(u64, @intCast(index.count()), .little);
            pos_index.* += @sizeOf(u64);

            var iter = index.iterator();
            while (iter.next()) |entry| {
                const key_len: u32 = @intCast(entry.key_ptr.len);
                try writer_index.interface.writeInt(u32, key_len, .little);
                pos_index.* += @sizeOf(u32);

                try writer_index.interface.writeAll(entry.key_ptr.*);
                pos_index.* += entry.key_ptr.len;

                try writer_index.interface.writeAll(std.mem.asBytes(&entry.value_ptr.*));
                pos_index.* += @sizeOf([2]u64);
            }

            return pos_index.*;
        }

        fn writeRowIndex(self: *Self, writer_index: anytype, pos_index: *u64, index: *const HashMap(u64)) !u64 {
            _ = self;
            try writer_index.interface.writeInt(u64, @intCast(index.count()), .little);
            pos_index.* += @sizeOf(u64);

            var iter = index.iterator();
            while (iter.next()) |entry| {
                const key_len: u32 = @intCast(entry.key_ptr.len);
                try writer_index.interface.writeInt(u32, key_len, .little);
                pos_index.* += @sizeOf(u32);

                try writer_index.interface.writeAll(entry.key_ptr.*);
                pos_index.* += entry.key_ptr.len;

                try writer_index.interface.writeInt(u64, entry.value_ptr.*, .little);
                pos_index.* += @sizeOf(u64);
            }

            return pos_index.*;
        }

        fn writeFooter(self: *Self, writer_index: anytype, pos_index: *u64, offset_bloom: u64, offset_index_row: u64, offset_index_series: u64) !u64 {
            const footer_start = pos_index.*;

            try writer_index.interface.writeInt(u64, offset_bloom, .little);
            try writer_index.interface.writeInt(u64, offset_index_row, .little);
            try writer_index.interface.writeInt(u64, offset_index_series, .little);
            pos_index.* += @sizeOf(u64) * 3;

            try writer_index.interface.writeInt(u64, self.metadata.number_rows, .little);
            try writer_index.interface.writeInt(u32, self.metadata.number_columns, .little);
            try writer_index.interface.writeInt(i64, self.metadata.created_at, .little);
            try writer_index.interface.writeInt(u32, self.metadata.page_size, .little);
            try writer_index.interface.writeInt(u32, self.metadata.version, .little);
            pos_index.* += @sizeOf(u64) + @sizeOf(u32) + @sizeOf(i64) + @sizeOf(u32) + @sizeOf(u32);

            for (self.column_descriptors) |desc| {
                const name_len: u32 = @intCast(desc.name.len);
                try writer_index.interface.writeInt(u32, name_len, .little);
                pos_index.* += @sizeOf(u32);

                try writer_index.interface.writeAll(desc.name);
                pos_index.* += desc.name.len;

                try writer_index.interface.writeInt(u64, desc.data_offset, .little);
                try writer_index.interface.writeInt(u64, desc.data_size, .little);
                try writer_index.interface.writeInt(u32, desc.num_pages, .little);
                try writer_index.interface.writeInt(u64, desc.offset_index_page, .little);
                try writer_index.interface.writeInt(u64, desc.offset_offsets_row, .little);
                pos_index.* += @sizeOf(u64) * 4 + @sizeOf(u32);
            }

            try writer_index.interface.writeInt(u64, footer_start, .little);
            pos_index.* += @sizeOf(u64);

            try writer_index.interface.writeAll(MAGIC);
            pos_index.* += MAGIC.len;

            try writer_index.interface.flush();
            return pos_index.*;
        }

        pub fn open(allocator: Allocator, file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);

            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.dat", .{ level, file_path });
            defer allocator.free(path_data);
            entry.file_data = try fs.cwd().openFile(path_data, .{});

            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx", .{ level, file_path });
            defer allocator.free(path_index);
            entry.file_index = try fs.cwd().openFile(path_index, .{});

            entry.index_row = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();

            try entry.readFooter();

            return entry;
        }

        pub fn getColumnById(self: *Self, column_id: u64) ![]ColumnTable(page_size).Value {
            var buffer_index: [8192]u8 = undefined;
            var reader_index = self.file_index.reader(&buffer_index);
            var buffer_data: [8192]u8 = undefined;
            var reader_data = self.file_data.reader(&buffer_data);
            if (column_id >= self.column_descriptors.len) return error.InvalidColumnId;

            var row_offsets = AutoHashMap(u64, RowOffset).init(self.allocator);
            defer row_offsets.deinit();
            try self.loadRowOffsets(column_id, &row_offsets);

            const descriptor = &self.column_descriptors[column_id];
            try reader_index.seekTo(descriptor.offset_index_page);
            const num_pages = try reader_index.interface.takeInt(u32, .little);

            const page_descriptors = try self.allocator.alloc(PageDescriptor, num_pages);
            defer self.allocator.free(page_descriptors);

            for (page_descriptors) |*page_desc| {
                page_desc.* = PageDescriptor{
                    .data_offset = try reader_index.interface.takeInt(u64, .little),
                    .data_size = try reader_index.interface.takeInt(u32, .little),
                    .start_row = try reader_index.interface.takeInt(u64, .little),
                    .end_row = try reader_index.interface.takeInt(u64, .little),
                };
            }

            var values = try self.allocator.alloc(Value, @intCast(self.metadata.number_rows));
            var index_values: usize = 0;
            for (page_descriptors, 0..) |page_desc, page_id| {
                try reader_data.seekTo(page_desc.data_offset);
                var page_data = try self.allocator.alloc(u8, page_desc.data_size);
                defer self.allocator.free(page_data);
                _ = try reader_data.interface.readSliceAll(page_data);

                var row = page_desc.start_row;
                while (row <= page_desc.end_row) : (row += 1) {
                    const row_offset = row_offsets.get(row) orelse return error.RowOffsetNotFound;
                    if (row_offset.page_id != page_id) continue;

                    const data = page_data[row_offset.offset..];
                    values[index_values] = try self.deserializeValue(data, row_offset.len);
                    index_values += 1;
                }
            }

            return values;
        }

        pub fn getColumnRangeById(self: *Self, column_id: u64, start_row: u64, end_row: u64) ![]ColumnTable(page_size).Value {
            if (column_id >= self.column_descriptors.len) return error.InvalidColumnId;
            if (end_row >= self.metadata.number_rows) return error.InvalidRange;
            if (start_row > end_row) return error.InvalidRange;

            var buffer_index: [8192]u8 = undefined;
            var reader_index = self.file_index.reader(&buffer_index);
            var buffer_data: [8192]u8 = undefined;
            var reader_data = self.file_data.reader(&buffer_data);

            var row_offsets = AutoHashMap(u64, RowOffset).init(self.allocator);
            defer row_offsets.deinit();
            try self.loadRowOffsets(column_id, &row_offsets);

            const descriptor = &self.column_descriptors[column_id];
            try reader_index.seekTo(descriptor.offset_index_page);
            const num_pages = try reader_index.interface.takeInt(u32, .little);

            const page_descriptors = try self.allocator.alloc(PageDescriptor, num_pages);
            defer self.allocator.free(page_descriptors);

            for (page_descriptors) |*page_desc| {
                page_desc.* = PageDescriptor{
                    .data_offset = try reader_index.interface.takeInt(u64, .little),
                    .data_size = try reader_index.interface.takeInt(u32, .little),
                    .start_row = try reader_index.interface.takeInt(u64, .little),
                    .end_row = try reader_index.interface.takeInt(u64, .little),
                };
            }

            var values = try self.allocator.alloc(Value, @intCast(self.metadata.number_rows));
            var index_values: usize = 0;
            for (page_descriptors, 0..) |page_desc, page_id| {
                if (page_desc.end_row < start_row or page_desc.start_row > end_row) {
                    continue;
                }

                try reader_data.seekTo(page_desc.data_offset);
                var page_data = try self.allocator.alloc(u8, page_desc.data_size);
                defer self.allocator.free(page_data);
                _ = try reader_data.interface.readSliceAll(page_data);

                var row = @max(page_desc.start_row, start_row);
                const row_end = @min(page_desc.end_row, end_row);
                while (row <= row_end) : (row += 1) {
                    const row_offset = row_offsets.get(row) orelse return error.RowOffsetNotFound;
                    if (row_offset.page_id != page_id) continue;

                    const data = page_data[row_offset.offset..];
                    values[index_values] = try self.deserializeValue(data, row_offset.len);
                    index_values += 1;
                }
            }

            return values;
        }

        fn loadRowOffsets(self: *Self, column_id: usize, row_offsets: *AutoHashMap(u64, RowOffset)) !void {
            var buffer: [8192]u8 = undefined;
            var reader_index = self.file_index.reader(&buffer);
            const desc = &self.column_descriptors[column_id];

            try reader_index.seekTo(desc.offset_index_page);

            const num_pages = try reader_index.interface.takeInt(u32, .little);
            const page_desc_size = @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64);
            const row_offsets_pos = desc.offset_index_page + @sizeOf(u32) + (num_pages * page_desc_size);
            try reader_index.seekTo(row_offsets_pos);

            const count = try reader_index.interface.takeInt(u64, .little);

            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const row_id = try reader_index.interface.takeInt(u64, .little);
                const offset = RowOffset{
                    .row_id = try reader_index.interface.takeInt(u64, .little),
                    .page_id = try reader_index.interface.takeInt(u64, .little),
                    .offset = try reader_index.interface.takeInt(u64, .little),
                    .len = try reader_index.interface.takeInt(u64, .little),
                };
                try row_offsets.put(row_id, offset);
            }
        }

        fn deserializeValue(self: *Self, data: []const u8, len: u64) !Value {
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
                    const bytes = try self.allocator.dupe(u8, data[5..len]);
                    break :blk Value{ .Bytes = bytes };
                },
            };
        }

        fn readFooter(self: *Self) !void {
            const file_size = try self.file_index.getEndPos();

            var buffer: [8192]u8 = undefined;
            var reader_index = self.file_index.reader(&buffer);
            try reader_index.seekTo(file_size - 13); // 8 bytes offset + 5 bytes magic

            const footer_offset = try reader_index.interface.takeInt(u64, .little);

            var magic_buf: [5]u8 = undefined;
            _ = try reader_index.interface.readSliceAll(&magic_buf);
            if (!std.mem.eql(u8, &magic_buf, MAGIC)) {
                return error.InvalidFileFormat;
            }

            try reader_index.seekTo(footer_offset);

            const offset_bloom = try reader_index.interface.takeInt(u64, .little);
            const offset_index_row = try reader_index.interface.takeInt(u64, .little);
            const offset_index_series = try reader_index.interface.takeInt(u64, .little);

            self.metadata = Metadata{
                .number_rows = try reader_index.interface.takeInt(u64, .little),
                .number_columns = try reader_index.interface.takeInt(u32, .little),
                .created_at = try reader_index.interface.takeInt(i64, .little),
                .page_size = try reader_index.interface.takeInt(u32, .little),
                .version = try reader_index.interface.takeInt(u32, .little),
            };

            self.column_descriptors = try self.allocator.alloc(ColumnDescriptor, self.metadata.number_columns);

            for (self.column_descriptors) |*desc| {
                const name_len = try reader_index.interface.takeInt(u32, .little);
                const name = try self.allocator.alloc(u8, name_len);
                _ = try reader_index.interface.readSliceAll(name);

                desc.* = ColumnDescriptor{
                    .name = name,
                    .data_offset = try reader_index.interface.takeInt(u64, .little),
                    .data_size = try reader_index.interface.takeInt(u64, .little),
                    .num_pages = try reader_index.interface.takeInt(u32, .little),
                    .offset_index_page = try reader_index.interface.takeInt(u64, .little),
                    .offset_offsets_row = try reader_index.interface.takeInt(u64, .little),
                };
            }

            try reader_index.seekTo(offset_bloom);
            try self.readBloomFilter(&reader_index);

            try reader_index.seekTo(offset_index_row);
            try self.readRowIndex(&reader_index);

            try reader_index.seekTo(offset_index_series);
            try self.readSeriesIndex(&reader_index);
        }

        fn readBloomFilter(self: *Self, reader_index: anytype) !void {
            const len = try reader_index.interface.takeInt(u64, .little);
            if (len != self.bloom.len()) return error.BloomFilterSizeMismatch;

            _ = try reader_index.interface.readSliceAll(&self.bloom.mask.bits);
        }

        fn readRowIndex(self: *Self, reader_index: anytype) !void {
            const count = try reader_index.interface.takeInt(u64, .little);

            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const key_len = try reader_index.interface.takeInt(u32, .little);
                const key = try self.allocator.alloc(u8, key_len);
                defer self.allocator.free(key);
                _ = try reader_index.interface.readSliceAll(key);

                const row_id = try reader_index.interface.takeInt(u64, .little);
                try self.index_row.put(key, row_id);
            }
        }

        fn readSeriesIndex(self: *Self, reader_index: anytype) !void {
            const count = try reader_index.interface.takeInt(u64, .little);

            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const key_len = try reader_index.interface.takeInt(u32, .little);
                const key = try self.allocator.alloc(u8, key_len);
                defer self.allocator.free(key);
                _ = try reader_index.interface.readSliceAll(key);

                var range: [2]u64 = undefined;
                _ = try reader_index.interface.readSliceAll(std.mem.asBytes(&range));

                try self.index_series.put(key, range);
            }
        }
    };
}

pub const DiskEntry = DiskEntryImpl;

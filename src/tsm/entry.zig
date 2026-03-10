const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;

const ds = @import("../ds/ds.zig");
const Bloom = ds.bloom.Bloom;
const Hasher = ds.bloom.DefaultHashFn;
const gorilla = @import("gorilla.zig");
const types = @import("types.zig");
pub const TimestampEncoding = types.TimestampEncoding;

fn DiskEntryImpl(comptime page_size: u32, comptime ts_encoding: TimestampEncoding) type {
    return struct {
        const Self = @This();
        const MAGIC = "SLZ01";
        const VERSION_DELTA_COMPRESSED = 1;
        const VERSION_GORILLA = 2;
        pub const timestamp_encoding = ts_encoding;

        allocator: Allocator,
        file_path: []const u8,
        file_data: fs.File,
        file_index: fs.File,
        index_row: HashMap(u64),
        index_column: HashMap(u64),
        index_series: HashMap([2]u64),
        bloom: Bloom(1024, Hasher),

        metadata: Metadata,
        column_descriptors: []ColumnDescriptor,

        cached_row_offsets: []?AutoHashMap(u64, RowOffset),
        cached_page_descriptors: []?[]PageDescriptor,

        pub const Metadata = struct {
            number_rows: u64,
            number_columns: u32,
            created_at: i64,
            page_size: u32,
            /// helps with versioning and compatibility
            version: u32,
            min_timestamp: i64,
            max_timestamp: i64,
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

        const Value = types.Value;

        pub fn flush(allocator: Allocator, cache: anytype, file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(entry.file_path);

            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.dat", .{ level, file_path });
            errdefer allocator.free(path_data);
            entry.file_data = try fs.cwd().createFile(path_data, .{ .read = true });

            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx", .{ level, file_path });
            errdefer allocator.free(path_index);
            entry.file_index = try fs.cwd().createFile(path_index, .{ .read = true });

            entry.index_row = HashMap(u64).init(allocator);
            entry.index_column = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();

            var total_rows: u64 = 0;
            var min_ts: i64 = std.math.maxInt(i64);
            var max_ts: i64 = std.math.minInt(i64);
            var series_iter = cache.index_series.iterator();
            while (series_iter.next()) |series| {
                var node_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                while (node_iter) |node| : (node_iter = node.next()) {
                    if (node.key < min_ts) min_ts = node.key;
                    if (node.key > max_ts) max_ts = node.key;
                    total_rows += 1;
                }
            }

            entry.metadata = Metadata{
                .number_rows = total_rows,
                .number_columns = 2, // time and value only (series_key is in index)
                .created_at = std.time.timestamp(),
                .page_size = page_size,
                .version = if (ts_encoding == .gorilla) VERSION_GORILLA else VERSION_DELTA_COMPRESSED,
                .min_timestamp = min_ts,
                .max_timestamp = max_ts,
            };

            entry.column_descriptors = try allocator.alloc(ColumnDescriptor, 2);
            entry.cached_row_offsets = try allocator.alloc(?AutoHashMap(u64, RowOffset), 2);
            @memset(entry.cached_row_offsets, null);
            entry.cached_page_descriptors = try allocator.alloc(?[]PageDescriptor, 2);
            @memset(entry.cached_page_descriptors, null);

            var buffer_index: [8192]u8 = undefined;
            var writer_index = entry.file_index.writer(&buffer_index);
            var pos_index: u64 = 0;
            var pos_data: u64 = 0;
            var buffer_data: [8192]u8 = undefined;
            var writer_data = entry.file_data.writer(&buffer_data);

            const column_names = [_][]const u8{ "time", "value" };

            for (column_names, 0..) |col_name, column_id| {
                const data_start = pos_data;
                const offset_index_page = pos_index;
                const num_series = cache.index_series.count();
                try writer_index.interface.writeInt(u32, @intCast(num_series), .little);
                try entry.index_column.put(try allocator.dupe(u8, col_name), @intCast(column_id));
                pos_index += @sizeOf(u32);

                const page_desc_start = pos_index;
                pos_index += num_series * (@sizeOf(u64) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64));

                const offset_offsets_row = pos_index;
                if (ts_encoding == .delta) {
                    try writer_index.interface.writeInt(u64, total_rows, .little);
                    pos_index += @sizeOf(u64);
                } else {
                    try writer_index.interface.writeInt(u64, 0, .little); // 0 = no row offsets
                    pos_index += @sizeOf(u64);
                }

                var page_descriptors = try allocator.alloc(PageDescriptor, num_series);
                defer allocator.free(page_descriptors);

                var row_id: u64 = 0;
                var page_id: u64 = 0;
                var serialize_buf: [page_size]u8 = undefined;

                series_iter = cache.index_series.iterator();
                while (series_iter.next()) |series| {
                    const page_start_row = row_id;
                    const page_data_start = pos_data;
                    var page_data_size: u32 = 0;

                    if (column_id == 0) {
                        if (ts_encoding == .gorilla) {
                            var node_count: usize = 0;
                            var count_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                            while (count_iter) |node| : (count_iter = node.next()) {
                                node_count += 1;
                            }

                            const buffer_size = @max(page_size, node_count * 9 + 16);
                            const gorilla_buf = try allocator.alloc(u8, buffer_size);
                            defer allocator.free(gorilla_buf);

                            var ts_encoder = gorilla.TimestampEncoder.init();
                            var bit_writer = gorilla.BitWriter.init(gorilla_buf);

                            var node_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                            while (node_iter) |node| : (node_iter = node.next()) {
                                ts_encoder.encode(&bit_writer, node.key);
                                row_id += 1;
                            }

                            const encoded_data = bit_writer.getWrittenData();
                            try writer_data.interface.writeAll(encoded_data);
                            page_data_size = @intCast(encoded_data.len);
                        } else {
                            var prev_timestamp: i64 = 0;
                            var is_first_in_series = true;

                            var node_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                            while (node_iter) |node| : (node_iter = node.next()) {
                                var serialized_len: usize = 0;

                                if (is_first_in_series) {
                                    serialize_buf[0] = 0xFF;
                                    std.mem.writeInt(i64, serialize_buf[1..9], node.key, .little);
                                    serialized_len = 9;
                                    is_first_in_series = false;
                                } else {
                                    const delta = node.key - prev_timestamp;
                                    serialized_len = writeZigzagVarint(delta, &serialize_buf);
                                }
                                prev_timestamp = node.key;
                                try writer_data.interface.writeAll(serialize_buf[0..serialized_len]);
                                page_data_size += @intCast(serialized_len);
                                row_id += 1;
                            }
                        }
                    } else if (column_id == 1) {
                        var node_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                        while (node_iter) |node| : (node_iter = node.next()) {
                            const serialized = serializeValueStatic(node.value, &serialize_buf);
                            try writer_data.interface.writeAll(serialized);
                            page_data_size += @intCast(serialized.len);
                            row_id += 1;
                        }
                    }

                    pos_data += page_data_size;

                    page_descriptors[page_id] = PageDescriptor{
                        .data_offset = page_data_start,
                        .data_size = page_data_size,
                        .start_row = page_start_row,
                        .end_row = row_id - 1,
                    };

                    if (column_id == 0) {
                        const owned_key = try allocator.dupe(u8, series.key_ptr.*);
                        try entry.index_series.put(owned_key, .{ page_start_row, row_id - 1 });
                        entry.bloom.insert(series.key_ptr.*);
                    }

                    page_id += 1;
                }

                try writer_index.interface.flush();
                try writer_index.seekTo(page_desc_start);
                for (page_descriptors) |pd| {
                    try writer_index.interface.writeInt(u64, pd.data_offset, .little);
                    try writer_index.interface.writeInt(u32, pd.data_size, .little);
                    try writer_index.interface.writeInt(u64, pd.start_row, .little);
                    try writer_index.interface.writeInt(u64, pd.end_row, .little);
                }

                try writer_index.interface.flush();
                try writer_index.seekTo(pos_index);

                entry.column_descriptors[column_id] = ColumnDescriptor{
                    .name = try allocator.dupe(u8, col_name),
                    .data_offset = data_start,
                    .data_size = pos_data - data_start,
                    .num_pages = @intCast(num_series),
                    .offset_index_page = offset_index_page,
                    .offset_offsets_row = offset_offsets_row,
                };
            }

            try writer_data.interface.flush();

            const offset_bloom = pos_index;
            pos_index = try entry.writeBloomFilter(&writer_index, &pos_index, &entry.bloom);

            const offset_index_row = pos_index;
            pos_index = try entry.writeRowIndex(&writer_index, &pos_index, &entry.index_row);

            const offset_index_series = pos_index;
            pos_index = try entry.writeSeriesIndex(&writer_index, &pos_index, &entry.index_series);

            _ = try entry.writeFooter(&writer_index, &pos_index, offset_bloom, offset_index_row, offset_index_series);

            try writer_index.interface.flush();

            entry.file_data.close();
            entry.file_index.close();
            entry.file_data = try fs.cwd().openFile(path_data, .{});
            entry.file_index = try fs.cwd().openFile(path_index, .{});

            allocator.free(path_data);
            allocator.free(path_index);

            return entry;
        }

        fn writeZigzagVarint(value: i64, buf: []u8) usize {
            const zigzag: u64 = @bitCast((value << 1) ^ (value >> 63));
            return writeVarint(zigzag, buf);
        }

        fn writeVarint(value: u64, buf: []u8) usize {
            var v = value;
            var i: usize = 0;
            while (v >= 0x80) : (i += 1) {
                buf[i] = @intCast((v & 0x7F) | 0x80);
                v >>= 7;
            }
            buf[i] = @intCast(v);
            return i + 1;
        }

        fn readZigzagVarint(data: []const u8) struct { value: i64, len: usize } {
            const result = readVarint(data);
            const decoded: i64 = @bitCast((result.value >> 1) ^ (0 -% (result.value & 1)));
            return .{ .value = decoded, .len = result.len };
        }

        fn readVarint(data: []const u8) struct { value: u64, len: usize } {
            var result: u64 = 0;
            var shift: u6 = 0;
            var i: usize = 0;
            while (i < data.len) : (i += 1) {
                const byte = data[i];
                result |= @as(u64, byte & 0x7F) << shift;
                if (byte & 0x80 == 0) {
                    return .{ .value = result, .len = i + 1 };
                }
                shift += 7;
            }
            return .{ .value = result, .len = i };
        }

        fn serializeValueStatic(value: Value, buf: []u8) []u8 {
            buf[0] = @intFromEnum(value);

            switch (value) {
                .Bool => |v| {
                    buf[1] = @intFromBool(v);
                    return buf[0..2];
                },
                .Int => |v| {
                    std.mem.writeInt(i64, buf[1..9], v, .little);
                    return buf[0..9];
                },
                .Float => |v| {
                    @memcpy(buf[1..9], std.mem.asBytes(&v));
                    return buf[0..9];
                },
                .Bytes => |v| {
                    std.mem.writeInt(u32, buf[1..5], @intCast(v.len), .little);
                    @memcpy(buf[5..][0..v.len], v);
                    return buf[0 .. 5 + v.len];
                },
            }
        }

        pub fn deinit(self: *Self) void {
            self.file_data.close();
            self.file_index.close();
            self.allocator.free(self.file_path);
            self.index_row.deinit();
            var column_key_iter = self.index_column.iterator();
            while (column_key_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.index_column.deinit();

            var series_key_iter = self.index_series.iterator();
            while (series_key_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.index_series.deinit();
            self.bloom.deinit();
            for (self.column_descriptors) |column_descriptor| {
                self.allocator.free(column_descriptor.name);
            }
            self.allocator.free(self.column_descriptors);

            for (self.cached_row_offsets) |*cached| {
                if (cached.*) |*map| {
                    map.deinit();
                }
            }
            self.allocator.free(self.cached_row_offsets);

            for (self.cached_page_descriptors) |cached| {
                if (cached) |descs| {
                    self.allocator.free(descs);
                }
            }
            self.allocator.free(self.cached_page_descriptors);

            self.allocator.destroy(self);
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
            try writer_index.interface.writeInt(i64, self.metadata.min_timestamp, .little);
            try writer_index.interface.writeInt(i64, self.metadata.max_timestamp, .little);
            pos_index.* += @sizeOf(u64) + @sizeOf(u32) + @sizeOf(i64) + @sizeOf(u32) + @sizeOf(u32) + @sizeOf(i64) * 2;

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
            entry.index_column = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();
            entry.cached_row_offsets = &.{};
            entry.cached_page_descriptors = &.{};

            try entry.readFooter();

            entry.cached_row_offsets = try allocator.alloc(?AutoHashMap(u64, RowOffset), entry.metadata.number_columns);
            @memset(entry.cached_row_offsets, null);
            entry.cached_page_descriptors = try allocator.alloc(?[]PageDescriptor, entry.metadata.number_columns);
            @memset(entry.cached_page_descriptors, null);

            return entry;
        }

        pub fn mayContainSeries(self: *Self, series_key: []const u8) bool {
            return self.bloom.contains(series_key);
        }

        pub fn getColumn(self: *Self, column_name: []const u8) ![]Value {
            const column_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
            return self.getColumnById(column_id);
        }

        pub fn getColumnRange(self: *Self, column_name: []const u8, start_row: u64, end_row: u64) ![]Value {
            const column_id = self.index_column.get(column_name) orelse return error.ColumnNotFound;
            return self.getColumnRangeById(@intCast(column_id), start_row, end_row);
        }

        pub fn getColumnById(self: *Self, column_id: u64) ![]Value {
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

        pub fn getColumnRangeById(self: *Self, column_id: usize, start_row: u64, end_row: u64) ![]Value {
            if (column_id >= self.column_descriptors.len) return error.InvalidColumnId;
            if (end_row >= self.metadata.number_rows) return error.InvalidRange;
            if (start_row > end_row) return error.InvalidRange;

            var buffer_data: [8192]u8 = undefined;
            var reader_data = self.file_data.reader(&buffer_data);

            const is_sequential = self.metadata.version == VERSION_GORILLA or self.metadata.version == VERSION_DELTA_COMPRESSED;
            var empty_row_offsets = AutoHashMap(u64, RowOffset).init(self.allocator);
            defer if (is_sequential) empty_row_offsets.deinit();
            const row_offsets = if (is_sequential) &empty_row_offsets else try self.getOrLoadRowOffsets(column_id);

            const page_descriptors = try self.getOrLoadPageDescriptors(column_id);

            var values = try self.allocator.alloc(Value, @intCast(end_row - start_row + 1));
            var index_values: usize = 0;

            const is_time_column_delta = column_id == 0 and self.metadata.version == VERSION_DELTA_COMPRESSED;
            const is_time_column_gorilla = column_id == 0 and self.metadata.version == VERSION_GORILLA;

            for (page_descriptors, 0..) |page_desc, page_id| {
                if (page_desc.end_row < start_row or page_desc.start_row > end_row) {
                    continue;
                }

                try reader_data.seekTo(page_desc.data_offset);
                var page_data = try self.allocator.alloc(u8, page_desc.data_size);
                defer self.allocator.free(page_data);
                _ = try reader_data.interface.readSliceAll(page_data);

                const is_value_column = column_id == 1 and (self.metadata.version == VERSION_GORILLA or self.metadata.version == VERSION_DELTA_COMPRESSED);

                if (is_time_column_gorilla) {
                    const row_count = page_desc.end_row - page_desc.start_row + 1;
                    const timestamps = try decodeGorillaTimestamps(self.allocator, page_data, @intCast(row_count));
                    defer self.allocator.free(timestamps);

                    for (timestamps, 0..) |ts, i| {
                        const current_row = page_desc.start_row + i;
                        if (current_row >= start_row and current_row <= end_row) {
                            values[index_values] = Value{ .Int = ts };
                            index_values += 1;
                        }
                    }
                } else if (is_time_column_delta) {
                    var prev_timestamp: i64 = 0;
                    var data_offset: usize = 0;
                    var current_row = page_desc.start_row;

                    while (current_row <= page_desc.end_row and data_offset < page_data.len) {
                        const result = deserializeTimestamp(page_data[data_offset..], prev_timestamp);
                        prev_timestamp = result.value;

                        if (current_row >= start_row and current_row <= end_row) {
                            values[index_values] = Value{ .Int = result.value };
                            index_values += 1;
                        }

                        data_offset += result.len;
                        current_row += 1;
                    }
                } else if (is_value_column) {
                    var data_offset: usize = 0;
                    var current_row = page_desc.start_row;

                    while (current_row <= page_desc.end_row and data_offset < page_data.len) {
                        const tag = page_data[data_offset];
                        var value_len: usize = 1;

                        const value: Value = switch (@as(std.meta.Tag(Value), @enumFromInt(tag))) {
                            .Bool => blk: {
                                value_len = 2;
                                break :blk Value{ .Bool = page_data[data_offset + 1] != 0 };
                            },
                            .Int => blk: {
                                value_len = 9;
                                break :blk Value{ .Int = std.mem.readInt(i64, page_data[data_offset + 1 ..][0..8], .little) };
                            },
                            .Float => blk: {
                                value_len = 9;
                                var val: f64 = undefined;
                                @memcpy(std.mem.asBytes(&val), page_data[data_offset + 1 ..][0..8]);
                                break :blk Value{ .Float = val };
                            },
                            .Bytes => blk: {
                                const str_len = std.mem.readInt(u32, page_data[data_offset + 1 ..][0..4], .little);
                                value_len = 5 + str_len;
                                const bytes = try self.allocator.dupe(u8, page_data[data_offset + 5 ..][0..str_len]);
                                break :blk Value{ .Bytes = bytes };
                            },
                        };

                        if (current_row >= start_row and current_row <= end_row) {
                            values[index_values] = value;
                            index_values += 1;
                        }

                        data_offset += value_len;
                        current_row += 1;
                    }
                } else {
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
            }

            return values;
        }

        fn getOrLoadRowOffsets(self: *Self, column_id: u64) !*AutoHashMap(u64, RowOffset) {
            if (self.cached_row_offsets[column_id]) |*cached| {
                return cached;
            }

            var row_offsets = AutoHashMap(u64, RowOffset).init(self.allocator);
            try self.loadRowOffsets(column_id, &row_offsets);
            self.cached_row_offsets[column_id] = row_offsets;
            return &self.cached_row_offsets[column_id].?;
        }

        fn getOrLoadPageDescriptors(self: *Self, column_id: u64) ![]PageDescriptor {
            if (self.cached_page_descriptors[column_id]) |cached| {
                return cached;
            }

            var buffer_index: [8192]u8 = undefined;
            var reader_index = self.file_index.reader(&buffer_index);

            const descriptor = &self.column_descriptors[column_id];
            try reader_index.seekTo(descriptor.offset_index_page);
            const num_pages = try reader_index.interface.takeInt(u32, .little);

            const page_descriptors = try self.allocator.alloc(PageDescriptor, num_pages);

            for (page_descriptors) |*page_desc| {
                page_desc.* = PageDescriptor{
                    .data_offset = try reader_index.interface.takeInt(u64, .little),
                    .data_size = try reader_index.interface.takeInt(u32, .little),
                    .start_row = try reader_index.interface.takeInt(u64, .little),
                    .end_row = try reader_index.interface.takeInt(u64, .little),
                };
            }

            self.cached_page_descriptors[column_id] = page_descriptors;
            return page_descriptors;
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
            _ = len;
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
                    const str_len = std.mem.readInt(u32, data[1..5], .little);
                    // Must copy bytes since page_data gets freed after this
                    const bytes = try self.allocator.dupe(u8, data[5..][0..str_len]);
                    break :blk Value{ .Bytes = bytes };
                },
            };
        }

        fn deserializeTimestamp(data: []const u8, prev_timestamp: i64) struct { value: i64, len: usize } {
            if (data[0] == 0xFF) {
                const ts = std.mem.readInt(i64, data[1..9], .little);
                return .{ .value = ts, .len = 9 };
            } else {
                const result = readZigzagVarint(data);
                return .{ .value = prev_timestamp + result.value, .len = result.len };
            }
        }

        fn decodeGorillaTimestamps(allocator: Allocator, data: []const u8, count: usize) ![]i64 {
            var timestamps = try allocator.alloc(i64, count);
            errdefer allocator.free(timestamps);

            var reader = gorilla.BitReader.init(data);
            var decoder = gorilla.TimestampDecoder.init();

            for (0..count) |i| {
                timestamps[i] = decoder.decode(&reader) orelse return error.CorruptedData;
            }

            return timestamps;
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
                .min_timestamp = try reader_index.interface.takeInt(i64, .little),
                .max_timestamp = try reader_index.interface.takeInt(i64, .little),
            };

            self.column_descriptors = try self.allocator.alloc(ColumnDescriptor, self.metadata.number_columns);

            for (self.column_descriptors, 0..) |*desc, desc_id| {
                const name_len = try reader_index.interface.takeInt(u32, .little);
                const name = try self.allocator.alloc(u8, name_len);
                _ = try reader_index.interface.readSliceAll(name);

                try self.index_column.put(name, @intCast(desc_id));

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
                errdefer self.allocator.free(key);
                _ = try reader_index.interface.readSliceAll(key);

                var range: [2]u64 = undefined;
                _ = try reader_index.interface.readSliceAll(std.mem.asBytes(&range));

                try self.index_series.put(key, range);
            }
        }
    };
}

pub const DiskEntry = DiskEntryImpl;

test {
    _ = gorilla;
}

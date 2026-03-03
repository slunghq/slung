const std = @import("std");
const fs = std.fs;
const ds = @import("../ds/ds.zig");
const csv = @import("../csv.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;
const Bloom = ds.bloom.Bloom;
const Hasher = ds.bloom.DefaultHashFn;
const types = @import("types.zig");

pub const TimestampEncoding = types.TimestampEncoding;

pub fn DiskEntryImpl(comptime page_size: u32, comptime ts_encoding: TimestampEncoding) type {
    return struct {
        const Self = @This();

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

        const Value = types.Value;

        pub const Metadata = struct {
            number_rows: u64,
            number_columns: u32,
            created_at: i64,
            page_size: u32,
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

        pub fn flush(allocator: Allocator, cache: anytype, file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            errdefer allocator.destroy(entry);

            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(entry.file_path);

            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.csv", .{ level, file_path });
            defer allocator.free(path_data);
            entry.file_data = try fs.cwd().createFile(path_data, .{ .read = true });
            errdefer entry.file_data.close();

            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx.csv", .{ level, file_path });
            defer allocator.free(path_index);
            entry.file_index = try fs.cwd().createFile(path_index, .{ .read = true });
            errdefer entry.file_index.close();

            entry.index_row = HashMap(u64).init(allocator);
            entry.index_column = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();

            entry.column_descriptors = try allocator.alloc(ColumnDescriptor, 2);
            errdefer allocator.free(entry.column_descriptors);
            entry.column_descriptors[0] = .{ .name = try allocator.dupe(u8, "time"), .data_offset = 0, .data_size = 0, .num_pages = 0, .offset_index_page = 0, .offset_offsets_row = 0 };
            entry.column_descriptors[1] = .{ .name = try allocator.dupe(u8, "value"), .data_offset = 0, .data_size = 0, .num_pages = 0, .offset_index_page = 0, .offset_offsets_row = 0 };
            errdefer {
                allocator.free(entry.column_descriptors[0].name);
                allocator.free(entry.column_descriptors[1].name);
            }

            try entry.index_column.put(try allocator.dupe(u8, "time"), 0);
            try entry.index_column.put(try allocator.dupe(u8, "value"), 1);

            entry.cached_row_offsets = try allocator.alloc(?AutoHashMap(u64, RowOffset), 2);
            @memset(entry.cached_row_offsets, null);
            entry.cached_page_descriptors = try allocator.alloc(?[]PageDescriptor, 2);
            @memset(entry.cached_page_descriptors, null);

            var total_rows: u64 = 0;
            var min_ts: i64 = std.math.maxInt(i64);
            var max_ts: i64 = std.math.minInt(i64);

            var data_writer = csv.CsvWriter.init(entry.file_data);
            try data_writer.writeRecord(&[_][]const u8{ "row_id", "series_key", "timestamp", "value_type", "value_data" });

            var series_iter = cache.index_series.iterator();
            while (series_iter.next()) |series| {
                const series_start = total_rows;
                var node_iter: ?*@TypeOf(series.value_ptr.*).Node = series.value_ptr.head.next();
                while (node_iter) |node| : (node_iter = node.next()) {
                    const row_id_s = try std.fmt.allocPrint(allocator, "{d}", .{total_rows});
                    defer allocator.free(row_id_s);

                    const ts_s = try std.fmt.allocPrint(allocator, "{d}", .{node.key});
                    defer allocator.free(ts_s);

                    const value_type_s = valueTypeTag(node.value);
                    const value_data_s = try valueDataToString(allocator, node.value);
                    defer allocator.free(value_data_s);

                    try data_writer.writeRecord(&[_][]const u8{ row_id_s, series.key_ptr.*, ts_s, value_type_s, value_data_s });

                    if (node.key < min_ts) min_ts = node.key;
                    if (node.key > max_ts) max_ts = node.key;
                    total_rows += 1;
                }

                if (total_rows > series_start) {
                    const owned_key = try allocator.dupe(u8, series.key_ptr.*);
                    try entry.index_series.put(owned_key, .{ series_start, total_rows - 1 });
                    entry.bloom.insert(series.key_ptr.*);
                }
            }
            try data_writer.flush();

            if (total_rows == 0) {
                min_ts = 0;
                max_ts = 0;
            }

            entry.metadata = .{
                .number_rows = total_rows,
                .number_columns = 2,
                .created_at = std.time.timestamp(),
                .page_size = page_size,
                .version = 1,
                .min_timestamp = min_ts,
                .max_timestamp = max_ts,
            };

            var index_writer = csv.CsvWriter.init(entry.file_index);
            try index_writer.writeRecord(&[_][]const u8{ "kind", "k1", "k2", "k3" });

            try writeMetaRecord(allocator, &index_writer, "number_rows", entry.metadata.number_rows);
            try writeMetaRecord(allocator, &index_writer, "number_columns", entry.metadata.number_columns);
            try writeMetaRecord(allocator, &index_writer, "created_at", entry.metadata.created_at);
            try writeMetaRecord(allocator, &index_writer, "page_size", entry.metadata.page_size);
            try writeMetaRecord(allocator, &index_writer, "version", entry.metadata.version);
            try writeMetaRecord(allocator, &index_writer, "min_timestamp", entry.metadata.min_timestamp);
            try writeMetaRecord(allocator, &index_writer, "max_timestamp", entry.metadata.max_timestamp);

            try index_writer.writeRecord(&[_][]const u8{ "column", "0", "time", "" });
            try index_writer.writeRecord(&[_][]const u8{ "column", "1", "value", "" });

            var idx_series_iter = entry.index_series.iterator();
            while (idx_series_iter.next()) |kv| {
                const start_s = try std.fmt.allocPrint(allocator, "{d}", .{kv.value_ptr.*[0]});
                defer allocator.free(start_s);
                const end_s = try std.fmt.allocPrint(allocator, "{d}", .{kv.value_ptr.*[1]});
                defer allocator.free(end_s);
                try index_writer.writeRecord(&[_][]const u8{ "series", kv.key_ptr.*, start_s, end_s });
            }

            try index_writer.flush();

            entry.file_data.close();
            entry.file_index.close();
            entry.file_data = try fs.cwd().openFile(path_data, .{});
            entry.file_index = try fs.cwd().openFile(path_index, .{});

            return entry;
        }

        pub fn open(allocator: Allocator, file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            errdefer allocator.destroy(entry);

            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(entry.file_path);

            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.csv", .{ level, file_path });
            defer allocator.free(path_data);
            entry.file_data = try fs.cwd().openFile(path_data, .{});
            errdefer entry.file_data.close();

            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx.csv", .{ level, file_path });
            defer allocator.free(path_index);
            entry.file_index = try fs.cwd().openFile(path_index, .{});
            errdefer entry.file_index.close();

            entry.index_row = HashMap(u64).init(allocator);
            entry.index_column = HashMap(u64).init(allocator);
            entry.index_series = HashMap([2]u64).init(allocator);
            entry.bloom = Bloom(1024, Hasher).init();

            entry.column_descriptors = try allocator.alloc(ColumnDescriptor, 2);
            errdefer allocator.free(entry.column_descriptors);
            entry.column_descriptors[0] = .{ .name = try allocator.dupe(u8, "time"), .data_offset = 0, .data_size = 0, .num_pages = 0, .offset_index_page = 0, .offset_offsets_row = 0 };
            entry.column_descriptors[1] = .{ .name = try allocator.dupe(u8, "value"), .data_offset = 0, .data_size = 0, .num_pages = 0, .offset_index_page = 0, .offset_offsets_row = 0 };
            errdefer {
                allocator.free(entry.column_descriptors[0].name);
                allocator.free(entry.column_descriptors[1].name);
            }

            try entry.index_column.put(try allocator.dupe(u8, "time"), 0);
            try entry.index_column.put(try allocator.dupe(u8, "value"), 1);

            entry.cached_row_offsets = try allocator.alloc(?AutoHashMap(u64, RowOffset), 2);
            @memset(entry.cached_row_offsets, null);
            entry.cached_page_descriptors = try allocator.alloc(?[]PageDescriptor, 2);
            @memset(entry.cached_page_descriptors, null);

            entry.metadata = .{
                .number_rows = 0,
                .number_columns = 2,
                .created_at = 0,
                .page_size = page_size,
                .version = 1,
                .min_timestamp = 0,
                .max_timestamp = 0,
            };

            try entry.loadIndexFromCsv();
            return entry;
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
            if (self.metadata.number_rows == 0) {
                return self.allocator.alloc(Value, 0);
            }
            return self.getColumnRangeById(@intCast(column_id), 0, self.metadata.number_rows - 1);
        }

        pub fn getColumnRangeById(self: *Self, column_id: usize, start_row: u64, end_row: u64) ![]Value {
            if (column_id >= self.column_descriptors.len) return error.InvalidColumnId;
            if (start_row > end_row) return error.InvalidRange;
            if (self.metadata.number_rows == 0) return self.allocator.alloc(Value, 0);
            if (end_row >= self.metadata.number_rows) return error.InvalidRange;

            try self.file_data.seekTo(0);
            var reader = csv.CsvReader.init(self.allocator, self.file_data);

            const header = (try reader.readRecord()) orelse return error.InvalidFileFormat;
            reader.freeRecord(header);

            var values: std.ArrayList(Value) = .empty;
            defer values.deinit(self.allocator);

            while (try reader.readRecord()) |record| {
                defer reader.freeRecord(record);
                if (record.len < 5) continue;

                const row_id = std.fmt.parseInt(u64, record[0], 10) catch continue;
                if (row_id < start_row or row_id > end_row) continue;

                if (column_id == 0) {
                    const ts = std.fmt.parseInt(i64, record[2], 10) catch continue;
                    try values.append(self.allocator, Value{ .Int = ts });
                } else if (column_id == 1) {
                    const v = try parseValueFromStrings(self.allocator, record[3], record[4]);
                    try values.append(self.allocator, v);
                } else {
                    return error.InvalidColumnId;
                }
            }

            return values.toOwnedSlice(self.allocator);
        }

        fn loadIndexFromCsv(self: *Self) !void {
            try self.file_index.seekTo(0);
            var reader = csv.CsvReader.init(self.allocator, self.file_index);

            const header = (try reader.readRecord()) orelse return;
            reader.freeRecord(header);

            while (try reader.readRecord()) |record| {
                defer reader.freeRecord(record);
                if (record.len < 4) continue;

                if (std.mem.eql(u8, record[0], "meta")) {
                    if (std.mem.eql(u8, record[1], "number_rows")) self.metadata.number_rows = std.fmt.parseInt(u64, record[2], 10) catch self.metadata.number_rows;
                    if (std.mem.eql(u8, record[1], "number_columns")) self.metadata.number_columns = std.fmt.parseInt(u32, record[2], 10) catch self.metadata.number_columns;
                    if (std.mem.eql(u8, record[1], "created_at")) self.metadata.created_at = std.fmt.parseInt(i64, record[2], 10) catch self.metadata.created_at;
                    if (std.mem.eql(u8, record[1], "page_size")) self.metadata.page_size = std.fmt.parseInt(u32, record[2], 10) catch self.metadata.page_size;
                    if (std.mem.eql(u8, record[1], "version")) self.metadata.version = std.fmt.parseInt(u32, record[2], 10) catch self.metadata.version;
                    if (std.mem.eql(u8, record[1], "min_timestamp")) self.metadata.min_timestamp = std.fmt.parseInt(i64, record[2], 10) catch self.metadata.min_timestamp;
                    if (std.mem.eql(u8, record[1], "max_timestamp")) self.metadata.max_timestamp = std.fmt.parseInt(i64, record[2], 10) catch self.metadata.max_timestamp;
                } else if (std.mem.eql(u8, record[0], "series")) {
                    const start_row = std.fmt.parseInt(u64, record[2], 10) catch continue;
                    const end_row = std.fmt.parseInt(u64, record[3], 10) catch continue;
                    const key = try self.allocator.dupe(u8, record[1]);
                    try self.index_series.put(key, .{ start_row, end_row });
                    self.bloom.insert(record[1]);
                }
            }
        }

        fn writeMetaRecord(allocator: Allocator, writer: *csv.CsvWriter, key: []const u8, value: anytype) !void {
            const v = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(v);
            try writer.writeRecord(&[_][]const u8{ "meta", key, v, "" });
        }

        fn valueTypeTag(value: Value) []const u8 {
            return switch (value) {
                .Bool => "bool",
                .Int => "int",
                .Float => "float",
                .Bytes => "bytes",
            };
        }

        fn valueDataToString(allocator: Allocator, value: Value) ![]u8 {
            return switch (value) {
                .Bool => |v| allocator.dupe(u8, if (v) "1" else "0"),
                .Int => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
                .Float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
                .Bytes => |v| encodeHexLower(allocator, v),
            };
        }

        fn parseValueFromStrings(allocator: Allocator, type_s: []const u8, data_s: []const u8) !Value {
            if (std.mem.eql(u8, type_s, "bool")) {
                const bool_v = std.mem.eql(u8, data_s, "1") or std.ascii.eqlIgnoreCase(data_s, "true");
                return Value{ .Bool = bool_v };
            }
            if (std.mem.eql(u8, type_s, "int")) {
                const int_v = try std.fmt.parseInt(i64, data_s, 10);
                return Value{ .Int = int_v };
            }
            if (std.mem.eql(u8, type_s, "float")) {
                const float_v = try std.fmt.parseFloat(f64, data_s);
                return Value{ .Float = float_v };
            }
            if (std.mem.eql(u8, type_s, "bytes")) {
                const bytes = try parseHexBytes(allocator, data_s);
                return Value{ .Bytes = bytes };
            }
            return error.InvalidValueType;
        }

        fn parseHexBytes(allocator: Allocator, hex: []const u8) ![]u8 {
            if (hex.len % 2 != 0) return error.InvalidHexLength;

            var out = try allocator.alloc(u8, hex.len / 2);
            errdefer allocator.free(out);

            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
            }

            return out;
        }

        fn encodeHexLower(allocator: Allocator, bytes: []const u8) ![]u8 {
            const table = "0123456789abcdef";
            var out = try allocator.alloc(u8, bytes.len * 2);
            errdefer allocator.free(out);

            for (bytes, 0..) |b, i| {
                out[i * 2] = table[b >> 4];
                out[i * 2 + 1] = table[b & 0x0F];
            }

            return out;
        }
    };
}

pub const DiskEntry = DiskEntryImpl;

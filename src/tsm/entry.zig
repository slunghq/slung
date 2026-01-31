//! Disk entry
//!
//! Used for flushing and querying the columnar table to and from disk
//!

const std = @import("std");
const fs = std.fs;
const ds = @import("../ds/ds.zig");
const Allocator = std.mem.Allocator;
const HashMap = std.StringHashMap;
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

        pub fn flush(allocator: Allocator, table: *ColumnTable(page_size), file_path: []const u8, level: usize) !*Self {
            var entry = try allocator.create(Self);
            entry.allocator = allocator;
            entry.file_path = try allocator.dupe(u8, file_path);

            // start time vs end time
            const path_data = try std.fmt.allocPrint(allocator, "_{d}_{s}.dat", .{ level, file_path });
            defer allocator.free(path_data);
            entry.file_data = try fs.cwd().createFile(path_data, .{});
            const path_index = try std.fmt.allocPrint(allocator, "_{d}_{s}.idx", .{ level, file_path });
            defer allocator.free(path_index);
            entry.file_index = try fs.cwd().createFile(path_index, .{});
            entry.index_row = HashMap(u64).init(allocator);
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

            for (table.columns, 0..) |*column, column_id| {
                try entry.writeColumn(column, column_id);
            }

            const bloom_offset = try entry.file_index.getPos();
            try entry.writeBloomFilter(&table.bloom);

            const row_index_offset = try entry.file_index.getPos();
            try entry.writeRowIndex(&table.index_row);

            try entry.writeFooter(bloom_offset, row_index_offset);

            return entry;
        }

        pub fn deinit(self: *Self) void {
            self.file_data.close();
            self.file_index.close();
            self.allocator.free(self.file_path);
            self.index_row.deinit();
            for (self.column_descriptors) |column_descriptor| {
                self.allocator.free(column_descriptor.name);
            }
            self.allocator.free(self.column_descriptors);
            self.allocator.destroy(self);
        }

        fn writeColumn(self: *Self, column: *ColumnTable(page_size).Column, column_id: usize) !void {
            const data_start = try self.file_data.getPos();
            var total_data_size: u64 = 0;
            var buffer_index: [8192]u8 = undefined;
            var writer_index = self.file_index.writer(&buffer_index);
            var buffer_data: [8192]u8 = undefined;
            var writer_data = self.file_data.writer(&buffer_data);

            const offset_index_page = try self.file_index.getPos();
            try writer_index.interface.writeInt(u32, @intCast(column.pages.items.len), .little);

            for (column.pages.items, 0..) |page, page_id| {
                const page_offset = try self.file_data.getPos();
                const actual_size = if (page_id == column.pages.items.len - 1) column.current_offset else page_size;
                total_data_size += actual_size;

                try writer_data.interface.writeAll(&page.data);

                try writer_index.interface.writeInt(u64, page_offset, .little);
                try writer_index.interface.writeInt(u32, actual_size, .little);
                try writer_index.interface.writeInt(u64, page.start, .little);
                try writer_index.interface.writeInt(u64, page.end, .little);
            }

            try writer_index.interface.writeInt(u64, column.row_offsets.count(), .little);

            var iter = column.row_offsets.iterator();
            while (iter.next()) |entry| {
                try writer_index.interface.writeInt(u64, entry.key_ptr.*, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.row_id, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.page_id, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.offset, .little);
                try writer_index.interface.writeInt(u64, entry.value_ptr.len, .little);
            }

            const offset_offsets_row = try self.file_index.getPos();
            self.column_descriptors[column_id] = ColumnDescriptor{
                .name = try self.allocator.dupe(u8, column.name),
                .data_offset = data_start,
                .data_size = total_data_size,
                .num_pages = @intCast(column.pages.items.len),
                .offset_index_page = offset_index_page,
                .offset_offsets_row = offset_offsets_row,
            };

            try writer_index.interface.flush();
            try writer_data.interface.flush();
        }

        fn writeBloomFilter(self: *Self, bloom: *Bloom(1024, Hasher)) !void {
            var buffer: [8192]u8 = undefined;
            var writer_index = self.file_index.writer(&buffer);

            try writer_index.interface.writeInt(u64, bloom.len(), .little);
            try writer_index.interface.writeAll(&bloom.mask.bits);

            try writer_index.interface.flush();
        }

        fn writeRowIndex(self: *Self, index: *const HashMap(u64)) !void {
            var buffer: [8192]u8 = undefined;
            var writer_index = self.file_index.writer(&buffer);

            try writer_index.interface.writeInt(u64, @intCast(index.count()), .little);

            var iter = index.iterator();
            while (iter.next()) |entry| {
                const key_len: u32 = @intCast(entry.key_ptr.len);
                try writer_index.interface.writeInt(u32, key_len, .little);
                try writer_index.interface.writeAll(entry.key_ptr.*);
                try writer_index.interface.writeInt(u64, entry.value_ptr.*, .little);
            }

            try writer_index.interface.flush();
        }

        fn writeFooter(self: *Self, bloom_offset: u64, row_index_offset: u64) !void {
            var buffer: [8192]u8 = undefined;
            var writer_index = self.file_index.writer(&buffer);

            const footer_start = try self.file_index.getPos();

            try writer_index.interface.writeInt(u64, bloom_offset, .little);
            try writer_index.interface.writeInt(u64, row_index_offset, .little);

            try writer_index.interface.writeInt(u64, self.metadata.number_rows, .little);
            try writer_index.interface.writeInt(u32, self.metadata.number_columns, .little);
            try writer_index.interface.writeInt(i64, self.metadata.created_at, .little);
            try writer_index.interface.writeInt(u32, self.metadata.page_size, .little);
            try writer_index.interface.writeInt(u32, self.metadata.version, .little);

            for (self.column_descriptors) |desc| {
                const name_len: u32 = @intCast(desc.name.len);
                try writer_index.interface.writeInt(u32, name_len, .little);
                try writer_index.interface.writeAll(desc.name);
                try writer_index.interface.writeInt(u64, desc.data_offset, .little);
                try writer_index.interface.writeInt(u64, desc.data_size, .little);
                try writer_index.interface.writeInt(u32, desc.num_pages, .little);
                try writer_index.interface.writeInt(u64, desc.offset_index_page, .little);
                try writer_index.interface.writeInt(u64, desc.offset_offsets_row, .little);
            }

            try writer_index.interface.writeInt(u64, footer_start, .little);
            try writer_index.interface.writeAll(MAGIC);

            try writer_index.interface.flush();
        }
    };
}

pub const DiskEntry = DiskEntryImpl;


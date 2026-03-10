const std = @import("std");
const Codspeed = @import("codspeed");
const tsm = @import("src/tsm/tsm.zig");

const TsmTree = tsm.TsmTreeRuntime;

const metric_name = "bench.cpu.total.billions";
const hosts = [_][]const u8{
    "h-0", "h-1", "h-2", "h-3", "h-4",
    "h-5", "h-6", "h-7", "h-8", "h-9",
};
const points_per_host: usize = 100_000_000;
const total_points: u128 = @as(u128, hosts.len) * points_per_host;
const progress_interval: usize = 10_000_000;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var codspeed = Codspeed.init(allocator, "billions.zig");
    defer codspeed.deinit();

    try codspeed.start("billions");
    errdefer codspeed.stop("billions") catch {};
    try runBenchmark(allocator);
    try codspeed.stop("billions");
}

fn runBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("Starting billions benchmark...\n", .{});

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
        break :blk seed;
    });
    const random = prng.random();

    var max_memory_bytes: u64 = 0;

    var tree = try TsmTree.init(allocator, metric_name, .Native);
    defer tree.deinit();

    const start = std.time.nanoTimestamp();

    for (hosts, 0..) |host, hidx| {
        const series_key = try std.fmt.allocPrint(allocator, "{s},env=prod,service=db,host={s}", .{ metric_name, host });
        defer allocator.free(series_key);

        for (0..points_per_host) |idx| {
            const items_written: u128 = @as(u128, hidx) * points_per_host + idx + 1;

            const value: f64 = random.float(f64) * 100.0;
            const timestamp: i64 = @intCast(items_written);

            try tree.insert(series_key, TsmTree.DataPoint{
                .timestamp = timestamp,
                .value = .{ .Float = value },
            });

            if (idx > 0 and idx % progress_interval == 0) {
                const now = std.time.nanoTimestamp();
                const elapsed_ns: u128 = @intCast(now - start);

                const ns_per_item = if (items_written > 0) elapsed_ns / items_written else 0;
                const write_speed = if (ns_per_item > 0) 1_000_000_000 / ns_per_item else 0;

                const current_memory = getResidentMemory() catch 0;
                if (current_memory > max_memory_bytes) {
                    max_memory_bytes = current_memory;
                }

                std.debug.print("[{s}] ingested {d} - {d} WPS - peak mem: {d} MiB\n", .{
                    host,
                    idx,
                    write_speed,
                    max_memory_bytes / 1024 / 1024,
                });
            }
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u128 = @intCast(end - start);
    const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    const items_written: u128 = total_points;
    const ns_per_item = elapsed_ns / items_written;
    const write_speed = 1_000_000_000 / ns_per_item;

    const current_memory = getResidentMemory() catch 0;
    if (current_memory > max_memory_bytes) {
        max_memory_bytes = current_memory;
    }

    try tree.flush();

    std.debug.print("\n", .{});
    std.debug.print("ingested {d} points in {d:.2}s\n", .{ items_written, elapsed_secs });
    std.debug.print("write latency per item: {d}ns\n", .{ns_per_item});
    std.debug.print("write speed: {d} WPS\n", .{write_speed});
    std.debug.print("peak mem: {d} MiB\n", .{max_memory_bytes / 1024 / 1024});

    // Check file sizes
    std.debug.print("\n--- Storage ---\n", .{});
    var total_size: u64 = 0;
    {
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
            std.debug.print("  Could not open directory\n", .{});
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const name = entry.name;
                if (isBenchmarkFile(name) and
                    (std.mem.endsWith(u8, name, ".dat") or std.mem.endsWith(u8, name, ".idx")))
                {
                    const stat = try dir.statFile(name);
                    total_size += stat.size;
                }
            }
        }
    }
    std.debug.print("  Total: {d} bytes ({d:.2} GB)\n", .{ total_size, @as(f64, @floatFromInt(total_size)) / 1024.0 / 1024.0 / 1024.0 });
    std.debug.print("  Bytes per point: {d:.2}\n", .{@as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(total_points))});

    std.debug.print("\n--- Query Benchmark ---\n", .{});

    // Query 1M points from h-9 (the last host).
    const query_host = "h-9";
    const query_series_key = try std.fmt.allocPrint(allocator, "{s},env=prod,service=db,host={s}", .{ metric_name, query_host });
    defer allocator.free(query_series_key);

    const host_end: i64 = @intCast(total_points);
    const lower_bound: i64 = host_end - 1_000_000;
    const upper_bound: i64 = host_end - 1;

    std.debug.print("  Querying {s} range {d}-{d} (1M points)\n", .{ query_host, lower_bound, upper_bound });

    for (0..5) |run| {
        const query_start = std.time.nanoTimestamp();

        const result = tree.query(query_series_key, lower_bound, upper_bound, .AVG) catch |err| {
            std.debug.print("Query error: {}\n", .{err});
            continue;
        };

        const query_end = std.time.nanoTimestamp();
        const query_elapsed_ns = query_end - query_start;
        const query_elapsed_ms = @as(f64, @floatFromInt(query_elapsed_ns)) / 1_000_000.0;

        if (run == 0) {
            std.debug.print("  avg: {d:.4}\n", .{result.Float});
        }
        std.debug.print("  Run {d}: {d:.2}ms\n", .{ run + 1, query_elapsed_ms });
    }

    std.debug.print("\n--- Cleanup ---\n", .{});
    {
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
            std.debug.print("  Could not open directory for cleanup\n", .{});
            return;
        };
        defer dir.close();

        var files_deleted: u64 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const name = entry.name;
                if (isBenchmarkFile(name) and
                    (std.mem.endsWith(u8, name, ".dat") or std.mem.endsWith(u8, name, ".idx")))
                {
                    dir.deleteFile(name) catch {};
                    files_deleted += 1;
                }
            }
        }
        std.debug.print("  Deleted {d} files\n", .{files_deleted});
    }

    std.debug.print("\nDone!\n", .{});
}

fn isBenchmarkFile(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "_")) return false;
    const marker = "_" ++ metric_name ++ ".";
    return std.mem.indexOf(u8, name, marker) != null;
}

fn getResidentMemory() !u64 {
    const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = try file.read(&buf);
    const content = buf[0..bytes_read];

    var iter = std.mem.splitScalar(u8, content, ' ');
    _ = iter.next(); // skip size
    const resident_pages_str = iter.next() orelse return error.ParseError;

    const resident_pages = try std.fmt.parseInt(u64, resident_pages_str, 10);

    const page_size: u64 = 4096;
    return resident_pages * page_size;
}

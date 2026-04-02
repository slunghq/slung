//! ColumnTable benchmark

const std = @import("std");
const Allocator = std.mem.Allocator;
const ColumnTable = @import("../../benches.zig").ColumnTable;
const utils = @import("../utils.zig");

const n_hosts = 10;
const rows_per_host: usize = 100_000;
const total_rows: usize = n_hosts * rows_per_host;
const progress_interval: usize = 10_000;

const col_names = [_][]const u8{ "timestamp", "value", "series_key" };
const hosts = [_][]const u8{ "h-0", "h-1", "h-2", "h-3", "h-4", "h-5", "h-6", "h-7", "h-8", "h-9" };

pub fn run(allocator: Allocator) !void {
    std.debug.print("\n=== ColumnTable ===\n", .{});

    var prng = std.Random.DefaultPrng.init(utils.randomSeed());
    const random = prng.random();

    var table = try ColumnTable.init(allocator, &col_names);
    defer table.deinit();
    try table.reserve(total_rows);

    var peak_mem: u64 = 0;
    const start = std.time.nanoTimestamp();
    var written: usize = 0;

    for (hosts, 0..) |host, hi| {
        const series_key = try std.fmt.allocPrint(allocator, "cpu,host={s}", .{host});
        defer allocator.free(series_key);

        for (0..rows_per_host) |i| {
            written = hi * rows_per_host + i + 1;
            var vals = [_]ColumnTable.Value{
                .{ .Int = @intCast(written) },
                .{ .Float = random.float(f64) * 100.0 },
                .{ .Bytes = series_key },
            };
            try table.insert(.{ .key = series_key, .values = &vals });

            if (i > 0 and i % progress_interval == 0) {
                const now = std.time.nanoTimestamp();
                const elapsed: u128 = @intCast(now - start);
                const ns_per = elapsed / written;
                const rps = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
                const mem = utils.getResidentMemory() catch 0;
                if (mem > peak_mem) peak_mem = mem;
                std.debug.print("  [{s}] {d} rows - {d} rows/s - {d} MiB\n", .{ host, written, rps, peak_mem / 1024 / 1024 });
            }
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u128 = @intCast(end - start);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ns_per = elapsed_ns / written;
    const rps = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
    const mem = utils.getResidentMemory() catch 0;
    if (mem > peak_mem) peak_mem = mem;

    std.debug.print("  insert: {d} rows in {d:.2}s - {d} rows/s - {d}ns/row - peak {d} MiB\n", .{
        written, elapsed_s, rps, ns_per, peak_mem / 1024 / 1024,
    });

    // Range query bench
    const query_key = "cpu,host=h-9";
    const lo: i64 = @intCast(total_rows - rows_per_host);
    const hi_ts: i64 = @intCast(total_rows - 1);

    std.debug.print("  query: scanning [{d}, {d}] on {s}\n", .{ lo, hi_ts, query_key });

    for (0..3) |qi| {
        const qs = std.time.nanoTimestamp();

        const ts_col = try table.getColumnById(0);
        const val_col = try table.getColumnById(1);
        const sk_col = try table.getColumnById(2);

        var count: u64 = 0;
        var sum: f64 = 0;
        for (ts_col, 0..) |ts_v, i| {
            const ts = ts_v.Int;
            if (ts < lo or ts > hi_ts) continue;
            if (!std.mem.eql(u8, sk_col[i].Bytes, query_key)) continue;
            sum += val_col[i].Float;
            count += 1;
        }

        const qe = std.time.nanoTimestamp();
        const qms = @as(f64, @floatFromInt(qe - qs)) / 1e6;
        const avg = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0;
        if (qi == 0) std.debug.print("  avg={d:.3} count={d}\n", .{ avg, count });
        std.debug.print("  run {d}: {d:.2}ms\n", .{ qi + 1, qms });
    }
}

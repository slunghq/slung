//! SkipList benchmark

const std = @import("std");
const Allocator = std.mem.Allocator;
const SkipList = @import("../../benches.zig").SkipList;
const utils = @import("../utils.zig");

const n_inserts: usize = 100_000;
const n_searches: usize = 10_000;
const progress_interval: usize = 10_000;

pub fn run(allocator: Allocator) !void {
    std.debug.print("\n=== SkipList ===\n", .{});

    var prng = std.Random.DefaultPrng.init(utils.randomSeed());
    const random = prng.random();

    // Pre-generate key/value strings upfront - isolates skiplist perf from fmt allocation
    const keys = try allocator.alloc([16]u8, n_inserts);
    defer allocator.free(keys);
    const vals = try allocator.alloc([16]u8, n_inserts);
    defer allocator.free(vals);

    for (0..n_inserts) |i| {
        _ = try std.fmt.bufPrint(&keys[i], "{d:0>16}", .{random.int(u64) % (n_inserts * 10)});
        _ = try std.fmt.bufPrint(&vals[i], "{d:0>16}", .{i});
    }

    var list = try SkipList.init(allocator, @intCast(std.time.microTimestamp()));
    defer list.deinit();

    var peak_mem: u64 = 0;
    const start = std.time.nanoTimestamp();

    for (0..n_inserts) |i| {
        _ = try list.insert(&keys[i], &vals[i]);

        if (i > 0 and i % progress_interval == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed: u128 = @intCast(now - start);
            const ns_per = elapsed / i;
            const ips = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
            const mem = utils.getResidentMemory() catch 0;
            if (mem > peak_mem) peak_mem = mem;
            std.debug.print("  {d} inserts - {d} inserts/s - {d} MiB\n", .{ i, ips, peak_mem / 1024 / 1024 });
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u128 = @intCast(end - start);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ns_per = elapsed_ns / n_inserts;
    const ips = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
    const mem = utils.getResidentMemory() catch 0;
    if (mem > peak_mem) peak_mem = mem;

    std.debug.print("  insert: {d} in {d:.2}s - {d} inserts/s - {d}ns/insert - peak {d} MiB\n", .{
        n_inserts, elapsed_s, ips, ns_per, peak_mem / 1024 / 1024,
    });

    // Search bench - random lookups across inserted keys
    const ss = std.time.nanoTimestamp();
    var found: usize = 0;
    for (0..n_searches) |_| {
        const ki = random.intRangeAtMost(usize, 0, n_inserts - 1);
        if (list.search(&keys[ki]) != null) found += 1;
    }
    const se = std.time.nanoTimestamp();
    const search_ns = @as(f64, @floatFromInt(se - ss)) / @as(f64, @floatFromInt(n_searches));
    std.debug.print("  search: {d}/{d} found - {d:.1}ns/search\n", .{ found, n_searches, search_ns });
}

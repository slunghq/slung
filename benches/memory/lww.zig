//! LwwRegistry benchmark

const std = @import("std");
const Allocator = std.mem.Allocator;
const LwwRegistry = @import("../../benches.zig").LwwRegistry;
const hlc = @import("../../benches.zig").hlc;
const Timestamp = hlc.Timestamp;
const Hlc = hlc.Hlc;
const utils = @import("../utils.zig");

const n_keys = 100;
const n_puts: usize = 1_000_000;
const progress_interval: usize = 100_000;

pub fn run(allocator: Allocator) !void {
    std.debug.print("\n=== LwwRegistry ===\n", .{});

    var prng = std.Random.DefaultPrng.init(utils.randomSeed());
    const random = prng.random();

    var reg = LwwRegistry.init(allocator);
    defer reg.deinit();

    var clock = Hlc.init(1);

    var key_bufs: [n_keys][24]u8 = undefined;
    var key_slices: [n_keys][]const u8 = undefined;
    for (0..n_keys) |i| {
        key_slices[i] = try std.fmt.bufPrint(&key_bufs[i], "metric.cpu.host-{d:0>3}", .{i});
    }

    var peak_mem: u64 = 0;
    var accepted: usize = 0;
    const start = std.time.nanoTimestamp();
    const sync_interval = 1000;

    var wall_time = std.time.milliTimestamp();

    for (0..n_puts) |i| {
        if (i % sync_interval == 0) {
            wall_time = std.time.milliTimestamp();
        }

        const key = key_slices[random.intRangeAtMost(usize, 0, n_keys - 1)];
        const ts = clock.send_with_wall(@intCast(wall_time));
        const val = LwwRegistry.Value{ .Float = random.float(f64) * 100.0 };

        if (try reg.put(key, ts, val, .{ .cause = 1, .entity = 1, .node = "" })) accepted += 1;

        if (i > 0 and i % progress_interval == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed: u128 = @intCast(now - start);
            const ns_per = elapsed / i;
            const pps = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
            const mem = utils.getResidentMemory() catch 0;
            if (mem > peak_mem) peak_mem = mem;
            std.debug.print("  {d} puts - {d} puts/s - {d} MiB\n", .{ i, pps, peak_mem / 1024 / 1024 });
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u128 = @intCast(end - start);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ns_per = elapsed_ns / n_puts;
    const pps = if (ns_per > 0) 1_000_000_000 / ns_per else 0;
    const mem = utils.getResidentMemory() catch 0;
    if (mem > peak_mem) peak_mem = mem;

    std.debug.print("  put: {d} ops in {d:.2}s - {d} puts/s - {d}ns/op - accepted {d:.1}% - peak {d} MiB\n", .{
        n_puts,
        elapsed_s,
        pps,
        ns_per,
        @as(f64, @floatFromInt(accepted)) / @as(f64, @floatFromInt(n_puts)) * 100.0,
        peak_mem / 1024 / 1024,
    });

    const gs = std.time.nanoTimestamp();
    var hits: usize = 0;
    for (key_slices) |k| {
        if (reg.get(k) != null) hits += 1;
    }
    const ge = std.time.nanoTimestamp();
    const get_ns = @as(f64, @floatFromInt(ge - gs)) / @as(f64, @floatFromInt(n_keys));
    std.debug.print("  get: {d}/{d} keys found - {d:.1}ns/get\n", .{ hits, n_keys, get_ns });
}

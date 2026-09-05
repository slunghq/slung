//! Custom WAL durability benchmark.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Wal = @import("../../src/wal.zig");

const eventual_iters: usize = 1_000;
const strict_iters: usize = 20;
const batch_size: usize = 128;
const value = "{\"value\":42.0}";

fn removeWal(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn mutation(index: usize) Wal.FactMutation {
    return .{
        .namespace = "wal_bench",
        .entity = @intCast(index + 1),
        .component = 1,
        .value = value,
        .timestamp = .{ .wall = @intCast(index + 1), .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 1, .entity = @intCast(index + 1), .node = "bench" },
    };
}

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.untilNow(io, .awake).toNanoseconds());
}

fn runEventual(allocator: Allocator, io: std.Io, path: []const u8) !void {
    removeWal(io, path);
    var wal = try Wal.open(allocator, io, path);
    const start = std.Io.Clock.awake.now(io);
    for (0..eventual_iters) |index| {
        var accepted = [_]bool{false};
        try wal.enqueueBatch(&.{mutation(index)}, accepted[0..], .eventual);
    }
    const enqueue_ns = elapsedNs(io, start);
    const drain_start = std.Io.Clock.awake.now(io);
    wal.deinit();
    const drain_ns = elapsedNs(io, drain_start);
    removeWal(io, path);

    const enqueue_s = @as(f64, @floatFromInt(enqueue_ns)) / 1e9;
    const drain_s = @as(f64, @floatFromInt(drain_ns)) / 1e9;
    std.debug.print("  eventual: {d} enqueues in {d:.3}s - {d:.0}/s; drain {d:.3}s\n", .{
        eventual_iters,
        enqueue_s,
        @as(f64, @floatFromInt(eventual_iters)) / @max(enqueue_s, 0.000000001),
        drain_s,
    });
}

fn runStrict(allocator: Allocator, io: std.Io, path: []const u8) !void {
    removeWal(io, path);
    var wal = try Wal.open(allocator, io, path);
    const start = std.Io.Clock.awake.now(io);
    for (0..strict_iters) |index| {
        var accepted = [_]bool{false};
        try wal.enqueueBatch(&.{mutation(index)}, accepted[0..], .strict);
    }
    const elapsed_ns = elapsedNs(io, start);
    wal.deinit();
    removeWal(io, path);

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print("  strict: {d} append+fsync in {d:.3}s - {d:.0}/s\n", .{
        strict_iters,
        elapsed_s,
        @as(f64, @floatFromInt(strict_iters)) / @max(elapsed_s, 0.000000001),
    });
}

fn runBatch(allocator: Allocator, io: std.Io, path: []const u8) !void {
    removeWal(io, path);
    var wal = try Wal.open(allocator, io, path);
    var mutations: [batch_size]Wal.FactMutation = undefined;
    var accepted: [batch_size]bool = undefined;
    const start = std.Io.Clock.awake.now(io);
    var completed: usize = 0;
    while (completed < eventual_iters) {
        const count = @min(batch_size, eventual_iters - completed);
        for (0..count) |offset| mutations[offset] = mutation(completed + offset);
        try wal.enqueueBatch(mutations[0..count], accepted[0..count], .eventual);
        completed += count;
    }
    const enqueue_ns = elapsedNs(io, start);
    const drain_start = std.Io.Clock.awake.now(io);
    wal.deinit();
    const drain_ns = elapsedNs(io, drain_start);
    removeWal(io, path);

    const enqueue_s = @as(f64, @floatFromInt(enqueue_ns)) / 1e9;
    const drain_s = @as(f64, @floatFromInt(drain_ns)) / 1e9;
    std.debug.print("  batch ({d}) eventual: {d} enqueues in {d:.3}s - {d:.0} records/s; drain {d:.3}s\n", .{
        batch_size,
        eventual_iters,
        enqueue_s,
        @as(f64, @floatFromInt(eventual_iters)) / @max(enqueue_s, 0.000000001),
        drain_s,
    });
}

pub fn run(allocator: Allocator, io: std.Io) !void {
    std.debug.print("\n=== Custom WAL ===\n", .{});
    try runEventual(allocator, io, "wal-eventual-benchmark.wal");
    try runBatch(allocator, io, "wal-batch-benchmark.wal");
    try runStrict(allocator, io, "wal-strict-benchmark.wal");
}

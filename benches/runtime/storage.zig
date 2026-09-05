//! SQLite persistence benchmark without Wasm or inference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Storage = @import("../../src/storage.zig").Storage;
const types = @import("../../src/types.zig");

const n_iters: usize = 100;
const batch_size: usize = 128;
const value = "{\"value\":42.0}";

fn removeDatabase(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var wal_buf: [128]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buf, "{s}.slung.wal", .{path});
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var shm_buf: [128]u8 = undefined;
    const shm_path = try std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path});
    std.Io.Dir.cwd().deleteFile(io, shm_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn mutation(index: usize) Storage.FactMutation {
    return .{
        .namespace = "storage_bench",
        .entity = 1,
        .component = 1,
        .value = value,
        .timestamp = .{ .wall = @intCast(index + 1), .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 1, .entity = 1, .node = "bench" },
    };
}

fn runSingle(allocator: Allocator, io: std.Io, path: []const u8) !void {
    try removeDatabase(io, path);
    var storage = try Storage.open(allocator, io, path);
    defer storage.deinit();

    const start = std.Io.Clock.awake.now(io);
    for (0..n_iters) |index| {
        _ = try storage.applyMutation(mutation(index));
    }
    const elapsed_ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ops_per_s = if (elapsed_s > 0) @as(f64, @floatFromInt(n_iters)) / elapsed_s else 0;
    std.debug.print("  single: {d} updates in {d:.2}s - {d:.0} updates/s\n", .{ n_iters, elapsed_s, ops_per_s });
}

fn runBatch(allocator: Allocator, io: std.Io, path: []const u8) !void {
    try removeDatabase(io, path);
    var storage = try Storage.open(allocator, io, path);
    defer storage.deinit();

    var mutations: [batch_size]Storage.FactMutation = undefined;
    var accepted: [batch_size]bool = undefined;
    const start = std.Io.Clock.awake.now(io);
    var completed: usize = 0;
    while (completed < n_iters) {
        const count = @min(batch_size, n_iters - completed);
        for (0..count) |offset| mutations[offset] = mutation(completed + offset);
        try storage.applyMutations(mutations[0..count], accepted[0..count]);
        completed += count;
    }
    const elapsed_ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ops_per_s = if (elapsed_s > 0) @as(f64, @floatFromInt(n_iters)) / elapsed_s else 0;
    std.debug.print("  batch ({d}): {d} updates in {d:.2}s - {d:.0} updates/s\n", .{ batch_size, n_iters, elapsed_s, ops_per_s });
}

pub fn run(allocator: Allocator, io: std.Io) !void {
    std.debug.print("\n=== SQLite Storage ===\n", .{});
    const path = "storage-benchmark.db";
    try runSingle(allocator, io, path);
    try runBatch(allocator, io, path);
    try removeDatabase(io, path);
}

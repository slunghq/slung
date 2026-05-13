const std = @import("std");

const Codspeed = @import("codspeed");

const bench_lww = @import("benches/memory/lww.zig");
const bench_skiplist = @import("benches/memory/skiplist.zig");
const bench_table = @import("benches/memory/table.zig");
const bench_runtime = @import("benches/runtime/execution.zig");
pub const LwwRegistry = @import("src/memory/lww.zig").LwwRegistry;
pub const SkipList = @import("src/memory/skiplist.zig").SkipList;
pub const ColumnTable = @import("src/memory/table.zig").ColumnTable;
pub const hlc = @import("src/primitives/hlc.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    var use_codspeed = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--runner")) {
            use_codspeed = true;
            break;
        }
    }

    if (use_codspeed) {
        var codspeed = Codspeed.init(allocator, "benches/benches.zig");
        defer codspeed.deinit();

        try codspeed.start("memory.table");
        try bench_table.run(allocator, io);
        try codspeed.stop("memory.table");

        try codspeed.start("memory.lww");
        try bench_lww.run(allocator, io);
        try codspeed.stop("memory.lww");

        try codspeed.start("memory.skiplist");
        try bench_skiplist.run(allocator, io);
        try codspeed.stop("memory.skiplist");

        try codspeed.start("runtime.execution");
        try bench_runtime.run(allocator, io);
        try codspeed.stop("runtime.execution");
    } else {
        try bench_table.run(allocator, io);
        try bench_lww.run(allocator, io);
        try bench_skiplist.run(allocator, io);
        try bench_runtime.run(allocator, io);
    }
}

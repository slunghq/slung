const std = @import("std");

const Codspeed = @import("codspeed");

const bench_lww = @import("benches/memory/lww.zig");
const bench_skiplist = @import("benches/memory/skiplist.zig");
const bench_table = @import("benches/memory/table.zig");
pub const LwwRegistry = @import("src/memory/lww.zig").LwwRegistry;
pub const SkipList = @import("src/memory/skiplist.zig").SkipList;
pub const ColumnTable = @import("src/memory/table.zig").ColumnTable;
pub const hlc = @import("src/primitives/hlc.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var codspeed = Codspeed.init(allocator, "benches/benches.zig");
    defer codspeed.deinit();

    try codspeed.start("memory.table");
    try bench_table.run(allocator);
    try codspeed.stop("memory.table");

    try codspeed.start("memory.lww");
    try bench_lww.run(allocator);
    try codspeed.stop("memory.lww");

    try codspeed.start("memory.skiplist");
    try bench_skiplist.run(allocator);
    try codspeed.stop("memory.skiplist");
}

const std = @import("std");
const zware = @import("zware");
const host = @import("host.zig");
const Store = zware.Store;
const Module = zware.Module;
const Instance = zware.Instance;
const Allocator = std.mem.Allocator;

pub fn spawn(allocator: Allocator, bytes: []const u8, context_ptr: usize) !void {
    var store = Store.init(allocator);
    defer store.deinit();

    try host.initHostFunctions(&store, context_ptr);

    var module = Module.init(allocator, bytes);
    defer module.deinit();
    try module.decode();

    var instance = Instance.init(allocator, &store, module);
    defer instance.deinit();
    try instance.instantiate();

    var input = [0]u64{};
    var output = [1]u64{0};

    try instance.invoke("call", &input, &output, .{});
}

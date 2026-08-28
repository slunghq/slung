//! Generic Slung host ABI using zwasm 2's typed Caller callbacks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zwasm = @import("zwasm");
const Context = @import("../../engine/context.zig").Context;
const types = @import("../../types.zig");

fn ctx(caller: *zwasm.Caller) *Context {
    return caller.data(Context);
}

fn writeU32(memory: zwasm.Memory, addr: u32, value: u32) !void {
    try memory.write(addr, value);
}

/// slung_get(entity, component, out_ptr_addr, out_len_addr) -> status.
pub fn slung_get(caller: *zwasm.Caller, entity_id: u32, component_id: u32, out_ptr: u32, out_len: u32) i32 {
    const c = ctx(caller);
    const memory = caller.memory() orelse return 1;
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{d}:{d}", .{ c.namespace, entity_id, component_id }) catch return 1;

    var guard = c.lww_store.getMut().lock();
    defer guard.deinit();
    const entry = guard.get().get(key) orelse {
        writeU32(memory, out_ptr, 0) catch return 1;
        writeU32(memory, out_len, 0) catch return 1;
        return 0;
    };

    var out: std.Io.Writer.Allocating = .init(c.allocator);
    defer out.deinit();
    switch (entry.value) {
        .Bool => |v| std.json.Stringify.value(v, .{}, &out.writer) catch return 1,
        .Int => |v| std.json.Stringify.value(v, .{}, &out.writer) catch return 1,
        .Float => |v| std.json.Stringify.value(v, .{}, &out.writer) catch return 1,
        .Bytes => |v| out.writer.writeAll(v) catch return 1,
    }
    const bytes = out.toOwnedSlice() catch return 1;
    defer c.allocator.free(bytes);
    const ptr = allocate(caller, bytes) catch return 1;
    writeU32(memory, out_ptr, ptr) catch return 1;
    writeU32(memory, out_len, @intCast(bytes.len)) catch return 1;
    return 0;
}

/// slung_set(entity, component, value_ptr, value_len) -> status.
pub fn slung_set(caller: *zwasm.Caller, entity_id: u32, component_id: u32, value_ptr: u32, value_len: u32) i32 {
    const c = ctx(caller);
    const memory = caller.memory() orelse return 1;
    if (value_ptr == 0 or value_len == 0) return 1;
    const bytes = memory.sliceAt(value_ptr, value_len) catch return 2;
    const parsed = std.json.parseFromSlice(std.json.Value, c.allocator, bytes, .{}) catch return 3;
    defer parsed.deinit();
    const value: types.Value = switch (parsed.value) {
        .bool => |v| .{ .Bool = v },
        .integer => |v| .{ .Int = v },
        .float => |v| .{ .Float = v },
        .string => |v| .{ .Bytes = v },
        else => .{ .Bytes = bytes },
    };
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrintZ(&key_buf, "{s}:{d}:{d}", .{ c.namespace, entity_id, component_id }) catch return 4;
    const cause = types.CausalTag{ .cause = c.current_rule, .entity = entity_id, .node = c.node_id };
    const ts = c.clock.*.send();
    var guard = c.lww_store.getMut().lock();
    defer guard.deinit();
    const accepted = guard.get().put(key, ts, value, cause) catch return 5;
    if (accepted) {
        var qguard = c.dirty_queue.getMut().lock();
        defer qguard.deinit();
        _ = qguard.get().push(.{ .entity = entity_id, .component = component_id }) catch {};
    }
    return 0;
}

/// slung_now(wall_hi_addr, wall_lo_addr, logical_addr) -> status.
pub fn slung_now(caller: *zwasm.Caller, wall_hi: u32, wall_lo: u32, logical: u32) i32 {
    const memory = caller.memory() orelse return 1;
    const ts = ctx(caller).clock.*.send();
    writeU32(memory, wall_hi, @intCast(ts.wall >> 32)) catch return 1;
    writeU32(memory, wall_lo, @intCast(ts.wall & 0xffffffff)) catch return 1;
    writeU32(memory, logical, ts.logical) catch return 1;
    return 0;
}

pub fn slung_yield(_: *zwasm.Caller) i32 {
    return 0;
}

fn allocate(caller: *zwasm.Caller, data: []const u8) !u32 {
    const c = ctx(caller);
    const inst = c.module;
    if (inst.typedFunc(fn (u32) u32, "slung_alloc").instance.exportFuncSig("slung_alloc") != null) {
        const ptr = try inst.call(fn (u32) u32, "slung_alloc", .{@as(u32, @intCast(data.len))});
        const memory = caller.memory() orelse return error.NoMemory;
        _ = try memory.sliceAt(ptr, @intCast(data.len));
        @memcpy((try memory.sliceAt(ptr, @intCast(data.len))).ptr, data);
        return ptr;
    }
    const memory = caller.memory() orelse return error.NoMemory;
    const old = memory.grow(@intCast((data.len + 65535) / 65536)) orelse return error.OutOfMemory;
    const ptr = old * 65536;
    @memcpy((try memory.sliceAt(ptr, @intCast(data.len))).ptr, data);
    return ptr;
}

pub fn defineHostFunctions(linker: *zwasm.Linker, context: *anyopaque) !void {
    try linker.defineFuncCtx("env", "slung_get", context, fn (*zwasm.Caller, u32, u32, u32, u32) i32, slung_get);
    try linker.defineFuncCtx("env", "slung_set", context, fn (*zwasm.Caller, u32, u32, u32, u32) i32, slung_set);
    try linker.defineFuncCtx("env", "slung_now", context, fn (*zwasm.Caller, u32, u32, u32) i32, slung_now);
    try linker.defineFuncCtx("env", "slung_yield", context, fn (*zwasm.Caller) i32, slung_yield);
}

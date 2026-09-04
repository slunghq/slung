//! Generic Host ABI — Active Memory & Runtime
//!
//! Core operations for rule execution:
//! + slung_get: read component value from local store
//! + slung_set: write component value and signal dirty
//! + slung_now: get current HLC timestamp
//! + slung_yield: cooperative suspension

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const zwasm = @import("zwasm");

const context_mod = @import("../../engine/context.zig");
const Context = context_mod.Context;
const LwwRegistry = @import("../../memory/lww.zig").LwwRegistry;
const Arc = @import("../../primitives/arc.zig").Arc;
const Hlc = @import("../../primitives/hlc.zig").Hlc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;
const DirtyQueue = @import("../../queue.zig").DirtyQueue;
const types = @import("../../types.zig");

/// slung_get(entity_id: i32, component_id: i32) -> (ptr: i32, len: i32)
///
/// Reads a component value from the LWW store and allocates it in guest memory.
/// Stack: [entity_id, component_id] -> [ptr, len]
/// Returns `(0, 0)` on error or missing value.
pub fn slung_get(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    const out_len: u32 = vm.popOperandU32();
    const out_ptr: u32 = vm.popOperandU32();
    const component_id: types.ComponentId = vm.popOperandU32();
    const entity_id: types.EntityId = vm.popOperandU32();

    var key_buf: [512]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_buf, "{s}:{d}:{d}", .{
        ctx.namespace,
        entity_id,
        component_id,
    }) catch {
        try writeGuestU32(ctx.module, out_ptr, 0);
        try writeGuestU32(ctx.module, out_len, 0);
        try vm.pushOperand(@as(u64, 1));
        return;
    };

    var cached_value: ?types.Value = null;
    {
        var store_guard = ctx.lww_store.getMut().lock();
        defer store_guard.deinit();
        if (store_guard.get().get(key_str)) |entry| {
            cached_value = entry.value;
        }
    }

    const persisted = if (cached_value == null and ctx.storage != null)
        (try ctx.loadFact(entity_id, component_id))
    else
        null;
    defer if (persisted) |fact| fact.deinit(ctx.allocator);

    if (cached_value == null and persisted == null) {
        try writeGuestU32(ctx.module, out_ptr, 0);
        try writeGuestU32(ctx.module, out_len, 0);
        try vm.pushOperand(@as(u64, 1));
        return;
    }

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    const value = cached_value orelse types.Value{ .Bytes = persisted.?.value };
    switch (value) {
        .Bool => |b| try std.json.Stringify.value(b, .{}, &out.writer),
        .Int => |i| try std.json.Stringify.value(i, .{}, &out.writer),
        .Float => |f| try std.json.Stringify.value(f, .{}, &out.writer),
        .Bytes => |b| try out.writer.writeAll(b), // Bytes are already JSON, output as-is
    }

    const value_bytes = try out.toOwnedSlice();
    defer ctx.allocator.free(value_bytes);
    const guest_data_ptr = try allocateInGuestMemory(vm, ctx.module, value_bytes);

    try writeGuestU32(ctx.module, out_ptr, @intCast(guest_data_ptr));
    try writeGuestU32(ctx.module, out_len, @intCast(value_bytes.len));
    try vm.pushOperand(@as(u64, 0));
}

/// slung_set(entity_id: i32, component_id: i32, value_ptr: i32, value_len: i32) -> (status: i32)
///
/// Writes a component value to the LWW store and signals dirty entry.
/// Value is JSON-serialized in guest memory at (value_ptr, value_len).
/// Stack: [entity_id, component_id, value_ptr, value_len] -> [status]
/// Returns 0 on success, non-zero error code on failure.
pub fn slung_set(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    const value_len = vm.popOperandU32();
    const value_ptr = vm.popOperandU32();
    const component_id: types.ComponentId = vm.popOperandU32();
    const entity_id: types.EntityId = vm.popOperandU32();

    if (value_len == 0 or value_ptr == 0) {
        // Invalid parameters
        try vm.pushOperand(@as(u64, 1));
        return;
    }

    const value_bytes = ctx.module.memoryRead(ctx.allocator, value_ptr, value_len) catch {
        try vm.pushOperand(@as(u64, 2));
        return;
    };
    defer ctx.allocator.free(value_bytes);

    const parsed_generic = std.json.parseFromSlice(std.json.Value, ctx.allocator, value_bytes, .{}) catch {
        try vm.pushOperand(@as(u64, 3));
        return;
    };
    defer parsed_generic.deinit();

    var parsed_value: types.Value = undefined;
    switch (parsed_generic.value) {
        .bool => |b| parsed_value = .{ .Bool = b },
        .integer => |i| parsed_value = .{ .Int = i },
        .float => |f| parsed_value = .{ .Float = f },
        .string => |s| parsed_value = .{ .Bytes = s },
        else => {
            parsed_value = .{ .Bytes = value_bytes };
        },
    }

    const ts = ctx.clock.*.send();

    const cause = types.CausalTag{
        .cause = ctx.current_rule,
        .entity = entity_id,
        .node = ctx.node_id,
    };

    // namespace:entity:component
    var key_buf: [512]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_buf, "{s}:{d}:{d}", .{
        ctx.namespace,
        entity_id,
        component_id,
    }) catch {
        // Key too long
        try vm.pushOperand(@as(u64, 4));
        return;
    };

    // Do not publish a fact that cannot be scheduled. A queue-full signal
    // must fail before LWW or cascade state is mutated.
    {
        var queue_capacity_guard = ctx.dirty_queue.getMut().lock();
        defer queue_capacity_guard.deinit();
        if (queue_capacity_guard.get().isFull()) {
            ctx.recordCascadeError(error.QueueFull);
            try vm.pushOperand(@as(u64, 6));
            return;
        }
    }

    const accepted = if (ctx.storage) |_| blk: {
        var previous_entry: ?LwwRegistry.Entry = null;
        // Update in-memory LWW first.
        const memory_accepted = blk2: {
            var store_guard = ctx.lww_store.getMut().lock();
            defer store_guard.deinit();
            if (store_guard.get().get(key_str)) |entry| {
                previous_entry = store_guard.get().cloneEntry(entry) catch {
                    try vm.pushOperand(@as(u64, 5));
                    return;
                };
            }
            break :blk2 store_guard.get().put(key_str, ts, parsed_value, cause) catch {
                if (previous_entry) |entry| store_guard.get().freeEntry(entry);
                try vm.pushOperand(@as(u64, 5));
                return;
            };
        };
        if (memory_accepted) {
            // Accumulate for cascade checkpoint; no WAL write here.
            _ = ctx.accumulateMutation(.{
                .namespace = ctx.namespace,
                .entity = entity_id,
                .component = component_id,
                .value = value_bytes,
                .timestamp = ts,
                .cause = cause,
            }) catch {
                var rollback_guard = ctx.lww_store.getMut().lock();
                defer rollback_guard.deinit();
                rollback_guard.get().rollbackPut(key_str, ts, previous_entry) catch |rollback_err| {
                    ctx.recordCascadeError(rollback_err);
                };
                try vm.pushOperand(@as(u64, 5));
                return;
            };
            // Signal dirty so transitive rules fire.
            var queue_guard = ctx.dirty_queue.getMut().lock();
            const signal_result = queue_guard.get().push(.{ .entity = entity_id, .component = component_id });
            queue_guard.deinit();
            if (signal_result) |_| {} else |err| {
                var store_guard = ctx.lww_store.getMut().lock();
                defer store_guard.deinit();
                store_guard.get().rollbackPut(key_str, ts, previous_entry) catch |rollback_err| {
                    ctx.recordCascadeError(rollback_err);
                    try vm.pushOperand(@as(u64, 5));
                    return;
                };
                ctx.recordCascadeError(err);
                try vm.pushOperand(@as(u64, 6));
                return;
            }
        }
        if (!memory_accepted) {
            if (previous_entry) |entry| {
                var store_guard = ctx.lww_store.getMut().lock();
                defer store_guard.deinit();
                store_guard.get().freeEntry(entry);
            }
        } else if (previous_entry) |entry| {
            var store_guard = ctx.lww_store.getMut().lock();
            defer store_guard.deinit();
            store_guard.get().freeEntry(entry);
        }
        break :blk memory_accepted;
    } else blk: {
        var store_guard = ctx.lww_store.getMut().lock();
        defer store_guard.deinit();
        const store = store_guard.get();
        const previous_entry = if (store.get(key_str)) |entry|
            (store.cloneEntry(entry) catch {
                try vm.pushOperand(@as(u64, 5));
                return;
            })
        else
            null;
        const memory_accepted = store.put(key_str, ts, parsed_value, cause) catch {
            if (previous_entry) |entry| store.freeEntry(entry);
            try vm.pushOperand(@as(u64, 5));
            return;
        };

        if (memory_accepted) {
            var queue_guard = ctx.dirty_queue.getMut().lock();
            defer queue_guard.deinit();
            queue_guard.get().push(.{
                .entity = entity_id,
                .component = component_id,
            }) catch |err| {
                store.rollbackPut(key_str, ts, previous_entry) catch |rollback_err| {
                    ctx.recordCascadeError(rollback_err);
                    try vm.pushOperand(@as(u64, 5));
                    return;
                };
                ctx.recordCascadeError(err);
                try vm.pushOperand(@as(u64, 6));
                return;
            };
        }
        if (!memory_accepted) {
            if (previous_entry) |entry| store.freeEntry(entry);
        } else if (previous_entry) |entry| {
            store.freeEntry(entry);
        }
        break :blk memory_accepted;
    };

    _ = accepted;

    try vm.pushOperand(@as(u64, 0));
}

/// slung_now(wall_hi_ptr: i32, wall_lo_ptr: i32, logical_ptr: i32) -> (status: i32)
///
/// Writes the current HLC timestamp components to guest memory addresses.
/// Stack: [wall_hi_ptr, wall_lo_ptr, logical_ptr] -> [status]
/// Returns 0 on success, non-zero error code on failure.
pub fn slung_now(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    const logical_ptr: u32 = vm.popOperandU32();
    const wall_lo_ptr: u32 = vm.popOperandU32();
    const wall_hi_ptr: u32 = vm.popOperandU32();

    const ts = ctx.clock.*.send();

    const wall_ms_hi: u32 = @intCast((ts.wall >> 32) & 0xFFFFFFFF);
    const wall_ms_lo: u32 = @intCast(ts.wall & 0xFFFFFFFF);
    const logical_u32: u32 = ts.logical;

    try writeGuestU32(ctx.module, wall_hi_ptr, wall_ms_hi);
    try writeGuestU32(ctx.module, wall_lo_ptr, wall_ms_lo);
    try writeGuestU32(ctx.module, logical_ptr, logical_u32);

    try vm.pushOperand(@as(u64, 0));
}

/// slung_yield() -> (status: i32)
///
/// Cooperative pause point for rules. Currently always returns 0 (success).
/// Stack: [] -> [status]
pub fn slung_yield(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = context;

    // STUB: always succeed (return status 0)
    try vm.pushOperand(@as(u64, 0));
}

/// Allocate a buffer in guest memory and copy data into it.
fn allocateInGuestMemory(vm: *zwasm.Vm, module: *zwasm.WasmModule, data: []const u8) !u32 {
    if (data.len == 0) return 0;

    var results = [_]u64{0};
    if (module.instance.getExportFunc("slung_alloc") != null) {
        try vm.invoke(&module.instance, "slung_alloc", &.{data.len}, results[0..]);
        const guest_buffer_offset: u32 = @intCast(results[0]);
        if (guest_buffer_offset == 0) return error.GuestAllocationFailed;
        try module.memoryWrite(guest_buffer_offset, data);
        return guest_buffer_offset;
    }

    // Legacy modules without slung_alloc receive a fresh page range outside
    // their current linear memory instead of using a fixed heap address.
    const page_size = 64 * 1024;
    const pages: u32 = @intCast((data.len + page_size - 1) / page_size);
    const memory = try module.instance.getMemory(0);
    const old_pages = try memory.grow(pages);
    const guest_buffer_offset = old_pages * page_size;
    try module.memoryWrite(guest_buffer_offset, data);

    return guest_buffer_offset;
}

fn writeGuestU32(module: *zwasm.WasmModule, guest_addr: u32, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try module.memoryWrite(guest_addr, &buf);
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: Allocator,
    context: usize,
) !void {
    try host_fns.append(allocator, .{
        .name = "slung_get",
        .callback = slung_get,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_set",
        .callback = slung_set,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_now",
        .callback = slung_now,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_yield",
        .callback = slung_yield,
        .context = context,
    });
}

test "slung_set: host function is registered" {
    const allocator = testing.allocator;

    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;
    defer host_fns.deinit(allocator);

    try appendHostFunctions(&host_fns, allocator, 0);

    var found = false;
    for (host_fns.items) |entry| {
        if (std.mem.eql(u8, entry.name, "slung_set")) {
            found = true;
            break;
        }
    }

    try testing.expect(found);
}

test "slung_now: host function is registered" {
    const allocator = testing.allocator;

    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;
    defer host_fns.deinit(allocator);

    try appendHostFunctions(&host_fns, allocator, 0);

    var found = false;
    for (host_fns.items) |entry| {
        if (std.mem.eql(u8, entry.name, "slung_now")) {
            found = true;
            break;
        }
    }

    try testing.expect(found);
}

test "slung_get: host function is registered" {
    const allocator = testing.allocator;

    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;
    defer host_fns.deinit(allocator);

    try appendHostFunctions(&host_fns, allocator, 0);

    var found = false;
    for (host_fns.items) |entry| {
        if (std.mem.eql(u8, entry.name, "slung_get")) {
            found = true;
            break;
        }
    }

    try testing.expect(found);
}

test "appendHostFunctions: creates host function entries" {
    const allocator = testing.allocator;

    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;
    defer host_fns.deinit(allocator);

    try appendHostFunctions(&host_fns, allocator, 0);

    try testing.expectEqual(@as(usize, 4), host_fns.items.len);

    var found_get = false;
    var found_set = false;
    var found_now = false;
    var found_yield = false;

    for (host_fns.items) |entry| {
        if (std.mem.eql(u8, entry.name, "slung_get")) found_get = true;
        if (std.mem.eql(u8, entry.name, "slung_set")) found_set = true;
        if (std.mem.eql(u8, entry.name, "slung_now")) found_now = true;
        if (std.mem.eql(u8, entry.name, "slung_yield")) found_yield = true;
    }

    try testing.expect(found_get);
    try testing.expect(found_set);
    try testing.expect(found_now);
    try testing.expect(found_yield);
}

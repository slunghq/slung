//! Generic Host ABI — Active Memory & Runtime
//!
//! Core operations for rule execution:
//! + slung_get: read component value from local store
//! + slung_set: write component value and signal dirty
//! + slung_now: get current HLC timestamp
//! + slung_yield: cooperative suspension

const std = @import("std");
const zwasm = @import("zwasm");
const types = @import("../../types.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    // TODO: inject lww_store, hlc_clock, dirty_queue, current_rule_id
};

pub fn slung_get(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop entity_id, component_id from operand stack, lookup in lww_store, serialize value, allocate in guest memory, push ptr
}

pub fn slung_set(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop entity_id, component_id, value_ptr from operand stack, deserialize value, create causal tag, put in lww_store, emit dirty entry
}

pub fn slung_now(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: call hlc_clock.now(), encode to i64, push to stack
}

pub fn slung_yield(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: check async_enabled, check rule_depth, signal scheduler to yield, return 0 on success
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: std.mem.Allocator,
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

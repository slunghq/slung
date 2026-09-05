//! Module-owned persistent key/value storage ABI.
//!
//! Values are opaque bytes. Storage is scoped by the runtime namespace and
//! module name, so modules can reuse keys without colliding.

const std = @import("std");
const zwasm = @import("zwasm");
const Context = @import("../../engine/context.zig").Context;

pub fn slung_store_get(ctx_ptr: *anyopaque, context: usize) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);
    const out_len = vm.popOperandU32();
    const out_ptr = vm.popOperandU32();
    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();

    try writeU32(ctx.module, out_ptr, 0);
    try writeU32(ctx.module, out_len, 0);

    const storage = ctx.storage orelse return vm.pushOperand(2);
    if (key_len != 0 and key_ptr == 0) return vm.pushOperand(1);
    const key = ctx.module.memoryRead(ctx.allocator, key_ptr, key_len) catch return vm.pushOperand(1);
    defer ctx.allocator.free(key);

    const value = storage.get(ctx.namespace, ctx.module_name, key) catch return vm.pushOperand(2);
    const bytes = value orelse return vm.pushOperand(1);
    defer ctx.allocator.free(bytes);

    const ptr = allocateInGuestMemory(vm, ctx.module, bytes) catch return vm.pushOperand(2);
    try writeU32(ctx.module, out_ptr, ptr);
    try writeU32(ctx.module, out_len, @intCast(bytes.len));
    try vm.pushOperand(0);
}

pub fn slung_store_set(ctx_ptr: *anyopaque, context: usize) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);
    const value_len = vm.popOperandU32();
    const value_ptr = vm.popOperandU32();
    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();

    const storage = ctx.storage orelse return vm.pushOperand(2);
    if ((key_len != 0 and key_ptr == 0) or (value_len != 0 and value_ptr == 0)) return vm.pushOperand(1);
    const key = ctx.module.memoryRead(ctx.allocator, key_ptr, key_len) catch return vm.pushOperand(1);
    defer ctx.allocator.free(key);
    const value = ctx.module.memoryRead(ctx.allocator, value_ptr, value_len) catch return vm.pushOperand(1);
    defer ctx.allocator.free(value);

    storage.set(ctx.namespace, ctx.module_name, key, value) catch return vm.pushOperand(2);
    try vm.pushOperand(0);
}

pub fn slung_store_delete(ctx_ptr: *anyopaque, context: usize) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);
    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();

    const storage = ctx.storage orelse return vm.pushOperand(2);
    if (key_len != 0 and key_ptr == 0) return vm.pushOperand(1);
    const key = ctx.module.memoryRead(ctx.allocator, key_ptr, key_len) catch return vm.pushOperand(1);
    defer ctx.allocator.free(key);

    const deleted = storage.delete(ctx.namespace, ctx.module_name, key) catch return vm.pushOperand(2);
    try vm.pushOperand(if (deleted) 0 else 1);
}

fn allocateInGuestMemory(vm: *zwasm.Vm, module: *zwasm.WasmModule, data: []const u8) !u32 {
    if (data.len == 0) return 0;
    var results = [_]u64{0};
    if (module.instance.getExportFunc("slung_alloc") != null) {
        try vm.invoke(&module.instance, "slung_alloc", &.{data.len}, results[0..]);
        const ptr: u32 = @intCast(results[0]);
        if (ptr == 0) return error.GuestAllocationFailed;
        try module.memoryWrite(ptr, data);
        return ptr;
    }
    const page_size = 64 * 1024;
    const pages: u32 = @intCast((data.len + page_size - 1) / page_size);
    const memory = try module.instance.getMemory(0);
    const old_pages = try memory.grow(pages);
    const ptr = old_pages * page_size;
    try module.memoryWrite(ptr, data);
    return ptr;
}

fn writeU32(module: *zwasm.WasmModule, address: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try module.memoryWrite(address, &bytes);
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: std.mem.Allocator,
    context: usize,
) !void {
    try host_fns.append(allocator, .{ .name = "slung_store_get", .callback = slung_store_get, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_store_set", .callback = slung_store_set, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_store_delete", .callback = slung_store_delete, .context = context });
}

test "module store host functions are registered" {
    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;
    defer host_fns.deinit(std.testing.allocator);
    try appendHostFunctions(&host_fns, std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 3), host_fns.items.len);
}

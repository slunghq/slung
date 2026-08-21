const std = @import("std");

const zwasm = @import("zwasm");
const http = @import("dusty");

const context_mod = @import("../../engine/context.zig");
const Context = context_mod.Context;

/// Helper function to perform HTTP requests
fn performHttpRequest(
    vm: *zwasm.Vm,
    allocator: std.mem.Allocator,
    io: std.Io,
    module: *zwasm.WasmModule,
    method: http.Method,
    url_str: []const u8,
    body_opt: ?[]const u8,
) !void {
    var client = http.Client.init(allocator, io, .{});
    defer client.deinit();

    var response: http.ClientResponse = undefined;
    defer response.deinit();

    if (body_opt) |body| {
        response = client.fetch(url_str, .{ .method = method, .body = body }) catch {
            try vm.pushOperand(@as(u64, 0));
            try vm.pushOperand(@as(u64, 0));
            try vm.pushOperand(@as(u64, 1));
            return;
        };
    } else {
        response = client.fetch(url_str, .{ .method = method }) catch {
            try vm.pushOperand(@as(u64, 0));
            try vm.pushOperand(@as(u64, 0));
            try vm.pushOperand(@as(u64, 1));
            return;
        };
    }

    var response_buffer: std.ArrayList(u8) = .empty;
    defer response_buffer.deinit(allocator);

    if (try response.body()) |body| {
        try response_buffer.appendSlice(allocator, body);
    }

    const response_data = try response_buffer.toOwnedSlice(allocator);
    defer allocator.free(response_data);
    const guest_ptr = allocateInGuestMemory(vm, module, response_data) catch {
        try vm.pushOperand(@as(u64, 0));
        try vm.pushOperand(@as(u64, 0));
        try vm.pushOperand(@as(u64, 1));
        return;
    };

    const status: u32 = if (@intFromEnum(response.status()) >= 200 and
        @intFromEnum(response.status()) < 300) 0 else 1;

    try vm.pushOperand(@as(u64, guest_ptr));
    try vm.pushOperand(@as(u64, response_data.len));
    try vm.pushOperand(@as(u64, status));
}

pub fn slung_http_get(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    // Pop: [url_ptr, url_len]
    const url_len: u32 = vm.popOperandU32();
    const url_ptr: u32 = vm.popOperandU32();

    const url_bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_bytes);

    const url_str = ctx.allocator.dupe(u8, url_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_str);

    try performHttpRequest(vm, ctx.allocator, ctx.io, ctx.module, .get, url_str, null);
}

pub fn slung_http_post(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    // Pop: [url_ptr, url_len, body_ptr, body_len]
    const body_len: u32 = vm.popOperandU32();
    const body_ptr: u32 = vm.popOperandU32();
    const url_len: u32 = vm.popOperandU32();
    const url_ptr: u32 = vm.popOperandU32();

    const url_bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_bytes);

    const body_bytes = ctx.module.memoryRead(ctx.allocator, body_ptr, body_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(body_bytes);

    const url_str = ctx.allocator.dupe(u8, url_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_str);

    const body_str = ctx.allocator.dupe(u8, body_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(body_str);

    try performHttpRequest(vm, ctx.allocator, ctx.io, ctx.module, .post, url_str, body_str);
}

pub fn slung_http_put(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    // Pop: [url_ptr, url_len, body_ptr, body_len]
    const body_len: u32 = vm.popOperandU32();
    const body_ptr: u32 = vm.popOperandU32();
    const url_len: u32 = vm.popOperandU32();
    const url_ptr: u32 = vm.popOperandU32();

    const url_bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_bytes);

    const body_bytes = ctx.module.memoryRead(ctx.allocator, body_ptr, body_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(body_bytes);

    const url_str = ctx.allocator.dupe(u8, url_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_str);

    const body_str = ctx.allocator.dupe(u8, body_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(body_str);

    try performHttpRequest(vm, ctx.allocator, ctx.io, ctx.module, .put, url_str, body_str);
}

pub fn slung_http_delete(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    // Pop: [url_ptr, url_len]
    const url_len: u32 = vm.popOperandU32();
    const url_ptr: u32 = vm.popOperandU32();

    const url_bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        // Memory read error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_bytes);

    const url_str = ctx.allocator.dupe(u8, url_bytes) catch {
        // Allocation error
        try vm.pushOperand(@as(u64, 0)); // response_ptr
        try vm.pushOperand(@as(u64, 0)); // response_len
        try vm.pushOperand(@as(u64, 1)); // status: error
        return;
    };
    defer ctx.allocator.free(url_str);

    try performHttpRequest(vm, ctx.allocator, ctx.io, ctx.module, .delete, url_str, null);
}

/// Allocate a buffer in guest memory and copy data into it.
fn allocateInGuestMemory(vm: *zwasm.Vm, module: *zwasm.WasmModule, data: []const u8) !u32 {
    if (data.len == 0) return 0;

    var results = [_]u64{0};
    try vm.invoke(&module.instance, "slung_alloc", &.{data.len}, results[0..]);
    const guest_buffer_offset: u32 = @intCast(results[0]);
    if (guest_buffer_offset == 0) return error.GuestAllocationFailed;

    try module.memoryWrite(guest_buffer_offset, data);
    return guest_buffer_offset;
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: std.mem.Allocator,
    context: usize,
) !void {
    try host_fns.append(allocator, .{
        .name = "slung_http_get",
        .callback = slung_http_get,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_http_post",
        .callback = slung_http_post,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_http_put",
        .callback = slung_http_put,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_http_delete",
        .callback = slung_http_delete,
        .context = context,
    });
}

const std = @import("std");
const zwasm = @import("zwasm");

pub const Context = struct {
    allocator: std.mem.Allocator,
    // TODO: inject http_client reference
};

pub fn slung_http_get(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len from operand stack, perform HTTP GET, allocate response struct, push ptr
}

pub fn slung_http_post(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len, body_ptr, body_len from operand stack, perform HTTP POST, allocate response struct, push ptr
}

pub fn slung_http_put(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len, body_ptr, body_len from operand stack, perform HTTP PUT, allocate response struct, push ptr
}

pub fn slung_http_delete(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len from operand stack, perform HTTP DELETE, allocate response struct, push ptr
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

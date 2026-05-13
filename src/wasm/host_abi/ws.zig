const std = @import("std");

const zwasm = @import("zwasm");

pub const Context = struct {
    allocator: std.mem.Allocator,
    // TODO: inject ws_manager reference
};

pub fn slung_ws_connect(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len from operand stack, connect to websocket, push handle or 0 on error
}

pub fn slung_ws_next(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle from operand stack, wait for next message, allocate WsMessage struct, push ptr
}

pub fn slung_ws_send(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, msg_ptr, msg_len from operand stack, send message, push 0 on success
}

pub fn slung_ws_close(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle from operand stack, close websocket gracefully, push 0 on success
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: std.mem.Allocator,
    context: usize,
) !void {
    try host_fns.append(allocator, .{
        .name = "slung_ws_connect",
        .callback = slung_ws_connect,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_ws_next",
        .callback = slung_ws_next,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_ws_send",
        .callback = slung_ws_send,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_ws_close",
        .callback = slung_ws_close,
        .context = context,
    });
}

const std = @import("std");
const zwasm = @import("zwasm");

pub const Context = struct {
    allocator: std.mem.Allocator,
    // TODO: inject socket_manager reference
};

pub fn slung_tcp_connect(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop host_ptr, host_len, port from operand stack, connect to TCP server, push handle or 0 on error
}

pub fn slung_tcp_read(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, buf_ptr, buf_len from operand stack, read TCP data, push bytes_read or error code
}

pub fn slung_tcp_write(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, buf_ptr, buf_len from operand stack, write TCP data, push bytes_written or error code
}

pub fn slung_tcp_close(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle from operand stack, close TCP gracefully, push 0 on success
}

pub fn slung_udp_bind(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop port from operand stack, bind UDP socket, push handle or 0 on error
}

pub fn slung_udp_recv(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, buf_ptr, buf_len, addr_ptr from operand stack, receive UDP datagram, push bytes_received or error code
}

pub fn slung_udp_send(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, buf_ptr, buf_len, addr_ptr, addr_len, reserved from operand stack, send UDP packet, push bytes_sent or error code
}

pub fn appendHostFunctions(
    host_fns: *std.ArrayList(zwasm.HostFnEntry),
    allocator: std.mem.Allocator,
    context: usize,
) !void {
    try host_fns.append(allocator, .{
        .name = "slung_tcp_connect",
        .callback = slung_tcp_connect,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_tcp_read",
        .callback = slung_tcp_read,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_tcp_write",
        .callback = slung_tcp_write,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_tcp_close",
        .callback = slung_tcp_close,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_udp_bind",
        .callback = slung_udp_bind,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_udp_recv",
        .callback = slung_udp_recv,
        .context = context,
    });
    try host_fns.append(allocator, .{
        .name = "slung_udp_send",
        .callback = slung_udp_send,
        .context = context,
    });
}

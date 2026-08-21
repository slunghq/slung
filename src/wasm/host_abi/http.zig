const std = @import("std");
const zwasm = @import("zwasm");
const http = @import("dusty");
const Context = @import("../../engine/context.zig").Context;

test "outbound HTTP connection failure does not deinitialize an invalid response" {
    var client = http.Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    const result = client.fetch("http://127.0.0.1:1/", .{});
    if (result) |response| {
        var successful_response = response;
        defer successful_response.deinit();
        return error.UnexpectedSuccessfulRequest;
    } else |_| {}
}

fn writeResult(module: *zwasm.WasmModule, ptr_addr: u32, len_addr: u32, ptr: u32, len: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, ptr, .little);
    try module.memoryWrite(ptr_addr, &bytes);
    std.mem.writeInt(u32, &bytes, len, .little);
    try module.memoryWrite(len_addr, &bytes);
}

fn fail(vm: *zwasm.Vm, module: *zwasm.WasmModule, ptr_addr: u32, len_addr: u32) !void {
    try writeResult(module, ptr_addr, len_addr, 0, 0);
    try vm.pushOperand(1);
}

fn request(vm: *zwasm.Vm, allocator: std.mem.Allocator, io: std.Io, module: *zwasm.WasmModule, method: http.Method, url: []const u8, body: ?[]const u8, ptr_addr: u32, len_addr: u32) !void {
    var client = http.Client.init(allocator, io, .{});
    defer client.deinit();
    var response = if (body) |data| client.fetch(url, .{ .method = method, .body = data }) catch return fail(vm, module, ptr_addr, len_addr) else client.fetch(url, .{ .method = method }) catch return fail(vm, module, ptr_addr, len_addr);
    defer response.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    if (response.body() catch return fail(vm, module, ptr_addr, len_addr)) |data| {
        buffer.appendSlice(allocator, data) catch return fail(vm, module, ptr_addr, len_addr);
    }
    const owned = buffer.toOwnedSlice(allocator) catch return fail(vm, module, ptr_addr, len_addr);
    defer allocator.free(owned);
    const guest_ptr = allocate(vm, module, owned) catch return fail(vm, module, ptr_addr, len_addr);
    const status: u32 = if (@intFromEnum(response.status()) >= 200 and @intFromEnum(response.status()) < 300) 0 else 1;
    try writeResult(module, ptr_addr, len_addr, guest_ptr, @intCast(owned.len));
    try vm.pushOperand(status);
}

fn allocate(vm: *zwasm.Vm, module: *zwasm.WasmModule, data: []const u8) !u32 {
    if (data.len == 0) return 0;
    var results = [_]u64{0};
    try vm.invoke(&module.instance, "slung_alloc", &.{data.len}, results[0..]);
    const ptr: u32 = @intCast(results[0]);
    if (ptr == 0) return error.GuestAllocationFailed;
    try module.memoryWrite(ptr, data);
    return ptr;
}

pub fn slung_http_get(ctx_ptr: *anyopaque, context: usize) !void {
    return urlRequest(ctx_ptr, context, .get);
}
fn urlRequest(ctx_ptr: *anyopaque, context: usize, method: http.Method) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);
    const len_addr = vm.popOperandU32();
    const ptr_addr = vm.popOperandU32();
    const url_len = vm.popOperandU32();
    const url_ptr = vm.popOperandU32();
    const bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(bytes);
    const url = ctx.allocator.dupe(u8, bytes) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(url);
    return request(vm, ctx.allocator, ctx.io, ctx.module, method, url, null, ptr_addr, len_addr);
}

pub fn slung_http_post(ctx_ptr: *anyopaque, context: usize) !void {
    return bodyRequest(ctx_ptr, context, .post);
}
pub fn slung_http_put(ctx_ptr: *anyopaque, context: usize) !void {
    return bodyRequest(ctx_ptr, context, .put);
}
fn bodyRequest(ctx_ptr: *anyopaque, context: usize, method: http.Method) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);
    const len_addr = vm.popOperandU32();
    const ptr_addr = vm.popOperandU32();
    const body_len = vm.popOperandU32();
    const body_ptr = vm.popOperandU32();
    const url_len = vm.popOperandU32();
    const url_ptr = vm.popOperandU32();
    const url_bytes = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(url_bytes);
    const body_bytes = ctx.module.memoryRead(ctx.allocator, body_ptr, body_len) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(body_bytes);
    const url = ctx.allocator.dupe(u8, url_bytes) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(url);
    const body = ctx.allocator.dupe(u8, body_bytes) catch return fail(vm, ctx.module, ptr_addr, len_addr);
    defer ctx.allocator.free(body);
    return request(vm, ctx.allocator, ctx.io, ctx.module, method, url, body, ptr_addr, len_addr);
}

pub fn slung_http_delete(ctx_ptr: *anyopaque, context: usize) !void {
    return urlRequest(ctx_ptr, context, .delete);
}

pub fn appendHostFunctions(host_fns: *std.ArrayList(zwasm.HostFnEntry), allocator: std.mem.Allocator, context: usize) !void {
    try host_fns.append(allocator, .{ .name = "slung_http_get", .callback = slung_http_get, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_post", .callback = slung_http_post, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_put", .callback = slung_http_put, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_delete", .callback = slung_http_delete, .context = context });
}

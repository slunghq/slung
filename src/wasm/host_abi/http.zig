const std = @import("std");
const zwasm = @import("zwasm");
const http = @import("dusty");
const Context = @import("../../engine/context.zig").Context;

const HeaderError = error{InvalidHeaders};

/// Header wire format:
/// [name length: u32][value length: u32][name bytes][value bytes]...
/// Lengths are little-endian and the complete buffer is length-delimited.
pub fn slung_http_get(ctx_ptr: *anyopaque, context: usize) !void {
    return urlRequest(ctx_ptr, context, .get);
}

pub fn slung_http_delete(ctx_ptr: *anyopaque, context: usize) !void {
    return urlRequest(ctx_ptr, context, .delete);
}

pub fn slung_http_put(ctx_ptr: *anyopaque, context: usize) !void {
    return bodyRequest(ctx_ptr, context, .put);
}

pub fn slung_http_post(ctx_ptr: *anyopaque, context: usize) !void {
    return bodyRequest(ctx_ptr, context, .post);
}

fn urlRequest(ctx_ptr: *anyopaque, context: usize, method: http.Method) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    const response_headers_len_addr = vm.popOperandU32();
    const response_headers_ptr_addr = vm.popOperandU32();
    const response_len_addr = vm.popOperandU32();
    const response_ptr_addr = vm.popOperandU32();
    const request_headers_len = vm.popOperandU32();
    const request_headers_ptr = vm.popOperandU32();
    const url_len = vm.popOperandU32();
    const url_ptr = vm.popOperandU32();

    const url = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(url);

    const request_headers = ctx.module.memoryRead(ctx.allocator, request_headers_ptr, request_headers_len) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(request_headers);

    return request(
        vm,
        ctx,
        method,
        url,
        request_headers,
        null,
        response_ptr_addr,
        response_len_addr,
        response_headers_ptr_addr,
        response_headers_len_addr,
    );
}

fn bodyRequest(ctx_ptr: *anyopaque, context: usize, method: http.Method) !void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const ctx: *Context = @ptrFromInt(context);

    const response_headers_len_addr = vm.popOperandU32();
    const response_headers_ptr_addr = vm.popOperandU32();
    const response_len_addr = vm.popOperandU32();
    const response_ptr_addr = vm.popOperandU32();
    const body_len = vm.popOperandU32();
    const body_ptr = vm.popOperandU32();
    const request_headers_len = vm.popOperandU32();
    const request_headers_ptr = vm.popOperandU32();
    const url_len = vm.popOperandU32();
    const url_ptr = vm.popOperandU32();

    const url = ctx.module.memoryRead(ctx.allocator, url_ptr, url_len) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(url);

    const request_headers = ctx.module.memoryRead(ctx.allocator, request_headers_ptr, request_headers_len) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(request_headers);

    const body = ctx.module.memoryRead(ctx.allocator, body_ptr, body_len) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(body);

    return request(
        vm,
        ctx,
        method,
        url,
        request_headers,
        body,
        response_ptr_addr,
        response_len_addr,
        response_headers_ptr_addr,
        response_headers_len_addr,
    );
}

fn request(
    vm: *zwasm.Vm,
    ctx: *Context,
    method: http.Method,
    url: []const u8,
    request_header_bytes: []const u8,
    body: ?[]const u8,
    response_ptr_addr: u32,
    response_len_addr: u32,
    response_headers_ptr_addr: u32,
    response_headers_len_addr: u32,
) !void {
    std.log.scoped(.slung).debug("Outbound HTTP request: {s} ({d} header bytes)", .{ url, request_header_bytes.len });

    const max_request_headers = request_header_bytes.len / 8;
    var request_headers = try http.Headers.init(ctx.allocator, max_request_headers);
    defer request_headers.deinit(ctx.allocator);
    parseHeaders(ctx.allocator, request_header_bytes, &request_headers) catch |err| {
        std.log.scoped(.slung).err("Outbound HTTP request headers could not be decoded: {}", .{err});
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };

    var client = http.Client.init(ctx.allocator, ctx.io, .{});
    defer client.deinit();

    var response = client.fetch(url, .{
        .method = method,
        .headers = &request_headers,
        .body = body,
    }) catch |err| {
        std.log.scoped(.slung).err("Outbound HTTP request failed: {}", .{err});
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer response.deinit();

    var response_body: std.ArrayList(u8) = .empty;
    defer response_body.deinit(ctx.allocator);
    if (response.body() catch |err| {
        std.log.scoped(.slung).err("Outbound HTTP response body could not be read: {}", .{err});
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    }) |data| {
        response_body.appendSlice(ctx.allocator, data) catch |err| {
            std.log.scoped(.slung).err("Outbound HTTP response body could not be buffered: {}", .{err});
            return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
        };
    }

    var response_header_bytes: std.ArrayList(u8) = .empty;
    defer response_header_bytes.deinit(ctx.allocator);
    encodeHeaders(ctx.allocator, response.headers(), &response_header_bytes) catch |err| {
        std.log.scoped(.slung).err("Outbound HTTP response headers could not be encoded: {}", .{err});
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };

    const response_body_owned = response_body.toOwnedSlice(ctx.allocator) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(response_body_owned);

    const response_headers_owned = response_header_bytes.toOwnedSlice(ctx.allocator) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    defer ctx.allocator.free(response_headers_owned);

    const response_guest_ptr = allocate(vm, ctx.module, response_body_owned) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };
    const response_headers_guest_ptr = allocate(vm, ctx.module, response_headers_owned) catch {
        return fail(vm, ctx.module, response_ptr_addr, response_len_addr, response_headers_ptr_addr, response_headers_len_addr);
    };

    try writeResult(ctx.module, response_ptr_addr, response_len_addr, response_guest_ptr, @intCast(response_body_owned.len));
    try writeResult(ctx.module, response_headers_ptr_addr, response_headers_len_addr, response_headers_guest_ptr, @intCast(response_headers_owned.len));
    try vm.pushOperand(@intCast(@intFromEnum(response.status())));
}

fn fail(
    vm: *zwasm.Vm,
    module: *zwasm.WasmModule,
    response_ptr_addr: u32,
    response_len_addr: u32,
    response_headers_ptr_addr: u32,
    response_headers_len_addr: u32,
) !void {
    try writeResult(module, response_ptr_addr, response_len_addr, 0, 0);
    try writeResult(module, response_headers_ptr_addr, response_headers_len_addr, 0, 0);
    try vm.pushOperand(0);
}

fn writeResult(module: *zwasm.WasmModule, ptr_addr: u32, len_addr: u32, ptr: u32, len: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, ptr, .little);
    try module.memoryWrite(ptr_addr, &bytes);
    std.mem.writeInt(u32, &bytes, len, .little);
    try module.memoryWrite(len_addr, &bytes);
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

fn parseHeaders(_: std.mem.Allocator, bytes: []const u8, headers: *http.Headers) HeaderError!void {
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 8) return error.InvalidHeaders;
        const name_len = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        const value_len = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
        cursor += 8;

        const name_end = std.math.add(usize, cursor, name_len) catch return error.InvalidHeaders;
        const value_end = std.math.add(usize, name_end, value_len) catch return error.InvalidHeaders;
        if (value_end > bytes.len) return error.InvalidHeaders;

        headers.put(bytes[cursor..name_end], bytes[name_end..value_end]) catch return error.InvalidHeaders;
        cursor = value_end;
    }
}

fn encodeHeaders(allocator: std.mem.Allocator, headers: *const http.Headers, output: *std.ArrayList(u8)) !void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(entry.key.len), .little);
        try output.appendSlice(allocator, &length);
        std.mem.writeInt(u32, &length, @intCast(entry.value.len), .little);
        try output.appendSlice(allocator, &length);
        try output.appendSlice(allocator, entry.key);
        try output.appendSlice(allocator, entry.value);
    }
}

pub fn appendHostFunctions(host_fns: *std.ArrayList(zwasm.HostFnEntry), allocator: std.mem.Allocator, context: usize) !void {
    try host_fns.append(allocator, .{ .name = "slung_http_get", .callback = slung_http_get, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_post", .callback = slung_http_post, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_put", .callback = slung_http_put, .context = context });
    try host_fns.append(allocator, .{ .name = "slung_http_delete", .callback = slung_http_delete, .context = context });
}

test "outbound HTTP connection failure returns transport status zero" {
    var client = http.Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    const result = client.fetch("http://127.0.0.1:1/", .{});
    if (result) |response| {
        var successful_response = response;
        defer successful_response.deinit();
        return error.UnexpectedSuccessfulRequest;
    } else |_| {}
}

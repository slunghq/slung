const std = @import("std");
const http = @import("dusty");
const zio = @import("zio");
const zware = @import("zware");
const AppContext = @import("../main.zig").AppContext;
const Query = @import("../query.zig").Query;
const QueryOp = @import("../tsm/tsm.zig").TsmTree.QueryOp;

pub fn initHostFunctions(store: *zware.Store, context_ptr: usize) !void {
    try store.exposeHostFunction("env", "u_poll_handle", u_poll_handle, context_ptr, &[_]zware.ValType{.I32}, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("env", "u_free_handle", u_free_handle, context_ptr, &[_]zware.ValType{.I32}, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("env", "u_query_live", u_query_live, context_ptr, &[_]zware.ValType{.I32}, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("env", "u_query_history", u_query_history, context_ptr, &[_]zware.ValType{.I32}, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("env", "u_write_event", u_write_event, context_ptr, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{.I32});
    // done
    try store.exposeHostFunction("env", "u_writeback_http", u_writeback_http, context_ptr, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{.I32});
    // done
    try store.exposeHostFunction("env", "u_writeback_ws", u_writeback_ws, context_ptr, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{.I32});

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_write", zware.wasi.fd_write, 0, &[_]zware.ValType{ .I32, .I32, .I32, .I32 }, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("wasi_snapshot_preview1", "environ_get", zware.wasi.environ_get, 0, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("wasi_snapshot_preview1", "environ_sizes_get", zware.wasi.environ_sizes_get, 0, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{.I32});
    try store.exposeHostFunction("wasi_snapshot_preview1", "proc_exit", zware.wasi.proc_exit, 0, &[_]zware.ValType{.I32}, &[_]zware.ValType{});
}

pub fn u_poll_handle(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    const handle = vm.popOperand(u32);

    context.server.connections_mutex.lock();
    const event = context.server.query_events.fetchRemove(handle);
    context.server.connections_mutex.unlock();

    if (event == null) {
        zio.yield() catch {};
        try vm.pushOperand(u32, 0);
        return;
    }

    const json_bytes = pollEventJson(context.io.allocator, event.?.value) catch {
        try vm.pushOperand(u32, 0);
        return;
    };
    defer context.io.allocator.free(json_bytes);

    const memory = try vm.inst.getMemory(0);
    var api = Api.init(vm.inst);
    const region_ptr = allocateAndWriteRegion(&api, memory, json_bytes) catch {
        try vm.pushOperand(u32, 0);
        return;
    };

    try vm.pushOperand(u32, region_ptr);
}

pub fn u_free_handle(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    const handle = vm.popOperand(u32);
    if (!context.server.queries.remove(handle)) {
        try vm.pushOperand(u64, 1);
        return;
    }
    try vm.pushOperand(u64, 0);
}

pub fn u_query_live(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    const filter_ptr = vm.popOperand(u32);

    const memory = try vm.inst.getMemory(0);
    const filter_bytes = try readRegion(memory, filter_ptr);

    const query_id = context.server.next_query_id.fetchAdd(1, .monotonic);
    const query = Query.init(filter_bytes) catch {
        try vm.pushOperand(u64, 0);
        return;
    };
    context.server.queries.put(query_id, query) catch {
        try vm.pushOperand(u64, 0);
        return;
    };

    try vm.pushOperand(u64, query_id);
}

pub fn u_query_history(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    const filter_ptr = vm.popOperand(u32);

    const memory = try vm.inst.getMemory(0);
    const filter_bytes = try readRegion(memory, filter_ptr);

    const query = Query.init(filter_bytes) catch {
        try vm.pushOperand(u64, 0);
        return;
    };
    var op: QueryOp = undefined;
    switch (query.op) {
        .Avg => {
            op = QueryOp.AVG;
        },
        .Sum => {
            op = QueryOp.SUM;
        },
        .Max => {
            op = QueryOp.MAX;
        },
        .Min => {
            op = QueryOp.MIN;
        },
        .Count => {
            op = QueryOp.COUNT;
        },
        .None => {
            try vm.pushOperand(u64, 0);
            return;
        },
    }

    const series_key = buildQuerySeriesKey(context.io.allocator, &query) catch {
        try vm.pushOperand(u64, 0);
        return;
    };
    defer context.io.allocator.free(series_key);

    const value = context.server.tree.query(series_key, query.time_start, query.time_end, op) catch {
        try vm.pushOperand(u64, 0);
        return;
    };

    try vm.pushOperand(f64, value.Float);
}

pub fn u_write_event(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    _ = context;
    const param2 = vm.popOperand(i32);
    const param1 = vm.popOperand(i32);
    const param0 = vm.popOperand(i32);
    std.debug.print("Unimplemented: u_writeback_http({}, {}, {})\n", .{ param0, param1, param2 });
    try vm.pushOperand(u64, 0);
    @panic("Unimplemented: u_writeback_ws");
}

pub fn u_writeback_http(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);
    var client = http.Client.init(context.io.allocator, .{});
    defer client.deinit();

    const method = vm.popOperand(u32);
    const data_ptr = vm.popOperand(u32);
    const url_ptr = vm.popOperand(u32);

    const memory = try vm.inst.getMemory(0);

    const url_bytes = try readRegion(memory, url_ptr);
    const data_bytes = try readRegion(memory, data_ptr);

    switch (method) {
        0 => {
            try sendHttp(vm, memory, &client, url_bytes, data_bytes, .get);
        },
        1 => {
            try sendHttp(vm, memory, &client, url_bytes, data_bytes, .post);
        },
        2 => {
            try sendHttp(vm, memory, &client, url_bytes, data_bytes, .put);
        },
        3 => {
            try sendHttp(vm, memory, &client, url_bytes, data_bytes, .delete);
        },
        else => {
            try vm.pushOperand(u32, 0);
            return;
        },
    }
}

fn sendHttp(vm: *zware.VirtualMachine, memory: *zware.Memory, client: *http.Client, url_bytes: []const u8, data_bytes: []const u8, method: http.Method) zware.WasmError!void {
    var response = client.fetch(url_bytes, .{ .body = data_bytes, .method = method }) catch return;
    defer response.deinit();
    if (response.body() catch return) |body| {
        var api = Api.init(vm.inst);
        const response_ptr = allocateAndWriteRegion(&api, memory, body) catch return;
        try vm.pushOperand(u32, response_ptr);
    } else {
        try vm.pushOperand(u32, 0);
    }
}

pub fn u_writeback_ws(vm: *zware.VirtualMachine, context_ptr: usize) zware.WasmError!void {
    const context: *AppContext = @ptrFromInt(context_ptr);

    const data_ptr = vm.popOperand(u32);
    const producer = vm.popOperand(u64);

    const memory = try vm.inst.getMemory(0);

    const data_bytes = try readRegion(memory, data_ptr);

    if (context.server.connections.get(producer)) |connection| {
        connection.send(.text, data_bytes) catch {
            context.server.connections_mutex.lock();
            defer context.server.connections_mutex.unlock();
            _ = context.server.connections.remove(producer);
            try vm.pushOperand(u32, 1);
            return;
        };
    } else {
        try vm.pushOperand(u32, 1);
        return;
    }

    try vm.pushOperand(u32, 0);
}

pub const PollState = union(enum) {
    Sum: f64,
    Min: f64,
    Max: f64,
    Avg: struct {
        sum: f64,
        count: u64,
    },
    Count: u64,
    None: void,
};

fn buildQuerySeriesKey(allocator: std.mem.Allocator, query: *const Query) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, query.series);
    for (query.tagsSlice()) |token| {
        switch (token) {
            .tag => |tag| {
                if (tag.len == 0) continue;
                try out.append(allocator, ',');
                try out.appendSlice(allocator, tag);
            },
            .op => {},
        }
    }

    return out.toOwnedSlice(allocator);
}

fn pollEventJson(allocator: std.mem.Allocator, event: anytype) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"timestamp\":{},\"value\":{d},\"tags\":[],\"producers\":[{}]}}",
        .{ event.timestamp, event.value, event.producer },
    );
}

/// Helper to read a Region from guest memory and get the data slice
fn readRegion(memory: *zware.Memory, region_ptr: u32) ![]const u8 {
    const data = memory.memory();

    // Read Region struct: { offset: u32, capacity: u32, length: u32 }
    const offset = try memory.read(u32, region_ptr, 0);
    const length = try memory.read(u32, region_ptr, 8);

    return data[offset .. offset + length];
}

/// Helper to allocate a Region in guest memory and write data to it
fn allocateAndWriteRegion(api: *Api, memory: *zware.Memory, data_bytes: []const u8) !u32 {
    const data_offset: u32 = @intCast(try api.allocate(@intCast(data_bytes.len)));

    // Write the data to guest memory
    for (data_bytes, 0..) |byte, i| {
        try memory.write(u8, data_offset + @as(u32, @intCast(i)), 0, byte);
    }

    // Allocate space for the Region struct (12 bytes)
    const region_ptr: u32 = @intCast(try api.allocate(12));

    // Write the Region struct: { offset, capacity, length }
    try memory.write(u32, region_ptr, 0, data_offset);
    try memory.write(u32, region_ptr, 4, @intCast(data_bytes.len));
    try memory.write(u32, region_ptr, 8, @intCast(data_bytes.len));

    return region_ptr;
}

pub const Api = struct {
    instance: *zware.Instance,

    const Self = @This();

    pub fn init(instance: *zware.Instance) Self {
        return .{ .instance = instance };
    }

    pub fn _start(self: *Self) !void {
        var in = [_]u64{};
        var out = [_]u64{};
        try self.instance.invoke("_start", in[0..], out[0..], .{});
    }

    pub fn __main_void(self: *Self) !i32 {
        var in = [_]u64{};
        var out = [_]u64{0};
        try self.instance.invoke("__main_void", in[0..], out[0..], .{});
        return @bitCast(@as(u32, @truncate(out[0])));
    }

    pub fn allocate(self: *Self, param0: i32) !i32 {
        var in = [_]u64{@bitCast(@as(i64, param0))};
        var out = [_]u64{0};
        try self.instance.invoke("allocate", in[0..], out[0..], .{});
        return @bitCast(@as(u32, @truncate(out[0])));
    }

    pub fn deallocate(self: *Self, param0: i32) !void {
        var in = [_]u64{@bitCast(@as(i64, param0))};
        var out = [_]u64{};
        try self.instance.invoke("deallocate", in[0..], out[0..], .{});
    }
};

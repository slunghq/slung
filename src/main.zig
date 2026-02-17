const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const testing = std.testing;
const ds = @import("ds/ds.zig");
const tsm = @import("tsm/tsm.zig");
const query = @import("query.zig");
const net = std.net;
const execute = @import("host/execute.zig");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Channel = zio.Channel;
const Query = query.Query;
const TsmTree = tsm.TsmTree;
const CHANNEL_CAPACITY = 8192 * 2;

pub const AppContext = struct {
    io: *zio.Runtime,
    server: *Server,
};

// rn we'll be making this single-instance
// so we don't need to hold any extra server data
const Server = struct {
    const max_queries = 16;
    const PendingEvent = struct {
        timestamp: i64,
        value: f64,
        producer: u64,
    };

    allocator: std.mem.Allocator,
    connections: Connections,
    connections_mutex: std.Thread.Mutex,
    next_connection_id: std.atomic.Value(u64),
    channel: *Channel(ChannelData),
    queries: AutoHashMap(u32, Query),
    query_events: AutoHashMap(u32, PendingEvent),
    series_key_cache: std.StringArrayHashMap([]const u8),
    next_query_id: std.atomic.Value(u32),
    tree: *TsmTree,

    const ChannelData = struct {
        /// to be used as id if not streamed with data
        id: u64,
        data: []const u8,
    };
    const Connections = AutoHashMap(u64, *http.WebSocket);

    pub fn init(
        context: *AppContext,
        channel: *Channel(ChannelData),
        tree: *TsmTree,
    ) !Server {
        return Server{
            .allocator = context.io.allocator,
            .connections = Connections.init(context.io.allocator),
            .connections_mutex = .{},
            .next_connection_id = std.atomic.Value(u64).init(1),
            .channel = channel,
            .queries = AutoHashMap(u32, Query).init(context.io.allocator),
            .query_events = AutoHashMap(u32, PendingEvent).init(context.io.allocator),
            .series_key_cache = std.StringArrayHashMap([]const u8).init(context.io.allocator),
            .next_query_id = std.atomic.Value(u32).init(1),
            .tree = tree,
        };
    }

    pub fn deinit(self: *Server) void {
        var iter_series = self.series_key_cache.iterator();
        while (iter_series.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.series_key_cache.deinit();
        self.connections.deinit();
        self.queries.deinit();
        self.query_events.deinit();
    }

    pub fn internSeriesKey(self: *Server, key_bytes: []const u8) ![]const u8 {
        const entry = try self.series_key_cache.getOrPut(key_bytes);
        if (entry.found_existing) return entry.value_ptr.*;

        const owned = try self.allocator.dupe(u8, key_bytes);
        entry.key_ptr.* = owned;
        entry.value_ptr.* = owned;
        return owned;
    }

    pub fn addConnection(self: *Server, websocket: *http.WebSocket) !u64 {
        const id = self.next_connection_id.fetchAdd(1, .monotonic);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        try self.connections.put(id, websocket);

        return id;
    }

    pub fn removeConnection(self: *Server, id: u64) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        _ = self.connections.remove(id);
    }
};

fn handleMessage(msg: http.WebSocket.Message, id: u64, context: *AppContext) !void {
    const message = Server.ChannelData{
        .id = id,
        .data = msg.data,
    };
    context.server.channel.send(message) catch |err| switch (err) {
        error.ChannelClosed => {
            std.log.debug("Producer {}: channel closed, exiting", .{id});
            return;
        },
        error.Canceled => {
            std.log.debug("Producer {}: canceled, exiting", .{id});
            return;
        },
    };
}

fn handleWebSocket(context: *AppContext, req: *http.Request, res: *http.Response) !void {
    var websocket = try res.upgradeWebSocket(req) orelse {
        try handleIndexPost(context, req, res);
        return;
    };
    const id = try context.server.addConnection(&websocket);
    errdefer websocket.close(.internal_error, "handler error") catch {};
    errdefer context.server.removeConnection(id);
    defer context.server.removeConnection(id);

    while (true) {
        const msg = websocket.receive() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (msg.type) {
            .text => {
                handleMessage(msg, id, context) catch return;
            },
            .binary => {
                handleMessage(msg, id, context) catch return;
            },
            .close => {
                std.log.info("Client closed connection", .{});
                break;
            },
            else => {},
        }
    }
}

fn handleHealth(_: *AppContext, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.body =
        \\{
        \\ "status": "ok",
        \\}
    ;
}

fn handleIndexPost(_: *AppContext, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.status = .bad_request;
    res.body =
        \\{
        \\ "status": "ok",
        \\ "info": "use websocket to stream data!"
        \\}
    ;
}

pub fn runServer(allocator: std.mem.Allocator, context: *AppContext) !void {
    var server = http.Server(AppContext).init(allocator, .{}, context);
    defer server.deinit();

    server.router.get("/", handleWebSocket);
    server.router.post("/", handleIndexPost);
    server.router.get("/health", handleHealth);

    const addr = try zio.net.IpAddress.parseIp("0.0.0.0", 2077);

    std.log.info("Slung server listening on http://0.0.0.0:2077", .{});
    try server.listen(addr);
}

pub fn handleWasm(allocator: std.mem.Allocator, context: *AppContext) !void {
    const bytes = @embedFile("basic.wasm");
    const context_ptr = @intFromPtr(context);
    try execute.spawn(allocator, bytes, context_ptr);
}

const Message = struct {
    timestamp: i64,
    value: f64,
    series: []const u8,
    tags: []const []const u8 = &.{},
};

fn writeSeriesKey(out: *std.ArrayList(u8), allocator: std.mem.Allocator, series: []const u8, tags: []const []const u8) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(allocator, series);
    for (tags) |tag| {
        if (tag.len == 0) continue;
        try out.append(allocator, ',');
        try out.appendSlice(allocator, tag);
    }
}

fn handleWasmWebsocket(context: *AppContext) !void {
    var parse_arena = std.heap.ArenaAllocator.init(context.io.allocator);
    defer parse_arena.deinit();

    var key_scratch = std.ArrayList(u8).empty;
    defer key_scratch.deinit(context.io.allocator);

    while (true) {
        var recv = context.server.channel.asyncReceive();
        const result = try zio.select(.{ .recv = &recv });
        switch (result) {
            .recv => |val| {
                const value = try val;
                const parsed_message = std.json.parseFromSlice(Message, parse_arena.allocator(), value.data, .{}) catch |err| {
                    std.log.warn("Ignoring websocket payload; expected JSON {{\"value\":...,\"timestamp\":...,\"series\":\"...\",\"tags\":[...]}}: {}", .{err});
                    _ = parse_arena.reset(.retain_capacity);
                    continue;
                };
                defer parsed_message.deinit();
                const message = parsed_message.value;
                try writeSeriesKey(&key_scratch, context.io.allocator, message.series, message.tags);
                const series_key = try context.server.internSeriesKey(key_scratch.items);
                try context.server.tree.insert(series_key, .{
                    .timestamp = message.timestamp,
                    .value = .{ .Float = message.value },
                });

                context.server.connections_mutex.lock();
                defer context.server.connections_mutex.unlock();

                var iter_queries = context.server.queries.iterator();
                while (iter_queries.next()) |entry| {
                    const query_id = entry.key_ptr.*;
                    const q = entry.value_ptr;
                    if (!std.mem.eql(u8, q.series, message.series)) {
                        continue;
                    }

                    switch (q.op) {
                        .Avg => {
                            q.*.op.Avg.count += 1;
                            q.*.op.Avg.sum += message.value;
                        },
                        .Sum => {
                            q.*.op.Sum += message.value;
                        },
                        .Count => {
                            q.*.op.Count += 1;
                        },
                        .Max => {},
                        .Min => {},
                        .None => {},
                    }

                    context.server.query_events.put(query_id, .{
                        .timestamp = message.timestamp,
                        .value = message.value,
                        .producer = value.id,
                    }) catch {};
                }
                _ = parse_arena.reset(.retain_capacity);
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = try zio.Runtime.init(allocator, .{});
    defer io.deinit();

    var group: zio.Group = .init;
    defer group.cancel();

    var context: AppContext = .{
        .io = io,
        .server = undefined,
    };

    const channel_buffer = try allocator.alloc(Server.ChannelData, CHANNEL_CAPACITY);
    defer allocator.free(channel_buffer);
    var channel = Channel(Server.ChannelData).init(channel_buffer[0..]);

    var tree = try TsmTree.init(allocator, "demo");
    defer tree.deinit();

    var server = try Server.init(&context, &channel, &tree);
    context.server = &server;
    defer server.deinit();

    try group.spawn(handleWasmWebsocket, .{&context});
    try group.spawn(handleWasm, .{ allocator, &context });
    try group.spawn(runServer, .{ allocator, &context });

    try group.wait();
}

test {
    _ = ds;
    _ = tsm;
    _ = query;
}

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

pub const AppContext = struct {
    io: *zio.Runtime,
    server: *Server,
};

// rn we'll be making this single-instance
// so we don't need to hold any extra server data
const Server = struct {
    const max_queries = 16;
    connections: Connections,
    connections_mutex: std.Thread.Mutex,
    next_connection_id: std.atomic.Value(u64),
    channel: *Channel(ChannelData),
    queries: AutoHashMap(u32, Query),
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
            .connections = Connections.init(context.io.allocator),
            .connections_mutex = .{},
            .next_connection_id = std.atomic.Value(u64).init(1),
            .channel = channel,
            .queries = AutoHashMap(u32, Query).init(context.io.allocator),
            .next_query_id = std.atomic.Value(u32).init(1),
            .tree = tree,
        };
    }

    pub fn deinit(self: *Server) void {
        self.connections.deinit();
        self.queries.deinit();
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

// TODO: handle Wasm
pub fn spawnWasm(allocator: std.mem.Allocator, context: *AppContext) !void {
    const bytes = @embedFile("basic.wasm");
    const context_ptr = @intFromPtr(context);
    _ = try zio.spawn(handleWasmWebsocket, .{ context, &context.server.queries });
    try execute.spawn(allocator, bytes, context_ptr);
}

const Message = struct {
    timestamp: i64,
    value: f64,
    series: []const u8,
    id: u64,
};

fn handleWasmWebsocket(context: *AppContext, queries: *AutoHashMap(u32, Query)) !void {
    while (true) {
        var recv = context.server.channel.asyncReceive();
        const result = try zio.select(.{ .recv = &recv });
        switch (result) {
            .recv => |val| {
                const value = try val;
                std.log.debug("data: {s}", .{value.data});

                context.server.connections_mutex.lock();
                defer context.server.connections_mutex.unlock();

                var iter_queries = queries.valueIterator();
                while (iter_queries.next()) |q| {
                    const parsed_message = try std.json.parseFromSlice(Message, context.io.allocator, value.data, .{});
                    defer parsed_message.deinit();
                    const message = parsed_message.value;
                    if (std.mem.eql(u8, message.series, q.series)) {
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
                    }
                }
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

    var channel = Channel(Server.ChannelData).init(&[_]Server.ChannelData{});

    var tree = try TsmTree.init(allocator, "demo");
    defer tree.deinit();

    var server = try Server.init(&context, &channel, &tree);
    context.server = &server;
    defer server.deinit();

    try group.spawn(spawnWasm, .{ allocator, &context });
    try group.spawn(runServer, .{ allocator, &context });

    try group.wait();
}

test {
    _ = ds;
    _ = tsm;
    _ = query;
}

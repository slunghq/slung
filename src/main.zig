const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const testing = std.testing;
const ds = @import("ds/ds.zig");
const tsm = @import("tsm/tsm.zig");
const net = std.net;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Channel = zio.Channel;
const SkipList = ds.skiplist.SkipList;

const AppContext = struct {
    io: *zio.Runtime,
    server: *Server,
};

// rn we'll be making this single-instance
// so we don't need to hold any extra server data
const Server = struct {
    connections: Connections,
    connections_mutex: std.Thread.Mutex,
    next_connection_id: std.atomic.Value(u64),
    channel: *Channel(ChannelData),

    const ChannelData = struct {
        /// to be used as id if not streamed with data
        id: []const u8,
        data: []const u8,
    };
    const Connections = AutoHashMap(u64, *http.WebSocket);

    pub fn init(
        context: *AppContext,
        channel: *Channel(ChannelData),
    ) !Server {
        return Server{
            .connections = Connections.init(context.io.allocator),
            .connections_mutex = .{},
            .next_connection_id = std.atomic.Value(u64).init(1),
            .channel = channel,
        };
    }

    pub fn deinit(self: *Server) void {
        self.connections.deinit();
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
        .id = try std.fmt.allocPrint(context.io.allocator, "{d}", .{id}),
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
pub fn spawnWasm(_: std.mem.Allocator, context: *AppContext) !void {
    // this while loop will be run within the host functions via zio.spawn
    // we have access to every websocket connection as well as a channel of their stream
    // we use a channel over polling on the connections to prevent misbehaviour
    while (true) {
        var recv = context.server.channel.asyncReceive();
        const result = try zio.select(.{ .recv = &recv });
        switch (result) {
            .recv => |val| {
                const value = try val;
                std.log.debug("data: {s}", .{value.data});

                context.server.connections_mutex.lock();
                defer context.server.connections_mutex.unlock();

                var websocket_iter = context.server.connections.iterator();
                while (websocket_iter.next()) |entry| {
                    const websocket = entry.value_ptr.*;
                    const id = try std.fmt.allocPrint(context.io.allocator, "{d}", .{entry.key_ptr.*});
                    if (!std.mem.eql(u8, id, value.id)) try websocket.send(.text, value.data);
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

    var server = try Server.init(&context, &channel);
    context.server = &server;
    defer server.deinit();

    try group.spawn(spawnWasm, .{ allocator, &context });
    try group.spawn(runServer, .{ allocator, &context });

    try group.wait();
}

test {
    _ = ds;
    _ = tsm;
}

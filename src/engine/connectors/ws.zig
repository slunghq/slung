const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMapUnmanaged;
const StringHashMap = std.StringHashMapUnmanaged;

const http = @import("dusty");

const Arc = @import("../../primitives/arc.zig").Arc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;
const Source = @import("shared.zig").Source;

pub const WebSocketServerConnection = struct {
    allocator: Allocator,
    namespace: []const u8,
    server: *Server,

    pub fn init(allocator: Allocator, server: *Server, namespace: []const u8) !WebSocketServerConnection {
        return .{
            .allocator = allocator,
            .namespace = try allocator.dupe(u8, namespace),
            .server = server,
        };
    }

    pub fn deinit(self: *WebSocketServerConnection) void {
        self.allocator.free(self.namespace);
    }

    pub fn listen(self: *WebSocketServerConnection, source_key: []const u8, source: Arc(Mutex(Source(Server.ChannelData)))) !void {
        const route_key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key });
        errdefer self.allocator.free(route_key);

        const source_clone = source.clone();
        errdefer source_clone.release();

        try self.server.routes_mutex.lock(self.server.io);
        defer self.server.routes_mutex.unlock(self.server.io);
        try self.server.routes.put(self.allocator, route_key, source_clone);
    }

    pub fn close(self: *WebSocketServerConnection, source_key: []const u8) !void {
        const route_key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key }) catch return;
        defer self.allocator.free(route_key);

        try self.server.routes_mutex.lock(self.server.io);
        defer self.server.routes_mutex.unlock(self.server.io);
        if (self.server.routes.fetchRemove(route_key)) |kv| {
            self.allocator.free(kv.key);
            kv.value.release(); // Release the Arc to decrement its ref count
        }
    }
};

pub const WebSocketClient = struct {
    allocator: Allocator,
    url: []const u8,

    pub fn init(allocator: Allocator, url: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
        };
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.allocator.free(self.url);
    }

    pub fn connect(self: *WebSocketClient) !void {
        _ = self;
        // TODO: Implement WebSocket connection
        // Should:
        //   - Parse URL to extract host/port/path
        //   - Open TCP connection
        //   - Perform WebSocket handshake
        //   - Store connection state
    }

    pub fn next(self: *WebSocketClient) !?[]u8 {
        _ = self;
        // TODO: Implement WebSocket message polling
        // Should:
        //   - Check if data available on connection
        //   - Read message frame
        //   - Return raw payload or null if none
        return null;
    }

    pub fn close(self: *WebSocketClient) void {
        // TODO: Close WebSocket connection
        _ = self;
    }
};

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    connections: Connections = .empty,
    connections_mutex: std.Io.Mutex = std.Io.Mutex.init,
    next_connection_id: std.atomic.Value(u64),
    config: Config = .{ .port = 2073 },
    routes: Routes = .empty,
    routes_mutex: std.Io.Mutex = std.Io.Mutex.init,

    const Connections = AutoHashMap(u64, *http.WebSocket);
    pub const ChannelData = struct {
        client_id: u64,
        data: []const u8,
    };
    pub const Config = struct {
        port: u16,
    };
    const Routes = StringHashMap(Arc(Mutex(Source(ChannelData))));

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Server {
        return Server{
            .allocator = allocator,
            .io = io,
            .next_connection_id = std.atomic.Value(u64).init(0),
            .config = config,
        };
    }

    pub fn deinit(self: *Server) void {
        var routes_iter = self.routes.iterator();
        while (routes_iter.next()) |entry| {
            entry.value_ptr.release(); // Release the Arc
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit(self.allocator);
        self.routes.deinit(self.allocator);
    }

    pub fn serve(self: *Server) !void {
        var server = http.Server(Server).init(self.allocator, self.io, .{}, self);
        defer server.deinit();

        server.router.get("/", handleIndex);
        server.router.post("/", handleIndex);
        server.router.get("/*path", serverDynamicDispatch);
        server.router.post("/*path", serverDynamicDispatch);

        const ip = try std.Io.net.IpAddress.parse("0.0.0.0", self.config.port);
        const addr: http.Address = .{ .ip = ip };

        std.log.info("WebSocket gateway listening on http://0.0.0.0:{d}", .{self.config.port});
        try server.listen(addr);
    }

    pub fn addConnection(self: *Server, websocket: *http.WebSocket) !u64 {
        const id = self.next_connection_id.fetchAdd(1, .monotonic);

        try self.connections_mutex.lock(self.io);
        defer self.connections_mutex.unlock(self.io);
        try self.connections.put(self.allocator, id, websocket);

        return id;
    }

    pub fn removeConnection(self: *Server, id: u64) !void {
        try self.connections_mutex.lock(self.io);
        defer self.connections_mutex.unlock(self.io);
        _ = self.connections.remove(id);
    }
};

fn serverDynamicDispatch(context: *Server, req: *http.Request, res: *http.Response) !void {
    var websocket = try res.upgradeWebSocket(req) orelse {
        if (std.mem.endsWith(u8, req.url, "/health")) try handleHealth(res) else try handleIndex(context, req, res);
        return;
    };
    const id = try context.addConnection(&websocket);
    errdefer websocket.close(.internal_error, "handler error") catch {};
    errdefer context.removeConnection(id) catch {};
    defer context.removeConnection(id) catch {};

    const route_path = if (std.mem.startsWith(u8, req.url, "/")) req.url[1..] else req.url;

    var source_arc_opt: ?Arc(Mutex(Source(Server.ChannelData))) = null;
    try context.routes_mutex.lock(context.io);
    if (context.routes.get(route_path)) |s_arc| {
        source_arc_opt = s_arc.clone();
    }
    context.routes_mutex.unlock(context.io);

    const source_arc = source_arc_opt orelse {
        std.log.info("route not registered: {s}", .{route_path});
        websocket.close(.policy_violation, "route not registered") catch {};
        return;
    };
    defer source_arc.release();

    while (true) {
        const msg = websocket.receive() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (msg.type) {
            .text => {
                const message = Server.ChannelData{
                    .client_id = id,
                    .data = msg.data,
                };
                const guard = source_arc.getMut().lock();
                defer guard.deinit();
                try guard.get().write(message);
            },
            .binary => {
                const message = Server.ChannelData{
                    .client_id = id,
                    .data = msg.data,
                };
                const guard = source_arc.getMut().lock();
                defer guard.deinit();
                try guard.get().write(message);
            },
            .close => {
                std.log.info("Client closed connection", .{});
                break;
            },
            .pong => {},
            else => {},
        }
    }
}

fn handleIndex(_: *Server, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.status = .bad_request;
    res.body =
        \\{
        \\ "status": "bad request",
        \\ "info": "use websocket binary frames to stream data"
        \\}
    ;
}

fn handleHealth(res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.body =
        \\{
        \\ "status": "ok"
        \\}
    ;
}

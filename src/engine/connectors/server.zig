const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMapUnmanaged;
const StringHashMap = std.StringHashMapUnmanaged;

const http = @import("dusty");
const zio = @import("zio");
const Source = @import("ws.zig").Source;
const Arc = @import("../../primitives/arc.zig").Arc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;

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

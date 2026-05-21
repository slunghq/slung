const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMapUnmanaged;

const http = @import("dusty");

const Arc = @import("../../primitives/arc.zig").Arc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;
const types = @import("../../types.zig");
const LwwRegistry = @import("../../memory/lww.zig").LwwRegistry;
const Hlc = @import("../../primitives/hlc.zig").Hlc;
const DirtyQueue = @import("../../queue.zig").DirtyQueue;

pub fn Source(D: type) type {
    return struct {
        allocator: Allocator,
        namespace: []const u8,
        node_id: types.NodeId,
        entity_id: types.EntityId,
        component_id: types.ComponentId,
        lww_store: Arc(Mutex(LwwRegistry)),
        dirty_queue: Arc(Mutex(DirtyQueue)),
        clock: *Hlc,
        data: ?D = null,

        const Self = @This();

        pub fn write(self: *Self, data: D) !void {
            self.data = data;
        }
    };
}

pub const HTTPServerConnection = struct {
    allocator: Allocator,
    namespace: []const u8,
    server: *Server,

    pub fn init(allocator: Allocator, server: *Server, namespace: []const u8) !HTTPServerConnection {
        return .{
            .allocator = allocator,
            .namespace = try allocator.dupe(u8, namespace),
            .server = server,
        };
    }

    pub fn deinit(self: *HTTPServerConnection) void {
        self.allocator.free(self.namespace);
    }

    pub fn listen(self: *HTTPServerConnection, source_key: []const u8, source: Arc(Mutex(Source(Server.RequestBody)))) !void {
        const route_key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key });
        errdefer self.allocator.free(route_key);

        const source_clone = source.clone();
        errdefer source_clone.release();

        try self.server.sources_mutex.lock(self.server.io);
        defer self.server.sources_mutex.unlock(self.server.io);
        try self.server.sources.put(self.allocator, route_key, source_clone);
    }

    pub fn close(self: *HTTPServerConnection, source_key: []const u8) !void {
        const route_key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key }) catch return;
        defer self.allocator.free(route_key);

        try self.server.sources_mutex.lock(self.server.io);
        defer self.server.sources_mutex.unlock(self.server.io);
        if (self.server.sources.fetchRemove(route_key)) |kv| {
            self.allocator.free(kv.key);
            kv.value.release(); // Release the Arc to decrement its ref count
        }
    }
};

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config = .{ .port = 2074 },
    sources: Sources = .empty,
    sources_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub const RequestBody = struct {
        data: []u8,
    };

    pub const Config = struct {
        port: u16,
    };

    const Sources = StringHashMap(Arc(Mutex(Source(RequestBody))));

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Server {
        return Server{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *Server) void {
        var sources_iter = self.sources.iterator();
        while (sources_iter.next()) |entry| {
            entry.value_ptr.release(); // Release the Arc
            self.allocator.free(entry.key_ptr.*);
        }
        self.sources.deinit(self.allocator);
    }

    pub fn serve(self: *Server) !void {
        var server = http.Server(Server).init(self.allocator, self.io, .{}, self);
        defer server.deinit();

        server.router.get("/", handleIndex);
        server.router.post("/*path", serverDynamicDispatch);
        server.router.get("/*path", handleIndex);

        const ip = try std.Io.net.IpAddress.parse("0.0.0.0", self.config.port);
        const addr: http.Address = .{ .ip = ip };

        std.log.info("HTTP webhook listener on http://0.0.0.0:{d}", .{self.config.port});
        try server.listen(addr);
    }
};

fn serverDynamicDispatch(context: *Server, req: *http.Request, res: *http.Response) !void {
    const route_path = if (std.mem.startsWith(u8, req.url, "/")) req.url[1..] else req.url;

    var source_arc_opt: ?Arc(Mutex(Source(Server.RequestBody))) = null;
    try context.sources_mutex.lock(context.io);
    if (context.sources.get(route_path)) |s_arc| {
        source_arc_opt = s_arc.clone();
    }
    context.sources_mutex.unlock(context.io);

    if (source_arc_opt) |source_arc| {
        defer source_arc.release();

        if (try req.body()) |body| {
            // Make a copy of the body since the request buffer may be reused
            const body_copy = try context.allocator.alloc(u8, body.len);
            @memcpy(body_copy, body);
            errdefer context.allocator.free(body_copy);

            const request = Server.RequestBody{
                .data = body_copy,
            };

            const guard = source_arc.getMut().lock();
            defer guard.deinit();
            try guard.get().write(request);

            // Respond with 200 OK
            try res.header("Content-Type", "application/json");
            res.status = .ok;
            res.body =
                \\{
                \\ "status": "received"
                \\}
            ;
        } else {
            // No body in request
            try res.header("Content-Type", "application/json");
            res.status = .bad_request;
            res.body =
                \\{
                \\ "status": "error",
                \\ "message": "empty request body"
                \\}
            ;
        }
    } else {
        std.log.info("http webhook route not registered: {s}", .{route_path});
        try res.header("Content-Type", "application/json");
        res.status = .not_found;
        res.body =
            \\{
            \\ "status": "error",
            \\ "message": "webhook route not found"
            \\}
        ;
    }
}

fn handleIndex(_: *Server, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.status = .bad_request;
    res.body =
        \\{
        \\ "status": "bad request",
        \\ "info": "post json to register webhook routes"
        \\}
    ;
}

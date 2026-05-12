const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("server.zig").Server;
const types = @import("../../types.zig");
const Arc = @import("../../primitives/arc.zig").Arc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;
const Hlc = @import("../../primitives/hlc.zig").Hlc;
const LwwRegistry = @import("../../memory/lww.zig").LwwRegistry;
const DirtyQueue = @import("../../queue.zig").DirtyQueue;

pub fn Source(D: type) type {
    return struct {
        allocator: Allocator,
        namespace: types.NamespaceId,
        node_id: types.NodeId,
        entity_id: types.EntityId,
        component_id: types.ComponentId,
        lww_store: Arc(Mutex(LwwRegistry)),
        dirty_queue: Arc(Mutex(DirtyQueue)),
        clock: *Hlc,
        data: ?D = null,

        const Self = @This();

        pub fn write(self: *Self, data: D, payload: []const u8) !void {
            self.data = data;

            const parsed_generic = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
                return;
            };
            defer parsed_generic.deinit();

            var parsed_value: types.Value = undefined;
            switch (parsed_generic.value) {
                .bool => |b| parsed_value = .{ .Bool = b },
                .integer => |i| parsed_value = .{ .Int = i },
                .float => |f| parsed_value = .{ .Float = f },
                .string => |s| parsed_value = .{ .Bytes = s },
                else => parsed_value = .{ .Bytes = payload },
            }

            const ts = self.clock.*.send();
            const cause = types.CausalTag{
                .cause = self.component_id,
                .entity = self.entity_id,
                .node = self.node_id,
            };

            var key_buf: [512]u8 = undefined;
            const key_str = std.fmt.bufPrintZ(&key_buf, "{s}:{d}:{d}", .{
                self.namespace,
                self.entity_id,
                self.component_id,
            }) catch return;

            var store_guard = self.lww_store.getMut().lock();
            defer store_guard.deinit();
            const store = store_guard.get();

            const accepted = store.put(key_str, ts, parsed_value, cause) catch return;

            if (accepted) {
                var queue_guard = self.dirty_queue.getMut().lock();
                defer queue_guard.deinit();
                const queue = queue_guard.get();
                const dirty_entry = types.DirtyEntry{
                    .entity = self.entity_id,
                    .component = self.component_id,
                };
                _ = queue.push(dirty_entry) catch {};
            }
        }
    };
}

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

    pub fn listen(self: *WebSocketServerConnection, source_key: []const u8, source: *Source(Server.ChannelData)) !void {
        const route_key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key });
        errdefer self.allocator.free(route_key);

        try self.server.routes_mutex.lock(self.server.io);
        defer self.server.routes_mutex.unlock(self.server.io);
        try self.server.routes.put(self.allocator, route_key, source);
        std.log.info("route registered: {s}", .{route_key});
    }

    pub fn close(self: *WebSocketServerConnection, source_key: []const u8) !void {
        const route_key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.namespace, source_key }) catch return;
        defer self.allocator.free(route_key);

        try self.server.routes_mutex.lock(self.server.io);
        defer self.server.routes_mutex.unlock(self.server.io);
        if (self.server.routes.fetchRemove(route_key)) |kv| {
            self.allocator.free(kv.key);
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

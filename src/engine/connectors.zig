const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SourceConfig = struct {
    connector_type: []const u8,
    route_path: ?[]const u8 = null,
    remote_url: ?[]const u8 = null,
};

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (*anyopaque, Allocator) anyerror!?[]u8,
        close: *const fn (*anyopaque, Allocator) void,
    };

    pub fn next(self: Connector, allocator: Allocator) !?[]u8 {
        return self.vtable.next(self.ptr, allocator);
    }

    pub fn close(self: Connector, allocator: Allocator) void {
        self.vtable.close(self.ptr, allocator);
    }
};

pub const WebSocketConnector = struct {
    allocator: Allocator,
    source_name: []const u8,
    remote_url: ?[]const u8,
    mode: enum { server, client },

    pub fn open(allocator: Allocator, source_name: []const u8, config: SourceConfig) !Connector {
        const connector = try allocator.create(WebSocketConnector);
        connector.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .remote_url = if (config.remote_url) |url| try allocator.dupe(u8, url) else null,
            .mode = if (config.remote_url != null) .client else .server,
        };
        errdefer allocator.destroy(connector);
        errdefer allocator.free(connector.source_name);

        return .{
            .ptr = connector,
            .vtable = &vtable,
        };
    }

    fn nextImpl(ptr: *anyopaque, allocator: Allocator) !?[]u8 {
        const self: *WebSocketConnector = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = allocator;

        // TODO: Implement based on mode
        // Server mode:
        //   - Check if connection accepted on /<namespace>/<source_key>
        //   - Read message frame
        //   - Return raw bytes or null
        // Client mode:
        //   - Read from remote connection
        //   - Return raw bytes or null

        return null;
    }

    fn closeImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *WebSocketConnector = @ptrCast(@alignCast(ptr));
        allocator.free(self.source_name);
        if (self.remote_url) |url| {
            allocator.free(url);
        }
        allocator.destroy(self);
    }

    const vtable = Connector.VTable{
        .next = nextImpl,
        .close = closeImpl,
    };
};

pub const NATSConnector = struct {
    allocator: Allocator,
    source_name: []const u8,
    remote_url: []const u8,

    pub fn open(allocator: Allocator, source_name: []const u8, config: SourceConfig) !Connector {
        if (config.remote_url == null) {
            return error.NATSRequiresRemoteUrl;
        }

        const connector = try allocator.create(NATSConnector);
        connector.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            // TODO: propagate some error from here as misconf could crash entire runtime
            // in a multi-instance system
            .remote_url = try allocator.dupe(u8, config.remote_url.?),
        };
        errdefer allocator.destroy(connector);
        errdefer allocator.free(connector.source_name);

        return .{
            .ptr = connector,
            .vtable = &vtable,
        };
    }

    fn nextImpl(ptr: *anyopaque, allocator: Allocator) !?[]u8 {
        const self: *NATSConnector = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = allocator;
        // TODO: Implement NATS subscriber polling
        // Subscribe to subject derived from source_key
        // Return raw message bytes or null
        return null;
    }

    fn closeImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *NATSConnector = @ptrCast(@alignCast(ptr));
        allocator.free(self.source_name);
        allocator.free(self.remote_url);
        allocator.destroy(self);
    }

    const vtable = Connector.VTable{
        .next = nextImpl,
        .close = closeImpl,
    };
};

pub const TCPConnector = struct {
    allocator: Allocator,
    source_name: []const u8,
    remote_url: []const u8,

    pub fn open(allocator: Allocator, source_name: []const u8, config: SourceConfig) !Connector {
        if (config.remote_url == null) {
            return error.TCPRequiresRemoteUrl;
        }

        const connector = try allocator.create(TCPConnector);
        connector.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            // TODO: propagate some error from here as misconf could crash entire runtime
            // in a multi-instance system
            .remote_url = try allocator.dupe(u8, config.remote_url.?),
        };
        errdefer allocator.destroy(connector);
        errdefer allocator.free(connector.source_name);

        return .{
            .ptr = connector,
            .vtable = &vtable,
        };
    }

    fn nextImpl(ptr: *anyopaque, allocator: Allocator) !?[]u8 {
        const self: *TCPConnector = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = allocator;
        // TODO: Implement TCP read
        // Read frame or delimited message
        // Return raw bytes or null
        return null;
    }

    fn closeImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *TCPConnector = @ptrCast(@alignCast(ptr));
        allocator.free(self.source_name);
        allocator.free(self.remote_url);
        allocator.destroy(self);
    }

    const vtable = Connector.VTable{
        .next = nextImpl,
        .close = closeImpl,
    };
};

pub const RedisConnector = struct {
    allocator: Allocator,
    source_name: []const u8,
    remote_url: []const u8,

    pub fn open(allocator: Allocator, source_name: []const u8, config: SourceConfig) !Connector {
        if (config.remote_url == null) {
            return error.RedisRequiresRemoteUrl;
        }

        const connector = try allocator.create(RedisConnector);
        connector.* = .{
            .allocator = allocator,
            .source_name = try allocator.dupe(u8, source_name),
            .remote_url = try allocator.dupe(u8, config.remote_url.?),
        };
        errdefer allocator.destroy(connector);
        errdefer allocator.free(connector.source_name);

        return .{
            .ptr = connector,
            .vtable = &vtable,
        };
    }

    fn nextImpl(ptr: *anyopaque, allocator: Allocator) !?[]u8 {
        const self: *RedisConnector = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = allocator;
        // TODO: Implement Redis subscriber polling
        // Subscribe to channel derived from source_key
        // Return raw message bytes or null
        return null;
    }

    fn closeImpl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *RedisConnector = @ptrCast(@alignCast(ptr));
        allocator.free(self.source_name);
        allocator.free(self.remote_url);
        allocator.destroy(self);
    }

    const vtable = Connector.VTable{
        .next = nextImpl,
        .close = closeImpl,
    };
};

pub fn openConnector(
    allocator: Allocator,
    source_name: []const u8,
    config: SourceConfig,
) !Connector {
    if (std.mem.eql(u8, config.connector_type, "ws")) {
        return try WebSocketConnector.open(allocator, source_name, config);
    } else if (std.mem.eql(u8, config.connector_type, "nats")) {
        return try NATSConnector.open(allocator, source_name, config);
    } else if (std.mem.eql(u8, config.connector_type, "tcp")) {
        return try TCPConnector.open(allocator, source_name, config);
    } else if (std.mem.eql(u8, config.connector_type, "redis")) {
        return try RedisConnector.open(allocator, source_name, config);
    } else {
        return error.UnknownConnectorType;
    }
}

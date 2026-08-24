const std = @import("std");
const zio = @import("zio");
const slung = @import("slung");

pub const InstanceConfig = struct {
    module_path: ?[]const u8,
    namespace: []const u8,
    node_id: []const u8,
    ws_port: u16,
    http_port: u16,

    pub fn deinit(_: *InstanceConfig, _: std.mem.Allocator) void {}
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Supervisor {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    /// Run one managed runtime instance until it exits.
    ///
    /// The instance boundary is deliberately separate from CLI parsing so the
    /// supervisor can own multiple instances in a future process model.
    pub fn run(self: *Supervisor, config: InstanceConfig) !void {
        var instance = try Instance.start(self.allocator, self.io, config);
        defer instance.deinit();
        try instance.wait();
    }
};

const Instance = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wasm_bytes: []const u8,
    server: *slung.engine.ws.Server,
    http_server: *slung.engine.http.Server,
    session: *slung.engine.ModuleSession,
    group: zio.Group,

    fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: InstanceConfig,
    ) !Instance {
        const module_path = config.module_path orelse return error.MissingModulePath;
        const wasm_bytes = try readFile(allocator, io, module_path);
        errdefer allocator.free(wasm_bytes);

        const server = try allocator.create(slung.engine.ws.Server);
        errdefer allocator.destroy(server);
        server.* = try slung.engine.ws.Server.init(allocator, io, .{ .port = config.ws_port });
        errdefer server.deinit();

        const http_server = try allocator.create(slung.engine.http.Server);
        errdefer allocator.destroy(http_server);
        http_server.* = try slung.engine.http.Server.init(allocator, io, .{ .port = config.http_port });
        errdefer http_server.deinit();

        var group: zio.Group = .init;
        errdefer group.cancel();

        try group.spawn(runWebSocket, .{server});
        try group.spawn(runHttp, .{http_server});

        const module_config = slung.engine.ModuleConfig{
            .io = io,
            .namespace = config.namespace,
            .node_id = config.node_id,
            .server = server,
            .http_server = http_server,
        };

        const session = try slung.engine.ModuleSession.init(
            allocator,
            io,
            wasm_bytes,
            module_config,
        );
        errdefer session.deinit();

        try group.spawn(runSession, .{session});

        return .{
            .allocator = allocator,
            .io = io,
            .wasm_bytes = wasm_bytes,
            .server = server,
            .http_server = http_server,
            .session = session,
            .group = group,
        };
    }

    fn wait(self: *Instance) !void {
        try self.group.wait();
    }

    fn deinit(self: *Instance) void {
        self.group.cancel();
        self.session.deinit();
        self.http_server.deinit();
        self.allocator.destroy(self.http_server);
        self.server.deinit();
        self.allocator.destroy(self.server);
        self.allocator.free(self.wasm_bytes);
    }

    fn runWebSocket(server: *slung.engine.ws.Server) !void {
        try server.serve();
    }

    fn runHttp(server: *slung.engine.http.Server) !void {
        try server.serve();
    }

    fn runSession(session: *slung.engine.ModuleSession) !void {
        try session.runForever();
    }
};

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);

    var reader = file.reader(io, &[_]u8{});
    try reader.interface.readSliceAll(data);
    return data;
}

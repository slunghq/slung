const std = @import("std");
const zio = @import("zio");
const slung = @import("slung");
const DeploymentServer = @import("deployment.zig").Server;

const SessionLoad = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wasm: []const u8,
    config: slung.engine.ModuleConfig,
    session: ?*slung.engine.ModuleSession = null,
    err: ?anyerror = null,

    fn run(self: *@This()) void {
        self.session = slung.engine.ModuleSession.init(
            self.allocator,
            self.io,
            self.wasm,
            self.config,
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn loadSessionOnThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    wasm: []const u8,
    config: slung.engine.ModuleConfig,
) !*slung.engine.ModuleSession {
    var load = SessionLoad{
        .allocator = allocator,
        .io = io,
        .wasm = wasm,
        .config = config,
    };

    var thread = try std.Thread.spawn(.{}, SessionLoad.run, .{&load});
    thread.join();

    if (load.err) |err| return err;
    return load.session orelse error.ModuleLoadFailed;
}

pub const InstanceConfig = struct {
    module_path: ?[]const u8,
    namespace: []const u8,
    node_id: []const u8,
    ws_port: u16,
    http_port: u16,

    pub fn deinit(_: *InstanceConfig, _: std.mem.Allocator) void {}
};

pub const DeploymentConfig = struct {
    node_id: []const u8,
    discovery_port: u16 = 2072,
    ws_port: u16 = 2073,
    http_port: u16 = 2074,
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

    /// Run the deployment host until it exits. The host does not load a module.
    pub fn run(self: *Supervisor, config: DeploymentConfig) !void {
        const host = try DeploymentHost.start(self.allocator, self.io, config);
        defer host.deinit();
        try host.wait();
    }

    /// Run one managed development module instance until it exits.
    pub fn runDev(self: *Supervisor, config: InstanceConfig) !void {
        var instance = try Instance.start(self.allocator, self.io, config);
        defer instance.deinit();
        try instance.wait();
    }
};

const DeploymentHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    node_id: []const u8,
    deployment_server: *DeploymentServer,
    ws_server: *slung.engine.ws.Server,
    http_server: *slung.engine.http.Server,
    sessions: std.StringHashMapUnmanaged(*slung.engine.ModuleSession) = .empty,
    retired_sessions: std.ArrayListUnmanaged(*slung.engine.ModuleSession) = .empty,
    group: zio.Group,

    fn start(allocator: std.mem.Allocator, io: std.Io, config: DeploymentConfig) !*DeploymentHost {
        const host = try allocator.create(DeploymentHost);
        errdefer allocator.destroy(host);

        const deployment_server = try allocator.create(DeploymentServer);
        errdefer allocator.destroy(deployment_server);
        deployment_server.* = DeploymentServer.init(allocator, io, .{
            .port = config.discovery_port,
            .on_deploy = onDeploy,
            .on_deploy_context = host,
        });
        errdefer deployment_server.deinit();

        const ws_server = try allocator.create(slung.engine.ws.Server);
        errdefer allocator.destroy(ws_server);
        ws_server.* = try slung.engine.ws.Server.init(allocator, io, .{ .port = config.ws_port });
        errdefer ws_server.deinit();

        const http_server = try allocator.create(slung.engine.http.Server);
        errdefer allocator.destroy(http_server);
        http_server.* = try slung.engine.http.Server.init(allocator, io, .{ .port = config.http_port });
        errdefer http_server.deinit();

        var group: zio.Group = .init;
        errdefer group.cancel();
        try group.spawn(runDeployment, .{deployment_server});
        try group.spawn(runWebSocket, .{ws_server});
        try group.spawn(runHttp, .{http_server});

        host.* = .{
            .allocator = allocator,
            .io = io,
            .node_id = config.node_id,
            .deployment_server = deployment_server,
            .ws_server = ws_server,
            .http_server = http_server,
            .group = group,
        };

        std.log.scoped(.slung).info("Starting deployment host:\n  node id: {s}", .{config.node_id});
        return host;
    }

    fn wait(self: *DeploymentHost) !void {
        try self.group.wait();
    }

    fn deinit(self: *DeploymentHost) void {
        self.group.cancel();
        var sessions = self.sessions.iterator();
        while (sessions.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        for (self.retired_sessions.items) |session| session.deinit();
        self.sessions.deinit(self.allocator);
        self.retired_sessions.deinit(self.allocator);
        self.deployment_server.deinit();
        self.allocator.destroy(self.deployment_server);
        self.ws_server.deinit();
        self.allocator.destroy(self.ws_server);
        self.http_server.deinit();
        self.allocator.destroy(self.http_server);
        self.allocator.destroy(self);
    }

    fn onDeploy(context: *anyopaque, deployment: *const @import("deployment.zig").Deployment) anyerror!void {
        const self: *DeploymentHost = @ptrCast(@alignCast(context));
        const module_config = slung.engine.ModuleConfig{
            .io = self.io,
            .namespace = deployment.namespace,
            .node_id = self.node_id,
            .server = self.ws_server,
            .http_server = self.http_server,
        };
        const log = std.log.scoped(.slung);
        if (self.sessions.fetchRemove(deployment.namespace)) |old| {
            log.info("Redeployment: {s} (namespace: {s})", .{ deployment.module_name, deployment.namespace });
            old.value.stop() catch {};
            try self.retired_sessions.append(self.allocator, old.value);
            self.allocator.free(old.key);
        } else {
            log.info("First deployment: {s} (namespace: {s})", .{ deployment.module_name, deployment.namespace });
        }

        const session = try loadSessionOnThread(
            self.allocator,
            self.io,
            deployment.wasm,
            module_config,
        );
        errdefer session.deinit();

        const namespace = try self.allocator.dupe(u8, deployment.namespace);
        errdefer self.allocator.free(namespace);
        try self.sessions.put(self.allocator, namespace, session);
        errdefer _ = self.sessions.remove(namespace);
        try self.group.spawn(runSession, .{session});
    }

    fn runDeployment(server: *DeploymentServer) !void {
        try server.serve();
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
        std.log.scoped(.slung).info(
            "Starting... Module loaded:\n  namespace: {s}\n  node id:   {s}\n  module:    {s}",
            .{ config.namespace, config.node_id, module_path },
        );
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

const std = @import("std");
const http = @import("dusty");

const log = std.log.scoped(.slung);

pub const port: u16 = 2072;
const magic = "SLNGDEP1";
const header_size = 24;
const max_payload_size: usize = 64 * 1024 * 1024;

pub const Deployment = struct {
    namespace: []u8,
    module_name: []u8,
    config: []u8,
    wasm: []u8,
    blake3: [32]u8,

    fn deinit(self: *Deployment, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.module_name);
        allocator.free(self.config);
        allocator.free(self.wasm);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    on_deploy: ?*const fn (*anyopaque, *const Deployment) anyerror!void = null,
    on_deploy_context: ?*anyopaque = null,
    deployments: std.StringHashMapUnmanaged(Deployment) = .empty,
    mutex: std.Io.Mutex = .init,

    pub const Config = struct {
        port: u16 = port,
        on_deploy: ?*const fn (*anyopaque, *const Deployment) anyerror!void = null,
        on_deploy_context: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .on_deploy = config.on_deploy,
            .on_deploy_context = config.on_deploy_context,
        };
    }

    pub fn deinit(self: *Server) void {
        var iterator = self.deployments.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.deployments.deinit(self.allocator);
    }

    pub fn serve(self: *Server) !void {
        var server = http.Server(Server).init(self.allocator, self.io, .{}, self);
        defer server.deinit();

        server.router.post("/deploy", handleDeploy);
        server.router.get("/deploy/*path", handleDeployment);

        const ip = try std.Io.net.IpAddress.parse("0.0.0.0", self.config.port);
        const address: http.Address = .{ .ip = ip };

        log.info("deployment server listening on http://0.0.0.0:{d}", .{self.config.port});
        try server.listen(address);
    }

    fn put(self: *Server, deployment: Deployment) !bool {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ deployment.namespace, deployment.module_name });
        errdefer self.allocator.free(key);

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var first_deployment = true;
        var iterator = self.deployments.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.namespace, deployment.namespace)) {
                first_deployment = false;
                const old_key = entry.key_ptr.*;
                const old_value = entry.value_ptr.*;
                _ = self.deployments.remove(old_key);
                self.allocator.free(old_key);
                var previous = old_value;
                previous.deinit(self.allocator);
                break;
            }
        }

        if (self.deployments.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            var previous = old.value;
            previous.deinit(self.allocator);
        }

        var stored = Deployment{
            .namespace = try self.allocator.dupe(u8, deployment.namespace),
            .module_name = undefined,
            .config = undefined,
            .wasm = undefined,
            .blake3 = undefined,
        };
        errdefer stored.deinit(self.allocator);
        stored.module_name = try self.allocator.dupe(u8, deployment.module_name);
        stored.config = try self.allocator.dupe(u8, deployment.config);
        stored.wasm = try self.allocator.dupe(u8, deployment.wasm);
        stored.blake3 = deployment.blake3;
        try self.deployments.put(self.allocator, key, stored);
        return first_deployment;
    }

    fn get(self: *Server, path: []const u8) ?Deployment {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);

        const deployment = self.deployments.get(path) orelse return null;
        return .{
            .namespace = self.allocator.dupe(u8, deployment.namespace) catch return null,
            .module_name = self.allocator.dupe(u8, deployment.module_name) catch return null,
            .config = self.allocator.dupe(u8, deployment.config) catch return null,
            .wasm = self.allocator.dupe(u8, deployment.wasm) catch return null,
            .blake3 = deployment.blake3,
        };
    }
};

fn handleDeploy(context: *Server, req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse {
        try writeError(res, .bad_request, "deployment body is required");
        return;
    };

    const deployment = parseEnvelope(context.allocator, body) catch {
        try writeError(res, .bad_request, "invalid deployment envelope");
        return;
    };
    errdefer {
        var owned = deployment;
        owned.deinit(context.allocator);
    }

    const first_deployment = try context.put(deployment);
    if (context.on_deploy) |callback| {
        const callback_context = context.on_deploy_context orelse return error.MissingDeploymentContext;
        try callback(callback_context, &deployment);
    }
    try res.header("Content-Type", "application/json");
    res.status = .ok;
    res.body = if (first_deployment)
        \\{
        \\ "status": "first deployment"
        \\}
    else
        \\{
        \\ "status": "redeployment"
        \\}
    ;
}

fn handleDeployment(context: *Server, req: *http.Request, res: *http.Response) !void {
    const path = if (std.mem.startsWith(u8, req.url, "/deploy/")) req.url[8..] else "";
    const deployment = context.get(path) orelse {
        try writeError(res, .not_found, "deployment not found");
        return;
    };
    var owned = deployment;
    defer owned.deinit(context.allocator);

    try res.header("Content-Type", "application/octet-stream");
    res.status = .ok;
    res.body = owned.wasm;
}

fn writeError(res: *http.Response, status: http.Status, message: []const u8) !void {
    try res.header("Content-Type", "application/json");
    res.status = status;
    res.body = message;
}

fn parseEnvelope(allocator: std.mem.Allocator, body: []const u8) !Deployment {
    if (body.len < header_size or !std.mem.eql(u8, body[0..magic.len], magic)) return error.InvalidEnvelope;

    const namespace_len = readU32(body[8..12]);
    const module_name_len = readU32(body[12..16]);
    const config_len = readU32(body[16..20]);
    const wasm_len = readU32(body[20..24]);

    const total = @as(usize, namespace_len) + @as(usize, module_name_len) + @as(usize, config_len) + @as(usize, wasm_len);
    if (total > max_payload_size or header_size + total != body.len) return error.InvalidEnvelope;

    var offset: usize = header_size;
    const namespace = try allocator.dupe(u8, body[offset .. offset + namespace_len]);
    errdefer allocator.free(namespace);
    offset += namespace_len;
    const module_name = try allocator.dupe(u8, body[offset .. offset + module_name_len]);
    errdefer allocator.free(module_name);
    offset += module_name_len;
    const config = try allocator.dupe(u8, body[offset .. offset + config_len]);
    errdefer allocator.free(config);
    offset += config_len;
    const wasm = try allocator.dupe(u8, body[offset .. offset + wasm_len]);
    var blake3: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(wasm, &blake3, .{});

    return .{
        .namespace = namespace,
        .module_name = module_name,
        .config = config,
        .wasm = wasm,
        .blake3 = blake3,
    };
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

pub fn writeEnvelope(allocator: std.mem.Allocator, namespace: []const u8, module_name: []const u8, config: []const u8, wasm: []const u8) ![]u8 {
    const total = header_size + namespace.len + module_name.len + config.len + wasm.len;
    if (total > max_payload_size) return error.DeploymentTooLarge;

    const body = try allocator.alloc(u8, total);
    @memcpy(body[0..magic.len], magic);
    writeU32(body[8..12], @intCast(namespace.len));
    writeU32(body[12..16], @intCast(module_name.len));
    writeU32(body[16..20], @intCast(config.len));
    writeU32(body[20..24], @intCast(wasm.len));

    var offset: usize = header_size;
    @memcpy(body[offset .. offset + namespace.len], namespace);
    offset += namespace.len;
    @memcpy(body[offset .. offset + module_name.len], module_name);
    offset += module_name.len;
    @memcpy(body[offset .. offset + config.len], config);
    offset += config.len;
    @memcpy(body[offset .. offset + wasm.len], wasm);
    return body;
}

fn writeU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

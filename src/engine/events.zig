const std = @import("std");
const Allocator = std.mem.Allocator;

const zio = @import("zio");
const zwasm = @import("zwasm");

const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;
const Arc = @import("../primitives/arc.zig").Arc;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const queue_mod = @import("../queue.zig");
const types = @import("../types.zig");
const Storage = @import("../storage.zig").Storage;
const wasm_host = @import("../wasm/host.zig");
const graph_index = @import("../wasm/index.zig");
const wasm_module_desc = @import("../wasm/module.zig");
const wasm_wire = @import("../wasm/wire.zig");
const ws_mod = @import("connectors/ws.zig");
const http_mod = @import("connectors/http.zig");
const connectors_mod = @import("connectors.zig");
const Connector = connectors_mod.Connector;
const SourceConfig = connectors_mod.SourceConfig;
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const loop_mod = @import("loop.zig");
const InferenceLoop = loop_mod.InferenceLoop;
const RuleDispatcher = loop_mod.RuleDispatcher;

const WsSource = @import("connectors/shared.zig").Source(ws_mod.Server.ChannelData);
const HttpSource = @import("connectors/shared.zig").Source(http_mod.Server.RequestBody);

pub const ModuleConfig = struct {
    io: std.Io,
    namespace: []const u8,
    node_id: []const u8,
    server: *ws_mod.Server,
    http_server: *http_mod.Server,
    storage: *Storage,
    durability: Storage.Durability = .eventual,
};

pub const ModuleSession = struct {
    allocator: Allocator,
    io: std.Io,
    wasm_module: *zwasm.WasmModule,
    owned_wasm_bytes: []u8,
    namespace: []const u8,
    node_id: []const u8,

    lww_store: Arc(Mutex(LwwRegistry)),
    dirty_queue: Arc(Mutex(queue_mod.DirtyQueue)),
    claim_register: Arc(Mutex(ClaimRegister)),

    forward_index: graph_index.ForwardIndex,
    reverse_index: graph_index.ReverseIndex,

    connectors: std.StringHashMap(Connector),
    source_configs: std.StringHashMap(SourceConfig),
    ws_connection: ?ws_mod.WebSocketServerConnection,
    ws_sources: std.ArrayList(WsRouteSource),
    http_connection: ?http_mod.HTTPServerConnection,
    http_sources: std.ArrayList(HttpRouteSource),
    http_server: *http_mod.Server,
    storage: *Storage,

    context: Context,
    clock: Hlc,
    host_fns: ?[]const zwasm.HostFnEntry = null,

    const Self = @This();
    const WsRouteSource = struct {
        route_path: []const u8,
        source_name: []const u8,
        source: Arc(Mutex(WsSource)),
    };
    const HttpRouteSource = struct {
        route_path: []const u8,
        source_name: []const u8,
        source: Arc(Mutex(HttpSource)),
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        wasm_bytes: []const u8,
        config: ModuleConfig,
    ) !*Self {
        const session = try allocator.create(Self);
        errdefer allocator.destroy(session);
        session.allocator = allocator;
        session.io = io;

        session.forward_index = .empty;
        session.reverse_index = .empty;
        errdefer deinitIndices(allocator, &session.forward_index, &session.reverse_index);

        var queue_owner = try queue_mod.QueueOwner.init(allocator, 8, config.namespace, config.io);
        defer queue_owner.deinit();

        const dirty_queue = queue_mod.DirtyQueue{
            .shared = queue_owner.shared.clone(),
            .io = config.io,
        };
        session.dirty_queue = try Arc(Mutex(queue_mod.DirtyQueue)).init(
            allocator,
            Mutex(queue_mod.DirtyQueue).init(dirty_queue, config.io),
        );
        errdefer {
            var guard = session.dirty_queue.getMut().lock();
            guard.get().decrement();
            guard.deinit();
            session.dirty_queue.release();
        }

        session.lww_store = try Arc(Mutex(LwwRegistry)).init(
            allocator,
            Mutex(LwwRegistry).init(LwwRegistry.init(allocator), config.io),
        );
        errdefer {
            var guard = session.lww_store.getMut().lock();
            guard.get().deinit();
            guard.deinit();
            session.lww_store.release();
        }

        session.claim_register = try Arc(Mutex(ClaimRegister)).init(
            allocator,
            Mutex(ClaimRegister).init(ClaimRegister.init(), config.io),
        );
        errdefer {
            var guard = session.claim_register.getMut().lock();
            guard.get().deinit(allocator);
            guard.deinit();
            session.claim_register.release();
        }

        const persisted_timestamp = try config.storage.latestTimestamp(config.namespace);
        session.clock = if (persisted_timestamp) |ts| Hlc.fromTimestamp(config.io, ts) else Hlc.init(config.io, 1);

        session.context = Context.init(
            allocator,
            config.io,
            session.lww_store,
            session.dirty_queue,
            session.claim_register,
            &session.forward_index,
            &session.reverse_index,
            &session.clock,
            undefined, // module filled after load
            config.namespace,
            config.node_id,
            config.storage,
        );

        const env_imports = try wasm_host.createEnvImport(allocator, @intFromPtr(&session.context));
        errdefer allocator.free(env_imports.source.host_fns);
        session.host_fns = env_imports.source.host_fns;

        const owned_wasm_bytes = try allocator.dupe(u8, wasm_bytes);
        var wasm_bytes_transferred = false;
        errdefer if (!wasm_bytes_transferred) allocator.free(owned_wasm_bytes);

        session.wasm_module = try zwasm.WasmModule.loadWasiWithImports(
            allocator,
            owned_wasm_bytes,
            &[_]zwasm.ImportEntry{env_imports},
            .{},
        );
        session.owned_wasm_bytes = owned_wasm_bytes;
        wasm_bytes_transferred = true;
        errdefer session.wasm_module.deinit();

        session.context.module = session.wasm_module;

        try wasm_wire.wire(
            allocator,
            session.wasm_module,
            &session.forward_index,
            &session.reverse_index,
            config.namespace,
            "module.wasm",
        );

        session.source_configs = std.StringHashMap(SourceConfig).init(allocator);
        errdefer {
            var it = session.source_configs.iterator();
            while (it.next()) |e| freeSourceConfig(allocator, e);
            session.source_configs.deinit();
        }
        try session.loadSourceConfigsFromModule();

        session.namespace = try allocator.dupe(u8, config.namespace);
        errdefer allocator.free(session.namespace);
        session.node_id = try allocator.dupe(u8, config.node_id);
        errdefer allocator.free(session.node_id);
        session.connectors = std.StringHashMap(Connector).init(allocator);
        session.ws_connection = try ws_mod.WebSocketServerConnection.init(allocator, config.server, config.namespace);
        session.http_connection = try http_mod.HTTPServerConnection.init(allocator, config.http_server, config.namespace);
        session.ws_sources = .empty;
        session.http_sources = .empty;
        session.http_server = config.http_server;
        session.storage = config.storage;

        return session;
    }

    pub fn deinit(self: *Self) void {
        self.closeConnectors() catch {};
        self.connectors.deinit();
        self.ws_sources.deinit(self.allocator);
        {
            const iter = self.http_sources.items;
            for (iter) |item| {
                self.allocator.free(item.source_name);
                item.source.release();
            }
            self.http_sources.deinit(self.allocator);
        }
        if (self.ws_connection) |*connection| {
            connection.deinit();
        }
        if (self.http_connection) |*connection| {
            connection.deinit();
        }
        {
            var iter = self.source_configs.iterator();
            while (iter.next()) |entry| {
                freeSourceConfig(self.allocator, entry);
            }
            self.source_configs.deinit();
        }

        {
            var iter = self.forward_index.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.value_ptr.watchers);
                self.allocator.free(entry.value_ptr.source);
                self.allocator.free(entry.value_ptr.component_type);
                self.allocator.free(entry.value_ptr.mapper);
            }
            self.forward_index.deinit(self.allocator);
        }

        {
            var iter = self.reverse_index.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.value_ptr.watch);
                self.allocator.free(entry.value_ptr.entrypoint);
                self.allocator.free(entry.value_ptr.module);
                self.allocator.free(entry.value_ptr.namespace);
            }
            self.reverse_index.deinit(self.allocator);
        }

        {
            var guard = self.dirty_queue.getMut().lock();
            guard.get().decrement();
            guard.deinit();
            self.dirty_queue.release();
        }

        {
            var guard = self.lww_store.getMut().lock();
            guard.get().deinit();
            guard.deinit();
            self.lww_store.release();
        }

        {
            var guard = self.claim_register.getMut().lock();
            guard.get().deinit(self.allocator);
            guard.deinit();
            self.claim_register.release();
        }

        self.wasm_module.deinit();
        self.allocator.free(self.owned_wasm_bytes);

        if (self.host_fns) |host_fns| {
            self.allocator.free(host_fns);
        }

        self.allocator.free(self.namespace);
        self.allocator.free(self.node_id);
        self.allocator.destroy(self);
    }

    pub fn run(self: *Self, max_iterations: u32) !void {
        try self.setupConnectors();
        defer self.closeConnectors() catch {};

        var iteration: u32 = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            const did_work = try self.pollSources();

            if (!did_work) {
                if (try self.storage.pendingDirtyCountFor(self.namespace) == 0) break;
            }

            _ = try self.runInferenceOnce();
        }
    }

    pub fn start(self: *Self) !void {
        try self.setupConnectors();
    }

    pub fn stop(self: *Self) !void {
        try self.closeConnectors();
    }

    /// Run one inference cycle if there is dirty work available.
    /// Returns true if an inference cycle ran.
    pub fn step(self: *Self) !bool {
        // First, poll for new data from sources (WebSocket, TCP, etc.)
        _ = try self.pollSources();

        if (try self.storage.pendingDirtyCountFor(self.namespace) == 0) return false;

        _ = try self.runInferenceOnce();
        return true;
    }

    /// Long-lived runtime loop: waits for dirty work and runs inference cycles.
    pub fn runForever(self: *Self) !void {
        try self.setupConnectors();
        defer self.closeConnectors() catch {};

        while (true) {
            if (!try self.step()) {
                try zio.yield();
            }
        }
    }

    fn setupConnectors(self: *Self) !void {
        var iter = self.source_configs.iterator();
        while (iter.next()) |entry| {
            const source_name = entry.key_ptr.*;
            const config = entry.value_ptr.*;

            const connector = try connectors_mod.openConnector(
                self.allocator,
                source_name,
                config,
            );
            var connector_tracked = false;
            errdefer if (connector_tracked) {
                if (self.connectors.fetchRemove(source_name)) |removed| {
                    removed.value.close(self.allocator);
                }
            } else {
                connector.close(self.allocator);
            };
            try self.connectors.put(source_name, connector);
            connector_tracked = true;

            if (std.mem.eql(u8, config.connector_type, "ws") and config.remote_url == null) {
                const route_path = config.route_path orelse source_name;
                const forward_key = self.findAnyForwardKeyForSource(source_name) orelse return error.SourceForwardMappingNotFound;

                const source_arc = try Arc(Mutex(WsSource)).init(self.allocator, Mutex(WsSource).init(.{
                    .allocator = self.allocator,
                    .namespace = self.namespace,
                    .node_id = self.node_id,
                    .entity_id = forward_key.entity,
                    .component_id = forward_key.component,
                    .lww_store = self.lww_store.clone(),
                    .dirty_queue = self.dirty_queue.clone(),
                    .clock = &self.clock,
                    .data = null,
                }, self.context.io));
                errdefer source_arc.release();

                if (self.ws_connection) |*connection| {
                    try connection.listen(route_path, source_arc);
                    errdefer connection.close(route_path) catch {};
                    std.log.scoped(.slung).info("Registered route: WS /{s}/{s}", .{ self.namespace, route_path });
                    const source_arc_clone = source_arc.clone();
                    errdefer source_arc_clone.release();
                    try self.ws_sources.append(self.allocator, .{
                        .route_path = route_path,
                        .source_name = source_name,
                        .source = source_arc_clone,
                    });
                }
                source_arc.release();
            }

            if (std.mem.eql(u8, config.connector_type, "http")) {
                const route_path = config.route_path orelse source_name;
                const forward_key = self.findAnyForwardKeyForSource(source_name) orelse return error.SourceForwardMappingNotFound;

                const source_arc = try Arc(Mutex(HttpSource)).init(self.allocator, Mutex(HttpSource).init(.{
                    .allocator = self.allocator,
                    .namespace = self.namespace,
                    .node_id = self.node_id,
                    .entity_id = forward_key.entity,
                    .component_id = forward_key.component,
                    .lww_store = self.lww_store.clone(),
                    .dirty_queue = self.dirty_queue.clone(),
                    .clock = &self.clock,
                    .data = null,
                }, self.context.io));
                errdefer source_arc.release();

                if (self.http_connection) |*connection| {
                    try connection.listen(route_path, source_arc);
                    errdefer connection.close(route_path) catch {};
                    std.log.scoped(.slung).info("Registered route: POST /{s}/{s}", .{ self.namespace, route_path });
                    const source_arc_clone = source_arc.clone();
                    errdefer source_arc_clone.release();
                    const duped_name = try self.allocator.dupe(u8, source_name);
                    errdefer self.allocator.free(duped_name);
                    try self.http_sources.append(self.allocator, .{
                        .route_path = route_path,
                        .source_name = duped_name,
                        .source = source_arc_clone,
                    });
                }
                source_arc.release();
            }
        }
    }

    fn closeConnectors(self: *Self) !void {
        // De-register all WebSocket sources and release the Arcs
        var first_error: ?anyerror = null;
        for (self.ws_sources.items) |route_source| {
            if (self.ws_connection) |*connection| {
                connection.close(route_source.route_path) catch |err| {
                    if (first_error == null) first_error = err;
                };
            }
            route_source.source.release();
        }
        self.ws_sources.clearRetainingCapacity();

        // De-register all HTTP sources and release the Arcs
        for (self.http_sources.items) |route_source| {
            if (self.http_connection) |*connection| {
                connection.close(route_source.route_path) catch |err| {
                    if (first_error == null) first_error = err;
                };
            }
            self.allocator.free(route_source.source_name);
            route_source.source.release();
        }
        self.http_sources.clearRetainingCapacity();

        while (self.connectors.count() > 0) {
            var iter = self.connectors.iterator();
            const entry = iter.next().?;
            const key = entry.key_ptr.*;
            entry.value_ptr.close(self.allocator);
            _ = self.connectors.remove(key);
        }

        if (first_error) |err| return err;
    }

    fn findAnyForwardKeyForSource(self: *Self, source_name: []const u8) ?graph_index.ForwardKey {
        var iter = self.forward_index.iterator();
        while (iter.next()) |entry| {
            const forward_entry = entry.value_ptr.*;
            if (!std.mem.eql(u8, forward_entry.source, source_name)) continue;
            return entry.key_ptr.*;
        }
        return null;
    }

    fn pollSources(self: *Self) !bool {
        var work_done = false;
        for (self.ws_sources.items) |ws_route| {
            var guard = ws_route.source.getMut().lock();
            defer guard.deinit();
            if (guard.get().data) |channel_data| {
                work_done = true;
                try self.ingestSourceData(ws_route.source_name, channel_data.data);
                guard.get().data = null;
            }
        }

        for (self.http_sources.items) |http_route| {
            var guard = http_route.source.getMut().lock();
            defer guard.deinit();
            if (guard.get().data) |request_body| {
                work_done = true;
                try self.ingestSourceData(http_route.source_name, request_body.data);
                guard.get().allocator.free(request_body.data);
                guard.get().data = null;
            }
        }

        var iter = self.connectors.iterator();

        while (iter.next()) |entry| {
            const source_name = entry.key_ptr.*;
            var connector = entry.value_ptr.*;

            while (try connector.next(self.allocator)) |raw_data| {
                defer self.allocator.free(raw_data);
                work_done = true;

                try self.ingestSourceData(source_name, raw_data);
            }
        }

        return work_done;
    }

    fn ingestSourceData(self: *Self, source_name: []const u8, raw_data: []const u8) !void {
        var mapper_count: usize = 0;
        var success_count: usize = 0;
        var iter = self.forward_index.iterator();
        while (iter.next()) |entry| {
            const forward_key = entry.key_ptr.*;
            const forward_entry = entry.value_ptr.*;

            if (!std.mem.eql(u8, forward_entry.source, source_name)) {
                continue;
            }
            mapper_count += 1;

            const input_offset: u32 = 10000;
            const output_offset: u32 = 20000;
            const output_len_offset: u32 = 30000;

            try self.wasm_module.memoryWrite(input_offset, raw_data);

            var output_len_init: [4]u8 = undefined;
            std.mem.writeInt(u32, &output_len_init, 0, .little);
            try self.wasm_module.memoryWrite(output_len_offset, &output_len_init);

            var results = [_]u64{0};
            self.wasm_module.invoke(
                forward_entry.mapper,
                &.{ input_offset, raw_data.len, output_offset, output_len_offset },
                results[0..],
            ) catch |err| {
                std.log.debug("Mapper invocation failed for {s}: {}", .{ forward_entry.mapper, err });
                continue;
            };

            const status: i32 = @bitCast(@as(u32, @intCast(results[0])));
            if (status != 0) {
                std.log.debug("Mapper {s} declined payload with status {}", .{ forward_entry.mapper, status });
                continue;
            }
            success_count += 1;

            const output_len_bytes = try self.wasm_module.memoryRead(self.allocator, output_len_offset, 4);
            defer self.allocator.free(output_len_bytes);
            const output_len = std.mem.readInt(u32, output_len_bytes[0..4], .little);

            const mapped = try self.wasm_module.memoryRead(self.allocator, output_offset, output_len);
            defer self.allocator.free(mapped);

            // Build LWW store key: namespace:entity:component
            var key_buf: [128]u8 = undefined;
            const store_key = std.fmt.bufPrint(
                &key_buf,
                "{s}:{d}:{d}",
                .{ self.namespace, forward_key.entity, forward_key.component },
            ) catch {
                std.log.err("Failed to format store key", .{});
                continue;
            };

            const timestamp = self.clock.send();
            const cause = types.CausalTag{
                .cause = forward_key.component,
                .entity = forward_key.entity,
                .node = self.node_id,
            };
            const accepted = self.context.persistMutation(.{
                .namespace = self.namespace,
                .entity = forward_key.entity,
                .component = forward_key.component,
                .value = mapped,
                .timestamp = timestamp,
                .cause = cause,
            }) catch |err| {
                std.log.err("Failed to persist fact mutation: {}", .{err});
                continue;
            };

            if (accepted) {
                var store_guard = self.lww_store.getMut().lock();
                defer store_guard.deinit();
                _ = store_guard.get().put(store_key, timestamp, .{ .Bytes = mapped }, cause) catch |err| {
                    std.log.err("Failed to update LWW cache: {}", .{err});
                    continue;
                };
            }
        }

        if (mapper_count > 0 and success_count == 0) {
            std.log.warn("No mappers accepted payload for source {s}", .{source_name});
        }
    }

    fn loadSourceConfigsFromModule(self: *Self) !void {
        const exports = self.wasm_module.export_fns;
        for (exports) |export_info| {
            if (!std.mem.startsWith(u8, export_info.name, "__slung_source_") or
                !std.mem.endsWith(u8, export_info.name, "_descriptor"))
            {
                continue;
            }

            var result: [1]u64 = undefined;
            try self.wasm_module.invoke(export_info.name, &.{}, result[0..]);
            const length: u32 = @intCast(result[0] & 0xFFFFFFFF);
            const offset: u32 = @intCast((result[0] >> 32) & 0xFFFFFFFF);

            const bytes = try self.wasm_module.memoryRead(self.allocator, offset, length);
            defer self.allocator.free(bytes);

            const parsed = try std.json.parseFromSlice(
                wasm_module_desc.ParsedSourceDescriptor,
                self.allocator,
                bytes,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();

            const source_name = try self.allocator.dupe(u8, parsed.value.name);
            errdefer self.allocator.free(source_name);

            const connector_type_src = if (std.mem.eql(u8, parsed.value.kind, "builtin"))
                parsed.value.builtin
            else
                parsed.value.kind;
            const connector_type = try self.allocator.dupe(u8, connector_type_src);
            errdefer self.allocator.free(connector_type);

            const route_path = try routePathForSourceConfig(self.allocator, connector_type_src, parsed.value.config);
            errdefer if (route_path) |path| self.allocator.free(path);

            const remote_url = try remoteUrlForSourceConfig(self.allocator, connector_type_src, parsed.value.config);
            errdefer if (remote_url) |url| self.allocator.free(url);

            try self.source_configs.put(source_name, .{
                .connector_type = connector_type,
                .route_path = route_path,
                .remote_url = remote_url,
            });
        }
    }

    fn runInferenceOnce(self: *Self) !usize {
        var dispatcher = WasmRuleDispatcher{
            .module = self.wasm_module,
            .reverse = &self.reverse_index,
            .context = &self.context,
        };

        const dispatch = RuleDispatcher{
            .ptr = &dispatcher,
            .dispatch_fn = WasmRuleDispatcher.dispatch,
        };

        var loop = InferenceLoop.init(&self.context, dispatch, 10, self.allocator);
        return try loop.run();
    }
};

fn freeSourceConfig(allocator: Allocator, entry: anytype) void {
    allocator.free(entry.key_ptr.*);
    allocator.free(entry.value_ptr.connector_type);
    if (entry.value_ptr.route_path) |path| allocator.free(path);
    if (entry.value_ptr.remote_url) |url| allocator.free(url);
}

fn routePathForSourceConfig(
    allocator: Allocator,
    connector_type: []const u8,
    config: std.json.Value,
) !?[]const u8 {
    if (!std.mem.eql(u8, connector_type, "ws") and !std.mem.eql(u8, connector_type, "http")) return null;
    if (std.mem.eql(u8, connector_type, "ws")) {
        const raw_path = jsonObjectString(config, "path") orelse return null;
        return try allocator.dupe(u8, std.mem.trimStart(u8, raw_path, "/"));
    } else {
        const raw_path = jsonObjectString(config, "endpoint") orelse return null;
        return try allocator.dupe(u8, std.mem.trimStart(u8, raw_path, "/"));
    }
}

fn remoteUrlForSourceConfig(
    allocator: Allocator,
    connector_type: []const u8,
    config: std.json.Value,
) !?[]const u8 {
    if (std.mem.eql(u8, connector_type, "ws")) {
        if (jsonObjectString(config, "url")) |url| return try allocator.dupe(u8, url);
        if (jsonObjectString(config, "endpoint")) |endpoint| return try allocator.dupe(u8, endpoint);
        return null;
    }
    if (jsonObjectString(config, "url")) |url| return try allocator.dupe(u8, url);
    if (jsonObjectString(config, "endpoint")) |endpoint| return try allocator.dupe(u8, endpoint);
    return null;
}

fn jsonObjectString(config: std.json.Value, key: []const u8) ?[]const u8 {
    if (config != .object) return null;
    const value = config.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

const WasmRuleDispatcher = struct {
    module: *zwasm.WasmModule,
    reverse: *graph_index.ReverseIndex,
    context: *Context,

    fn dispatch(ptr: *anyopaque, rule_id: types.RuleId, entity_id: types.EntityId) anyerror!i32 {
        const self: *WasmRuleDispatcher = @ptrCast(@alignCast(ptr));
        const reverse = self.reverse.get(rule_id) orelse return error.RuleNotFound;
        self.context.setCurrentExecution(entity_id, rule_id);
        var results = [_]u64{0};
        self.module.invoke(reverse.entrypoint, &.{}, &results) catch {
            if (self.module.getWasiExitCode()) |code| {
                if (code != 0) return error.WasiNonZeroExit;
                return 0;
            }
            return error.WasmTrap;
        };
        return @bitCast(@as(u32, @truncate(results[0])));
    }
};

fn deinitIndices(
    allocator: Allocator,
    forward: *graph_index.ForwardIndex,
    reverse: *graph_index.ReverseIndex,
) void {
    var f_iter = forward.iterator();
    while (f_iter.next()) |entry| {
        allocator.free(entry.value_ptr.watchers);
        allocator.free(entry.value_ptr.source);
        allocator.free(entry.value_ptr.component_type);
        allocator.free(entry.value_ptr.mapper);
    }
    forward.deinit(allocator);

    var r_iter = reverse.iterator();
    while (r_iter.next()) |entry| {
        allocator.free(entry.value_ptr.watch);
        allocator.free(entry.value_ptr.entrypoint);
        allocator.free(entry.value_ptr.module);
        allocator.free(entry.value_ptr.namespace);
    }
    reverse.deinit(allocator);
}

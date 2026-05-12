const std = @import("std");
const zwasm = @import("zwasm");

const types = @import("../types.zig");
const queue_mod = @import("../queue.zig");
const wasm_host = @import("../wasm/host.zig");
const wasm_wire = @import("../wasm/wire.zig");
const graph_index = @import("../wasm/index.zig");
const loop_mod = @import("loop.zig");
const context_mod = @import("context.zig");
const connectors_mod = @import("connectors.zig");
const ws_mod = @import("connectors/ws.zig");
const server_mod = @import("connectors/server.zig");
const Arc = @import("../primitives/arc.zig").Arc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;

const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const InferenceLoop = loop_mod.InferenceLoop;
const RuleDispatcher = loop_mod.RuleDispatcher;
const Connector = connectors_mod.Connector;
const SourceConfig = connectors_mod.SourceConfig;
const WsSource = ws_mod.Source(server_mod.Server.ChannelData);

const Allocator = std.mem.Allocator;

pub const ModuleConfig = struct {
    io: std.Io,
    namespace: []const u8,
    node_id: []const u8,
    server: *server_mod.Server,
};

pub const ModuleSession = struct {
    allocator: Allocator,
    io: std.Io,
    wasm_module: *zwasm.WasmModule,
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

    context: Context,
    clock: Hlc,

    const Self = @This();
    const WsRouteSource = struct {
        source_key: []const u8,
        source: Arc(Mutex(WsSource)),
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        wasm_bytes: []const u8,
        config: ModuleConfig,
    ) !*Self {
        const session = try allocator.create(Self);
        errdefer allocator.destroy(session);

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

        session.clock = Hlc.init(1, config.io);

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
        );

        const env_imports = try wasm_host.createEnvImport(allocator, @intFromPtr(&session.context));
        errdefer allocator.free(env_imports.source.host_fns);

        session.wasm_module = try zwasm.WasmModule.loadWasiWithImports(
            allocator,
            wasm_bytes,
            &[_]zwasm.ImportEntry{env_imports},
            .{},
        );
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
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            session.source_configs.deinit();
        }
        {
            var f_iter = session.forward_index.iterator();
            while (f_iter.next()) |entry| {
                const fwd = entry.value_ptr.*;
                const route = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fwd.source, fwd.component_type });
                if (session.source_configs.contains(route)) {
                    allocator.free(route);
                    continue;
                }
                try session.source_configs.put(route, .{
                    .connector_type = "ws",
                    .source_key = route,
                    .remote_url = null,
                });
            }
        }

        session.allocator = allocator;
        session.io = io;
        session.namespace = try allocator.dupe(u8, config.namespace);
        errdefer allocator.free(session.namespace);
        session.node_id = try allocator.dupe(u8, config.node_id);
        errdefer allocator.free(session.node_id);
        session.connectors = std.StringHashMap(Connector).init(allocator);
        session.ws_connection = try ws_mod.WebSocketServerConnection.init(allocator, config.server, config.namespace);
        session.ws_sources = .empty;

        return session;
    }

    pub fn deinit(self: *Self) void {
        self.closeConnectors() catch {};
        self.connectors.deinit();
        self.ws_sources.deinit(self.allocator);
        if (self.ws_connection) |*connection| {
            connection.deinit();
        }
        {
            var iter = self.source_configs.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
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
                var queue_guard = self.dirty_queue.getMut().lock();
                defer queue_guard.deinit();
                if (queue_guard.get().is_empty()) {
                    break;
                }
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

        var queue_guard = self.dirty_queue.getMut().lock();
        const empty = queue_guard.get().is_empty();
        queue_guard.deinit();
        if (empty) return false;

        _ = try self.runInferenceOnce();
        return true;
    }

    /// Long-lived runtime loop: waits for dirty work and runs inference cycles.
    /// This does not currently block on I/O; it polls the dirty queue.
    pub fn runForever(self: *Self) !void {
        try self.setupConnectors();
        defer self.closeConnectors() catch {};

        while (true) {
            if (!try self.step()) {
                try self.context.io.sleep(.{ .nanoseconds = 10 }, .awake);
            }
        }
    }

    fn setupConnectors(self: *Self) !void {
        var iter = self.source_configs.iterator();
        while (iter.next()) |entry| {
            const source_key = entry.key_ptr.*;
            const config = entry.value_ptr.*;

            const connector = try connectors_mod.openConnector(
                self.allocator,
                config,
            );

            try self.connectors.put(source_key, connector);

            if (std.mem.eql(u8, config.connector_type, "ws") and config.remote_url == null) {
                const forward_key = self.findForwardKeyForRoute(source_key) orelse {
                    std.log.err("no forward mapping for ws route '{s}'", .{source_key});
                    std.log.err("available module routes:", .{});
                    var f_iter = self.forward_index.iterator();
                    while (f_iter.next()) |f_entry| {
                        const fwd = f_entry.value_ptr.*;
                        std.log.err("  - {s}/{s}", .{ fwd.source, fwd.component_type });
                    }
                    return error.SourceForwardMappingNotFound;
                };

                const source = try self.allocator.create(WsSource);
                source.* = .{
                    .allocator = self.allocator,
                    .namespace = self.namespace,
                    .node_id = self.node_id,
                    .entity_id = forward_key.entity,
                    .component_id = forward_key.component,
                    .lww_store = self.lww_store.clone(),
                    .dirty_queue = self.dirty_queue.clone(),
                    .clock = &self.clock,
                    .data = null,
                };
                const source_arc = try Arc(Mutex(WsSource)).init(self.allocator, Mutex(WsSource).init(source.*, self.io));

                if (self.ws_connection) |*connection| {
                    try connection.listen(source_key, source_arc);
                    try self.ws_sources.append(self.allocator, .{
                        .source_key = source_key,
                        .source = source_arc,
                    });
                }
            }
        }
    }

    fn closeConnectors(self: *Self) !void {
        for (self.ws_sources.items) |route_source| {
            if (self.ws_connection) |*connection| {
                try connection.close(route_source.source_key);
            }
            var guard = route_source.source.getMut().lock();
            defer guard.deinit();
            guard.get().lww_store.release();
            guard.get().dirty_queue.release();
            self.allocator.destroy(guard.get());
        }
        self.ws_sources.clearRetainingCapacity();

        var iter = self.connectors.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.close(self.allocator);
        }
    }

    fn findForwardKeyForRoute(self: *Self, route: []const u8) ?graph_index.ForwardKey {
        const cut = std.mem.lastIndexOfScalar(u8, route, '/') orelse return null;
        const source_name = route[0..cut];
        const component_type = route[cut + 1 ..];

        var found: ?graph_index.ForwardKey = null;
        var iter = self.forward_index.iterator();
        while (iter.next()) |entry| {
            const forward_entry = entry.value_ptr.*;
            if (!std.mem.eql(u8, forward_entry.source, source_name)) continue;
            if (!std.mem.eql(u8, forward_entry.component_type, component_type)) continue;

            if (found != null) return null;
            found = entry.key_ptr.*;
        }
        return found;
    }

    fn pollSources(self: *Self) !bool {
        var work_done = false;
        for (self.ws_sources.items) |ws_route| {
            var guard = ws_route.source.getMut().lock();
            defer guard.deinit();
            if (guard.get().data) |channel_data| {
                work_done = true;
                try self.ingestSourceData(ws_route.source_key, channel_data.data);
                guard.get().data = null;
            }
        }

        var iter = self.connectors.iterator();

        while (iter.next()) |entry| {
            const source_key = entry.key_ptr.*;
            var connector = entry.value_ptr.*;

            while (try connector.next(self.allocator)) |raw_data| {
                defer self.allocator.free(raw_data);
                work_done = true;

                try self.ingestSourceData(source_key, raw_data);
            }
        }

        return work_done;
    }

    fn ingestSourceData(self: *Self, source_key: []const u8, raw_data: []const u8) !void {
        // source_key format is "SourceName/ComponentType", extract both parts
        const slash_pos = std.mem.indexOfScalar(u8, source_key, '/') orelse return;
        const source_name = source_key[0..slash_pos];
        const component_type = source_key[slash_pos + 1 ..];

        // Find the specific forward entry matching both source and component type
        var iter = self.forward_index.iterator();
        while (iter.next()) |entry| {
            const forward_key = entry.key_ptr.*;
            const forward_entry = entry.value_ptr.*;

            // Check if this entry matches BOTH source name AND component type
            if (!std.mem.eql(u8, forward_entry.source, source_name)) {
                continue;
            }
            if (!std.mem.eql(u8, forward_entry.component_type, component_type)) {
                continue;
            }

            // Invoke mapper to parse raw data
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
                std.log.err("Mapper invocation failed for {s}: {}", .{ forward_entry.mapper, err });
                continue;
            };

            const status: i32 = @bitCast(@as(u32, @intCast(results[0])));
            if (status != 0) {
                std.log.err("Mapper {s} failed with status {}", .{ forward_entry.mapper, status });
                continue;
            }

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

            // Write mapped component data to LWW store
            {
                var store_guard = self.lww_store.getMut().lock();
                defer store_guard.deinit();

                _ = store_guard.get().put(
                    store_key,
                    self.clock.send(),
                    .{ .Bytes = mapped },
                    .{ .cause = forward_key.component, .entity = forward_key.entity, .node = self.node_id },
                ) catch |err| {
                    std.log.err("Failed to write to LWW store: {}", .{err});
                    continue;
                };
            }

            // Signal dirty entry to trigger rules
            {
                var queue_guard = self.dirty_queue.getMut().lock();
                defer queue_guard.deinit();

                _ = queue_guard.get().push(.{
                    .entity = forward_key.entity,
                    .component = forward_key.component,
                }) catch |err| {
                    std.log.err("Failed to push dirty entry: {}", .{err});
                };
            }
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

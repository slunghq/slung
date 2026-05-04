const std = @import("std");
const testing = std.testing;
const zwasm = @import("zwasm");

const types = @import("../types.zig");
const queue_mod = @import("../queue.zig");
const wasm_host = @import("../wasm/host.zig");
const wasm_wire = @import("../wasm/wire.zig");
const graph_index = @import("../wasm/index.zig");
const loop_mod = @import("loop.zig");
const context_mod = @import("context.zig");
const Arc = @import("../primitives/arc.zig").Arc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;

const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const InferenceLoop = loop_mod.InferenceLoop;
const RuleDispatcher = loop_mod.RuleDispatcher;

fn deinitIndices(
    allocator: std.mem.Allocator,
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

fn keyBuf(namespace: []const u8, entity: u32, component: u32, buf: *[64]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}:{d}", .{ namespace, entity, component });
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

test "E2E: local rule execution writes derived fact back into active memory" {
    const allocator = testing.allocator;
    const wasm_bytes = @embedFile("../testdata/e2e_local.wasm");

    var forward = graph_index.ForwardIndex{};
    var reverse = graph_index.ReverseIndex{};
    defer deinitIndices(allocator, &forward, &reverse);

    var queue_owner = try queue_mod.QueueOwner.init(allocator, 8, "test_ns", std.testing.io);
    defer queue_owner.deinit();

    const dirty_queue = queue_mod.DirtyQueue{
        .shared = queue_owner.shared.clone(),
        .io = std.testing.io,
    };
    var dirty_queue_arc = try Arc(Mutex(queue_mod.DirtyQueue)).init(
        allocator,
        Mutex(queue_mod.DirtyQueue).init(dirty_queue, std.testing.io),
    );
    defer {
        var guard = dirty_queue_arc.getMut().lock();
        guard.get().decrement();
        guard.deinit();
        dirty_queue_arc.release();
    }

    var lww_arc = try Arc(Mutex(LwwRegistry)).init(
        allocator,
        Mutex(LwwRegistry).init(LwwRegistry.init(allocator), std.testing.io),
    );
    defer {
        var guard = lww_arc.getMut().lock();
        guard.get().deinit();
        guard.deinit();
        lww_arc.release();
    }

    var claim_arc = try Arc(Mutex(ClaimRegister)).init(
        allocator,
        Mutex(ClaimRegister).init(ClaimRegister.init(), std.testing.io),
    );
    defer {
        var guard = claim_arc.getMut().lock();
        guard.get().deinit(allocator);
        guard.deinit();
        claim_arc.release();
    }

    var clock = Hlc.init(1, std.testing.io);
    var wasm_module: *zwasm.WasmModule = undefined;
    var context = Context.init(
        allocator,
        lww_arc,
        dirty_queue_arc,
        claim_arc,
        &forward,
        &reverse,
        &clock,
        wasm_module,
        "test_ns",
        "node-1",
    );

    const env_imports = try wasm_host.createEnvImport(allocator, @intFromPtr(&context));
    defer allocator.free(env_imports.source.host_fns);

    wasm_module = try zwasm.WasmModule.loadWasiWithImports(
        allocator,
        wasm_bytes,
        &[_]zwasm.ImportEntry{env_imports},
        .{},
    );
    defer wasm_module.deinit();
    context.module = wasm_module;

    try wasm_wire.wire(allocator, wasm_module, &forward, &reverse, "test_ns", "e2e_local.wasm");

    try testing.expectEqual(@as(usize, 2), forward.count());
    try testing.expectEqual(@as(usize, 1), reverse.count());

    const reverse_entry = reverse.get(0) orelse return error.MissingRule;
    try testing.expectEqual(@as(usize, 1), reverse_entry.watch.len);
    const reading_key = reverse_entry.watch[0];

    var alert_key_opt: ?graph_index.ForwardKey = null;
    var iter = forward.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.component != reading_key.component) {
            alert_key_opt = entry.key_ptr.*;
            break;
        }
    }
    const alert_key = alert_key_opt orelse return error.MissingDerivedComponent;

    {
        var key_buf_reading: [64]u8 = undefined;
        const reading_store_key = try keyBuf("test_ns", reading_key.entity, reading_key.component, &key_buf_reading);

        var store_guard = lww_arc.getMut().lock();
        defer store_guard.deinit();
        try testing.expect(try store_guard.get().put(
            reading_store_key,
            clock.send(),
            .{ .Float = 42.0 },
            .{ .cause = reading_key.component, .entity = reading_key.entity, .node = "node-1" },
        ));
    }

    {
        var queue_guard = dirty_queue_arc.getMut().lock();
        defer queue_guard.deinit();
        try queue_guard.get().push(.{
            .entity = reading_key.entity,
            .component = reading_key.component,
        });
    }

    var wasm_dispatcher = WasmRuleDispatcher{
        .module = wasm_module,
        .reverse = &reverse,
        .context = &context,
    };
    const dispatcher = RuleDispatcher{
        .ptr = &wasm_dispatcher,
        .dispatch_fn = WasmRuleDispatcher.dispatch,
    };

    var loop = InferenceLoop.init(&context, dispatcher, 8, allocator);
    const fired = try loop.run();
    try testing.expectEqual(@as(usize, 1), fired);

    try testing.expectEqual(@as(types.EntityId, reading_key.entity), context.current_entity);
    try testing.expectEqual(@as(types.RuleId, 0), context.current_rule);

    {
        var key_buf_alert: [64]u8 = undefined;
        const alert_store_key = try keyBuf("test_ns", alert_key.entity, alert_key.component, &key_buf_alert);

        var store_guard = lww_arc.getMut().lock();
        defer store_guard.deinit();
        const derived = store_guard.get().get(alert_store_key) orelse return error.MissingDerivedWrite;
        try testing.expect(derived.value == .Bool);
        try testing.expectEqual(true, derived.value.Bool);
    }

    {
        var queue_guard = dirty_queue_arc.getMut().lock();
        defer queue_guard.deinit();
        try testing.expect(queue_guard.get().is_empty());
    }
}

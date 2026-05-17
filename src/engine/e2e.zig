const std = @import("std");
const testing = std.testing;

const zwasm = @import("zwasm");

const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;
const Arc = @import("../primitives/arc.zig").Arc;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const queue_mod = @import("../queue.zig");
const types = @import("../types.zig");
const wasm_host = @import("../wasm/host.zig");
const graph_index = @import("../wasm/index.zig");
const wasm_wire = @import("../wasm/wire.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const loop_mod = @import("loop.zig");
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

fn invokeMapper(
    wasm_module: *zwasm.WasmModule,
    allocator: std.mem.Allocator,
    mapper_name: []const u8,
    raw_input: []const u8,
) ![]const u8 {
    const input_offset: u32 = 10000;
    const output_offset: u32 = 20000;
    const output_len_offset: u32 = 30000;

    // Write raw input to wasm memory
    try wasm_module.memoryWrite(input_offset, raw_input);

    // Write output_len slot (initialized to 0)
    var output_len_init: [4]u8 = undefined;
    std.mem.writeInt(u32, &output_len_init, 0, .little);
    try wasm_module.memoryWrite(output_len_offset, &output_len_init);

    // Invoke mapper: mapper(input_ptr, input_len, output_ptr, output_len_ptr) -> status
    var results = [_]u64{0};
    try wasm_module.invoke(
        mapper_name,
        &.{ input_offset, raw_input.len, output_offset, output_len_offset },
        results[0..],
    );

    const status: i32 = @bitCast(@as(u32, @intCast(results[0])));
    if (status != 0) {
        return error.MapperFailed;
    }

    // Read output length from memory
    const output_len_bytes = try wasm_module.memoryRead(allocator, output_len_offset, 4);
    defer allocator.free(output_len_bytes);
    const output_len = std.mem.readInt(u32, output_len_bytes[0..4], .little);

    // Read output from wasm memory
    const output = try wasm_module.memoryRead(allocator, output_offset, output_len);

    return output;
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

test "E2E: multi-cycle cascade through rule chain" {
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
        testing.io,
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

    try testing.expectEqual(@as(usize, 3), forward.count());
    try testing.expectEqual(@as(usize, 2), reverse.count());

    var reading_key_opt: ?graph_index.ForwardKey = null;
    var reading_mapper_opt: ?[]const u8 = null;
    var alert_key_opt: ?graph_index.ForwardKey = null;
    {
        var iter = forward.iterator();
        while (iter.next()) |entry| {
            const fwd = entry.value_ptr.*;
            if (std.mem.eql(u8, fwd.source, "LocalExec") and std.mem.eql(u8, fwd.component_type, "Reading")) {
                reading_key_opt = entry.key_ptr.*;
                reading_mapper_opt = fwd.mapper;
            } else if (std.mem.eql(u8, fwd.source, "LocalExec") and std.mem.eql(u8, fwd.component_type, "Alert")) {
                alert_key_opt = entry.key_ptr.*;
            }
        }
    }

    const reading_key = reading_key_opt orelse return error.MissingReadingForward;
    const reading_mapper = reading_mapper_opt orelse return error.MissingReadingMapper;
    const alert_key = alert_key_opt orelse return error.MissingAlertForward;

    var notification_key_opt: ?graph_index.ForwardKey = null;
    {
        var iter = forward.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.component != reading_key.component and
                entry.key_ptr.component != alert_key.component)
            {
                notification_key_opt = entry.key_ptr.*;
                break;
            }
        }
    }
    const notification_key = notification_key_opt orelse return error.MissingNotificationComponent;

    {
        var key_buf_reading: [64]u8 = undefined;
        const reading_store_key = try keyBuf("test_ns", reading_key.entity, reading_key.component, &key_buf_reading);

        const raw_input = "{\"value\": 42.0}";
        const mapped = try invokeMapper(wasm_module, allocator, reading_mapper, raw_input);
        defer allocator.free(mapped);

        var store_guard = lww_arc.getMut().lock();
        defer store_guard.deinit();
        try testing.expect(try store_guard.get().put(
            reading_store_key,
            clock.send(),
            .{ .Bytes = mapped },
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

    var loop = InferenceLoop.init(&context, dispatcher, 10, allocator);
    const fired = try loop.run();
    try testing.expectEqual(@as(usize, 2), fired);

    {
        var key_buf_alert: [64]u8 = undefined;
        const alert_store_key = try keyBuf("test_ns", alert_key.entity, alert_key.component, &key_buf_alert);

        var store_guard = lww_arc.getMut().lock();
        defer store_guard.deinit();
        const alert_value = store_guard.get().get(alert_store_key) orelse return error.MissingAlertWrite;
        try testing.expect(alert_value.value == .Bytes);
        // Alert is now a component struct serialized as JSON
        const alert_parsed = try std.json.parseFromSlice(std.json.Value, allocator, alert_value.value.Bytes, .{});
        defer alert_parsed.deinit();
        const triggered = alert_parsed.value.object.get("triggered") orelse return error.MissingTriggeredField;
        try testing.expectEqual(true, triggered.bool);
    }

    {
        var key_buf_notif: [64]u8 = undefined;
        const notification_store_key = try keyBuf("test_ns", notification_key.entity, notification_key.component, &key_buf_notif);

        var store_guard = lww_arc.getMut().lock();
        defer store_guard.deinit();
        const notification_value = store_guard.get().get(notification_store_key) orelse return error.MissingNotificationWrite;
        try testing.expect(notification_value.value == .Bytes);
        // Notification is now a component struct serialized as JSON
        const notif_parsed = try std.json.parseFromSlice(std.json.Value, allocator, notification_value.value.Bytes, .{});
        defer notif_parsed.deinit();
        const msg = notif_parsed.value.object.get("msg") orelse return error.MissingMsgField;
        try testing.expectEqualStrings("ALERT: reading exceeded threshold", msg.string);
    }

    {
        var queue_guard = dirty_queue_arc.getMut().lock();
        defer queue_guard.deinit();
        try testing.expect(queue_guard.get().is_empty());
    }
}

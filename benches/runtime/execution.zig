//! Runtime execution benchmark

const std = @import("std");
const Allocator = std.mem.Allocator;

const zwasm = @import("zwasm");

const context_mod = @import("../../src/engine/context.zig");
const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const loop_mod = @import("../../src/engine/loop.zig");
const InferenceLoop = loop_mod.InferenceLoop;
const RuleDispatcher = loop_mod.RuleDispatcher;
const LwwRegistry = @import("../../src/memory/lww.zig").LwwRegistry;
const Arc = @import("../../src/primitives/arc.zig").Arc;
const Hlc = @import("../../src/primitives/hlc.zig").Hlc;
const Mutex = @import("../../src/primitives/mutex.zig").Mutex;
const queue_mod = @import("../../src/queue.zig");
const types = @import("../../src/types.zig");
const wasm_host = @import("../../src/wasm/host.zig");
const graph_index = @import("../../src/wasm/index.zig");
const wasm_wire = @import("../../src/wasm/wire.zig");

const n_iters: usize = 100_000;

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

fn invokeMapper(
    wasm_module: *zwasm.WasmModule,
    allocator: Allocator,
    mapper_name: []const u8,
    raw_input: []const u8,
) ![]const u8 {
    const input_offset: u32 = 10000;
    const output_offset: u32 = 20000;
    const output_len_offset: u32 = 30000;

    try wasm_module.memoryWrite(input_offset, raw_input);

    var output_len_init: [4]u8 = undefined;
    std.mem.writeInt(u32, &output_len_init, 0, .little);
    try wasm_module.memoryWrite(output_len_offset, &output_len_init);

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

    const output_len_bytes = try wasm_module.memoryRead(allocator, output_len_offset, 4);
    defer allocator.free(output_len_bytes);
    const output_len = std.mem.readInt(u32, output_len_bytes[0..4], .little);

    return try wasm_module.memoryRead(allocator, output_offset, output_len);
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

pub fn run(allocator: Allocator, io: std.Io) !void {
    std.debug.print("\n=== Runtime Execution ===\n", .{});

    const wasm_bytes = @embedFile("../../src/testdata/e2e_local.wasm");

    var forward = graph_index.ForwardIndex{};
    var reverse = graph_index.ReverseIndex{};
    defer deinitIndices(allocator, &forward, &reverse);

    var queue_owner = try queue_mod.QueueOwner.init(allocator, 8, "bench_ns", io);
    defer queue_owner.deinit();

    const dirty_queue = queue_mod.DirtyQueue{
        .shared = queue_owner.shared.clone(),
        .io = io,
    };
    var dirty_queue_arc = try Arc(Mutex(queue_mod.DirtyQueue)).init(
        allocator,
        Mutex(queue_mod.DirtyQueue).init(dirty_queue, io),
    );
    defer {
        var guard = dirty_queue_arc.getMut().lock();
        guard.get().decrement();
        guard.deinit();
        dirty_queue_arc.release();
    }

    var lww_arc = try Arc(Mutex(LwwRegistry)).init(
        allocator,
        Mutex(LwwRegistry).init(LwwRegistry.init(allocator), io),
    );
    defer {
        var guard = lww_arc.getMut().lock();
        guard.get().deinit();
        guard.deinit();
        lww_arc.release();
    }

    var claim_arc = try Arc(Mutex(ClaimRegister)).init(
        allocator,
        Mutex(ClaimRegister).init(ClaimRegister.init(), io),
    );
    defer {
        var guard = claim_arc.getMut().lock();
        guard.get().deinit(allocator);
        guard.deinit();
        claim_arc.release();
    }

    var clock = Hlc.init(1, io);
    var wasm_module: *zwasm.WasmModule = undefined;
    var context = Context.init(
        allocator,
        io,
        lww_arc,
        dirty_queue_arc,
        claim_arc,
        &forward,
        &reverse,
        &clock,
        wasm_module,
        "bench_ns",
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

    try wasm_wire.wire(allocator, wasm_module, &forward, &reverse, "bench_ns", "e2e_local.wasm");

    var reading_key_opt: ?graph_index.ForwardKey = null;
    var reading_mapper_opt: ?[]const u8 = null;
    var iter = forward.iterator();
    while (iter.next()) |entry| {
        const fwd = entry.value_ptr.*;
        if (std.mem.eql(u8, fwd.source, "LocalExec") and std.mem.eql(u8, fwd.component_type, "Reading")) {
            reading_key_opt = entry.key_ptr.*;
            reading_mapper_opt = fwd.mapper;
            break;
        }
    }

    const reading_key = reading_key_opt orelse return error.MissingReadingForward;
    const reading_mapper = reading_mapper_opt orelse return error.MissingReadingMapper;

    var dispatcher = WasmRuleDispatcher{
        .module = wasm_module,
        .reverse = &reverse,
        .context = &context,
    };
    const rule_dispatcher = RuleDispatcher{
        .ptr = &dispatcher,
        .dispatch_fn = WasmRuleDispatcher.dispatch,
    };
    var loop = InferenceLoop.init(&context, rule_dispatcher, 10, allocator);

    const input = "{\"value\": 42.0}";
    const start = std.Io.Clock.awake.now(io);
    var total_fired: usize = 0;

    for (0..n_iters) |_| {
        const mapped = try invokeMapper(wasm_module, allocator, reading_mapper, input);
        defer allocator.free(mapped);

        var key_buf: [128]u8 = undefined;
        const store_key = try std.fmt.bufPrint(
            &key_buf,
            "{s}:{d}:{d}",
            .{ "bench_ns", reading_key.entity, reading_key.component },
        );

        {
            var store_guard = lww_arc.getMut().lock();
            defer store_guard.deinit();

            _ = try store_guard.get().put(
                store_key,
                clock.send(),
                .{ .Bytes = mapped },
                .{ .cause = reading_key.component, .entity = reading_key.entity, .node = "node-1" },
            );
        }

        {
            var queue_guard = dirty_queue_arc.getMut().lock();
            defer queue_guard.deinit();
            try queue_guard.get().push(.{ .entity = reading_key.entity, .component = reading_key.component });
        }

        total_fired += try loop.run();
    }

    const elapsed_ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ops_per_s = if (elapsed_s > 0) @as(u64, @intFromFloat(@as(f64, n_iters) / elapsed_s)) else 0;

    std.debug.print(
        "  {d} updates in {d:.2}s - {d} updates/s - {d} rules fired\n",
        .{ n_iters, elapsed_s, ops_per_s, total_fired },
    );
}

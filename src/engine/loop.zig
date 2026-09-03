//! Inference Loop — Main event-driven execution engine
//!
//! Orchestrates the reactive cycle:
//! 1. Poll dirty queue for changed facts
//! 2. Look up candidate rules via forward index
//! 3. Check claims to prevent duplicate execution
//! 4. Sort candidates by priority
//! 5. Dispatch to Wasm rule entrypoints
//! 6. Collect writes (automatic via slung_set)
//! 7. Re-signal dirty for transitive rules
//! 8. Repeat until convergence or max depth reached
//!
//! The loop is namespace-aware and supports concurrent workers
//! via shared Arc<Mutex<>> state in the context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const queue_mod = @import("../queue.zig");
const types = @import("../types.zig");
const DirtyEntry = types.DirtyEntry;
const graph_index = @import("../wasm/index.zig");
const context_mod = @import("./context.zig");
const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;

/// Rule dispatcher interface — allows mocking Wasm invocation in tests.
pub const RuleDispatcher = struct {
    const DispatchFn = *const fn (dispatcher: *anyopaque, rule_id: types.RuleId, entity_id: types.EntityId) anyerror!i32;

    ptr: *anyopaque,
    dispatch_fn: DispatchFn,

    pub fn dispatch(self: RuleDispatcher, rule_id: types.RuleId, entity_id: types.EntityId) !i32 {
        return self.dispatch_fn(self.ptr, rule_id, entity_id);
    }
};

/// Candidate rule for execution — pairs rule_id with its priority for sorting.
const Candidate = struct {
    rule_id: types.RuleId,
    priority: u8,

    pub fn lessThan(ctx: void, a: Candidate, b: Candidate) bool {
        _ = ctx;
        // Higher priority first
        return a.priority > b.priority;
    }
};

/// Inference Loop — single-worker synchronous execution.
///
/// Processes dirty entries until queue is empty or max_depth cycles reached.
/// Thread-safe via Arc<Mutex<>> in context; call from one worker at a time
/// or synchronize via external locking.
pub const InferenceLoop = struct {
    const Self = @This();

    context: *Context,
    dispatcher: RuleDispatcher,
    max_depth: usize,
    allocator: Allocator,
    /// Initialize the inference loop.
    pub fn init(
        context: *Context,
        dispatcher: RuleDispatcher,
        max_depth: usize,
        allocator: Allocator,
    ) Self {
        return .{
            .context = context,
            .dispatcher = dispatcher,
            .max_depth = max_depth,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Run one complete inference cycle driven by one dirty entry.
    /// Returns the number of rules fired and the durable dirty ID (if any).
    pub fn runCycle(self: *Self) !struct { fired: usize, durable_id: ?i64 } {
        return self.runCycleWithSource(true);
    }

    fn runCycleWithSource(self: *Self, use_durable_source: bool) !struct { fired: usize, durable_id: ?i64 } {
        var rules_fired: usize = 0;

        var durable_id: ?i64 = null;
        const dirty_entry = if (use_durable_source and self.context.storage != null) blk: {
            const pending = (try self.context.nextPendingDirty()) orelse
                return .{ .fired = 0, .durable_id = null };
            durable_id = pending.id;
            defer pending.deinit(self.allocator);
            break :blk DirtyEntry{ .entity = pending.entity, .component = pending.component };
        } else blk: {
            var queue_guard = self.context.dirty_queue.getMut().lock();
            defer queue_guard.deinit();
            const queued = queue_guard.get().pop() orelse
                return .{ .fired = 0, .durable_id = null };
            break :blk DirtyEntry{ .entity = queued.entry.entity, .component = queued.entry.component };
        };

        const key = graph_index.ForwardKey{
            .entity = dirty_entry.entity,
            .component = dirty_entry.component,
        };

        const forward_entry = self.context.forward_index.get(key) orelse
            return .{ .fired = 0, .durable_id = durable_id };
        const candidate_rule_ids = forward_entry.watchers;

        if (candidate_rule_ids.len == 0)
            return .{ .fired = 0, .durable_id = durable_id };

        var candidates = try self.allocator.alloc(Candidate, candidate_rule_ids.len);
        defer self.allocator.free(candidates);

        for (candidate_rule_ids, 0..) |rule_id, i| {
            const reverse_entry = self.context.reverse_index.get(rule_id) orelse continue;
            candidates[i] = .{ .rule_id = rule_id, .priority = reverse_entry.priority };
        }

        std.mem.sort(Candidate, candidates, {}, Candidate.lessThan);

        for (candidates) |candidate| {
            const rule_id = candidate.rule_id;
            const entity_id = dirty_entry.entity;

            const should_execute = blk: {
                var claim_guard = self.context.claim_register.getMut().lock();
                defer claim_guard.deinit();
                break :blk try claim_guard.get().tryAcquire(self.allocator, rule_id, entity_id);
            };
            if (!should_execute) continue;

            self.context.setCurrentExecution(entity_id, rule_id);

            const return_code = self.dispatcher.dispatch(rule_id, entity_id) catch |err| {
                var claim_guard = self.context.claim_register.getMut().lock();
                defer claim_guard.deinit();
                claim_guard.get().release(rule_id, entity_id);
                return err;
            };

            {
                var claim_guard = self.context.claim_register.getMut().lock();
                defer claim_guard.deinit();
                claim_guard.get().release(rule_id, entity_id);
            }

            if (return_code != 0)
                std.debug.print("Rule {d} returned error code {d}\n", .{ rule_id, return_code });

            rules_fired += 1;
        }

        return .{ .fired = rules_fired, .durable_id = durable_id };
    }

    pub const RunTiming = struct {
        fired: usize,
        execution_ns: u64,
        checkpoint_ns: u64,
    };

    fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
        return @intCast(start.untilNow(io, .awake).toNanoseconds());
    }

    fn hasReadyWork(self: *Self) bool {
        var queue_guard = self.context.dirty_queue.getMut().lock();
        defer queue_guard.deinit();
        return !queue_guard.get().is_empty();
    }

    /// Run the full inference cascade from one dirty entry until convergence.
    /// Flushes all rule-produced outputs as one WAL cascade checkpoint when done.
    /// Returns total number of rules fired.
    pub fn run(self: *Self) !usize {
        return (try self.runTimed()).fired;
    }

    /// Benchmark/diagnostic form of run. Separates in-memory rule execution
    /// from the final cascade checkpoint without changing execution behavior.
    pub fn runTimed(self: *Self) !RunTiming {
        self.context.beginCascade();
        var total_fired: usize = 0;
        var durable_id: ?i64 = null;
        var converged = false;
        const execution_start = std.Io.Clock.awake.now(self.context.io);

        for (0..self.max_depth) |depth| {
            const result = try self.runCycleWithSource(depth == 0);
            if (self.context.getCascadeError()) |err| {
                self.context.discardCascade();
                return err;
            }
            // Capture the dirty ID from the first cycle; subsequent cycles are
            // transitive and do not have their own durable IDs.
            if (durable_id == null) durable_id = result.durable_id;
            total_fired += result.fired;
            if (result.fired == 0 and !self.hasReadyWork()) {
                converged = true;
                break;
            }
        }

        if (!converged and self.context.storage != null and self.hasReadyWork()) {
            self.context.discardCascade();
            return error.MaxDepthExceeded;
        }

        const execution_ns = elapsedNs(self.context.io, execution_start);
        const checkpoint_start = std.Io.Clock.awake.now(self.context.io);

        // Flush all accumulated cascade outputs + ack the triggering dirty entry.
        if (durable_id) |id| {
            self.context.flushCascade(id) catch |err| {
                std.log.err("cascade flush failed: {}", .{err});
                self.context.discardCascade();
                return err;
            };
        } else {
            self.context.discardCascade();
        }

        return .{
            .fired = total_fired,
            .execution_ns = execution_ns,
            .checkpoint_ns = elapsedNs(self.context.io, checkpoint_start),
        };
    }
};

// Tests

test "InferenceLoop: init" {
    const ctx: *Context = undefined;
    const dispatcher = RuleDispatcher{
        .ptr = undefined,
        .dispatch_fn = undefined,
    };

    const loop = InferenceLoop.init(ctx, dispatcher, 100, testing.allocator);
    try testing.expectEqual(@as(usize, 100), loop.max_depth);
}

test "InferenceLoop: runCycle returns zero with no candidates" {
    var forward_index = graph_index.ForwardIndex{};
    defer forward_index.deinit(testing.allocator);

    var reverse_index = graph_index.ReverseIndex{};
    defer reverse_index.deinit(testing.allocator);

    // For this test, we just verify the basic structure compiles
    // Full integration tests will mock the dispatcher and verify behavior
}

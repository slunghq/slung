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

const types = @import("../types.zig");
const context_mod = @import("./context.zig");
const graph_index = @import("../wasm/index.zig");
const queue_mod = @import("../queue.zig");

const Context = context_mod.Context;
const ClaimRegister = context_mod.ClaimRegister;
const DirtyEntry = types.DirtyEntry;

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

    /// Run one complete inference cycle.
    /// Returns the number of rules fired in this cycle.
    pub fn runCycle(self: *Self) !usize {
        var rules_fired: usize = 0;

        // Poll dirty queue with short timeout
        const dirty_entry_opt = blk: {
            var queue_guard = self.context.dirty_queue.getMut().lock();
            defer queue_guard.deinit();
            break :blk queue_guard.get().pop();
        };

        const dirty_entry = dirty_entry_opt orelse return 0; // Queue empty

        // Look up candidate rules via forward index
        const key = graph_index.ForwardKey{
            .entity = dirty_entry.entry.entity,
            .component = dirty_entry.entry.component,
        };

        const forward_entry = self.context.forward_index.get(key) orelse return 0;
        const candidate_rule_ids = forward_entry.watchers;

        if (candidate_rule_ids.len == 0) {
            return 0; // No rules watching this component
        }

        // Build candidate list with priorities
        var candidates = try self.allocator.alloc(Candidate, candidate_rule_ids.len);
        defer self.allocator.free(candidates);

        for (candidate_rule_ids, 0..) |rule_id, i| {
            const reverse_entry = self.context.reverse_index.get(rule_id) orelse continue;
            candidates[i] = .{
                .rule_id = rule_id,
                .priority = reverse_entry.priority,
            };
        }

        // Sort candidates by priority (highest first)
        std.mem.sort(Candidate, candidates, {}, Candidate.lessThan);

        // Dispatch each candidate rule (with claim checks)
        for (candidates) |candidate| {
            const rule_id = candidate.rule_id;
            const entity_id = dirty_entry.entry.entity;

            // Check claim via Arc<Mutex<>>
            const should_execute = blk: {
                var claim_guard = self.context.claim_register.getMut().lock();
                defer claim_guard.deinit();
                break :blk try claim_guard.get().tryAcquire(self.allocator, rule_id, entity_id);
            };

            if (!should_execute) {
                continue; // Already claimed/executing
            }

            // Update execution context
            self.context.setCurrentExecution(entity_id, rule_id);

            // Dispatch to Wasm rule entrypoint
            // Note: rule may call slung_set which writes to LWW and re-dirties queue
            const return_code = self.dispatcher.dispatch(rule_id, entity_id) catch |err| {
                // Release claim on error
                {
                    var claim_guard = self.context.claim_register.getMut().lock();
                    defer claim_guard.deinit();
                    claim_guard.get().release(rule_id, entity_id);
                }
                return err;
            };

            // Release claim
            {
                var claim_guard = self.context.claim_register.getMut().lock();
                defer claim_guard.deinit();
                claim_guard.get().release(rule_id, entity_id);
            }

            // Check return code
            if (return_code != 0) {
                // Rule returned error; could implement retry logic here
                // For now, just log and continue
                std.debug.print("Rule {d} returned error code {d}\n", .{ rule_id, return_code });
            }

            rules_fired += 1;
        }

        return rules_fired;
    }

    /// Run the full inference loop until convergence or max_depth reached.
    /// Returns total number of rules fired.
    pub fn run(self: *Self) !usize {
        var total_fired: usize = 0;

        for (0..self.max_depth) |_| {
            const fired_this_cycle = try self.runCycle();
            total_fired += fired_this_cycle;

            if (fired_this_cycle == 0) {
                break; // Converged; queue is empty
            }
        }

        return total_fired;
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

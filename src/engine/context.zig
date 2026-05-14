//! Runtime Context — state injection for rule execution
//!
//! Holds all runtime state needed during inference loop and rule execution:
//! + Shared memory (LWW store, dirty queue)
//! + Shared indices (forward/reverse capability graph)
//! + Current execution context (namespace, entity, rule)
//! + Clock and claim register
//!
//! Passed to:
//! + Wasm rule entrypoints via host ABI
//! + Inference loop for fact lookups and writes
//! + Claim checks for duplicate prevention

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const zwasm = @import("zwasm");

const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;
const Arc = @import("../primitives/arc.zig").Arc;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const DirtyQueue = @import("../queue.zig").DirtyQueue;
const types = @import("../types.zig");
const graph_index = @import("../wasm/index.zig");

/// Claim register: tracks (RuleId, EntityId) pairs currently executing.
/// Prevents duplicate rule execution within the same inference cycle.
pub const ClaimRegister = struct {
    const Self = @This();

    /// Key for claim tracking: rule_id and entity_id pair
    const ClaimKey = struct {
        rule_id: types.RuleId,
        entity_id: types.EntityId,

        pub fn hash(self: ClaimKey) u64 {
            return (@as(u64, self.rule_id) << 32) | self.entity_id;
        }

        pub fn eql(a: ClaimKey, b: ClaimKey) bool {
            return a.rule_id == b.rule_id and a.entity_id == b.entity_id;
        }
    };

    /// Map from (RuleId, EntityId) to void (simple occupancy tracker)
    claims: std.AutoHashMapUnmanaged(ClaimKey, void),

    pub fn init() Self {
        return .{ .claims = .{} };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.claims.deinit(allocator);
    }

    /// Try to acquire a claim for (rule_id, entity_id).
    /// Returns true if claim was acquired; false if already claimed.
    pub fn tryAcquire(self: *Self, allocator: Allocator, rule_id: types.RuleId, entity_id: types.EntityId) !bool {
        const key = ClaimKey{ .rule_id = rule_id, .entity_id = entity_id };
        const result = try self.claims.getOrPut(allocator, key);
        if (result.found_existing) {
            return false; // Already claimed
        }
        return true; // Claim acquired
    }

    /// Release a claim for (rule_id, entity_id).
    pub fn release(self: *Self, rule_id: types.RuleId, entity_id: types.EntityId) void {
        const key = ClaimKey{ .rule_id = rule_id, .entity_id = entity_id };
        _ = self.claims.remove(key);
    }

    /// Check if (rule_id, entity_id) is currently claimed.
    pub fn isClaimed(self: *Self, rule_id: types.RuleId, entity_id: types.EntityId) bool {
        const key = ClaimKey{ .rule_id = rule_id, .entity_id = entity_id };
        return self.claims.contains(key);
    }
};

/// Runtime Context — passed to rule entrypoints and inference loop.
///
/// Thread-safe access to shared state via Arc<Mutex<>>.
/// Current execution context (namespace, entity, rule) is mutable for each cycle.
pub const Context = struct {
    const Self = @This();

    // Shared state (wrapped in Arc<Mutex<>> for thread-safe access)
    lww_store: Arc(Mutex(LwwRegistry)),
    dirty_queue: Arc(Mutex(DirtyQueue)),
    claim_register: Arc(Mutex(ClaimRegister)),

    // Indices (precomputed, read-only)
    forward_index: *graph_index.ForwardIndex,
    reverse_index: *graph_index.ReverseIndex,

    // Clock for Hlc timestamps
    clock: *Hlc,

    // Wasm module for memory access from host functions
    module: *zwasm.WasmModule,

    // Current execution context (mutable per cycle)
    namespace: types.NamespaceId,
    current_entity: types.EntityId,
    current_rule: types.RuleId,

    // Node ID for causal tags
    node_id: types.NodeId,

    // Allocator for runtime allocations
    allocator: Allocator,
    io: std.Io,

    /// Initialize context with shared resources.
    pub fn init(
        allocator: Allocator,
        io: std.Io,
        lww_store: Arc(Mutex(LwwRegistry)),
        dirty_queue: Arc(Mutex(DirtyQueue)),
        claim_register: Arc(Mutex(ClaimRegister)),
        forward_index: *graph_index.ForwardIndex,
        reverse_index: *graph_index.ReverseIndex,
        clock: *Hlc,
        module: *zwasm.WasmModule,
        namespace: types.NamespaceId,
        node_id: types.NodeId,
    ) Self {
        return .{
            .io = io,
            .lww_store = lww_store,
            .dirty_queue = dirty_queue,
            .claim_register = claim_register,
            .forward_index = forward_index,
            .reverse_index = reverse_index,
            .clock = clock,
            .module = module,
            .namespace = namespace,
            .current_entity = 0,
            .current_rule = 0,
            .node_id = node_id,
            .allocator = allocator,
        };
    }

    /// Update current execution context (entity and rule).
    /// Called when dispatching to a rule.
    pub fn setCurrentExecution(self: *Self, entity_id: types.EntityId, rule_id: types.RuleId) void {
        self.current_entity = entity_id;
        self.current_rule = rule_id;
    }
};

// Tests
test "ClaimRegister: acquire and release" {
    var reg = ClaimRegister.init();
    defer reg.deinit(testing.allocator);

    try testing.expect(try reg.tryAcquire(testing.allocator, 1, 1));

    try testing.expect(!try reg.tryAcquire(testing.allocator, 1, 1));

    try testing.expect(try reg.tryAcquire(testing.allocator, 2, 1));

    reg.release(1, 1);
    try testing.expect(try reg.tryAcquire(testing.allocator, 1, 1));
}

test "ClaimRegister: isClaimed" {
    var reg = ClaimRegister.init();
    defer reg.deinit(testing.allocator);

    try testing.expect(!reg.isClaimed(1, 1));
    _ = try reg.tryAcquire(testing.allocator, 1, 1);
    try testing.expect(reg.isClaimed(1, 1));
    reg.release(1, 1);
    try testing.expect(!reg.isClaimed(1, 1));
}

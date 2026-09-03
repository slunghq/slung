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

const zio = @import("zio");
const zwasm = @import("zwasm");

const LwwRegistry = @import("../memory/lww.zig").LwwRegistry;
const Arc = @import("../primitives/arc.zig").Arc;
const Hlc = @import("../primitives/hlc.zig").Hlc;
const Mutex = @import("../primitives/mutex.zig").Mutex;
const DirtyQueue = @import("../queue.zig").DirtyQueue;
const types = @import("../types.zig");
const graph_index = @import("../wasm/index.zig");
const Storage = @import("../storage.zig").Storage;

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
    storage: ?*Storage,

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

    // Cascade accumulator: rule-produced mutations collected during propagation.
    // Flushed to WAL as one checkpoint after cascade convergence.
    cascade_outputs: std.ArrayListUnmanaged(Storage.FactMutation) = .empty,
    cascade_error: ?anyerror = null,

    pub fn beginCascade(self: *Self) void {
        self.cascade_error = null;
    }

    pub fn recordCascadeError(self: *Self, err: anyerror) void {
        if (self.cascade_error == null) self.cascade_error = err;
    }

    pub fn getCascadeError(self: *Self) ?anyerror {
        return self.cascade_error;
    }

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
        storage: ?*Storage,
    ) Self {
        return .{
            .io = io,
            .lww_store = lww_store,
            .dirty_queue = dirty_queue,
            .claim_register = claim_register,
            .storage = storage,
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

    /// Source ingestion checkpoint: persists the input fact durably before execution.
    pub fn persistMutation(self: *Self, mutation: Storage.FactMutation) !bool {
        var accepted = [_]bool{false};
        try self.persistMutations(&.{mutation}, accepted[0..]);
        return accepted[0];
    }

    pub fn persistMutations(
        self: *Self,
        mutations: []const Storage.FactMutation,
        accepted: []bool,
    ) !void {
        const storage = self.storage orelse return error.StorageUnavailable;
        if (storage.durability == .eventual) {
            return storage.applyMutations(mutations, accepted);
        }
        var task = try zio.spawnBlocking(persistMutationsBlocking, .{ storage, mutations, accepted });
        try task.join();
    }

    fn persistMutationsBlocking(
        storage: *Storage,
        mutations: []const Storage.FactMutation,
        accepted: []bool,
    ) !void {
        try storage.applyMutations(mutations, accepted);
    }

    /// Records a rule-produced mutation into the cascade accumulator.
    /// Updates the LWW store immediately; WAL write is deferred to flushCascade.
    pub fn accumulateMutation(self: *Self, mutation: Storage.FactMutation) !bool {
        // Copy slices because the caller's buffers are transient.
        const owned = Storage.FactMutation{
            .namespace = try self.allocator.dupe(u8, mutation.namespace),
            .entity = mutation.entity,
            .component = mutation.component,
            .value = try self.allocator.dupe(u8, mutation.value),
            .timestamp = mutation.timestamp,
            .cause = .{
                .cause = mutation.cause.cause,
                .entity = mutation.cause.entity,
                .node = try self.allocator.dupe(u8, mutation.cause.node),
            },
        };
        try self.cascade_outputs.append(self.allocator, owned);
        return true;
    }

    /// Writes accumulated cascade outputs + dirty ack as one WAL checkpoint.
    /// Called by the inference loop after a cascade converges.
    pub fn flushCascade(self: *Self, ack_id: i64) !void {
        defer {
            for (self.cascade_outputs.items) |m| {
                self.allocator.free(m.namespace);
                self.allocator.free(m.value);
                self.allocator.free(m.cause.node);
            }
            self.cascade_outputs.clearRetainingCapacity();
        }
        const storage = self.storage orelse return;
        try storage.flushCascade(self.cascade_outputs.items, ack_id);
    }

    /// Clears the cascade accumulator without writing (used on error paths).
    pub fn discardCascade(self: *Self) void {
        for (self.cascade_outputs.items) |m| {
            self.allocator.free(m.namespace);
            self.allocator.free(m.value);
            self.allocator.free(m.cause.node);
        }
        self.cascade_outputs.clearRetainingCapacity();
    }

    /// Frees cascade accumulator memory. Call during context teardown.
    pub fn deinit(self: *Self) void {
        self.discardCascade();
        self.cascade_outputs.deinit(self.allocator);
    }

    /// Direct in-memory fact read. No WAL I/O on the hot path.
    pub fn loadFact(
        self: *Self,
        entity: types.EntityId,
        component: types.ComponentId,
    ) !?Storage.Fact {
        const storage = self.storage orelse return null;
        return storage.getFact(self.namespace, entity, component);
    }

    /// Direct in-memory pending read. No WAL I/O on the hot path.
    pub fn nextPendingDirty(self: *Self) !?Storage.PendingDirty {
        const storage = self.storage orelse return null;
        return storage.nextPendingDirtyFor(self.namespace);
    }

    pub fn acknowledgeDirty(self: *Self, id: i64) !void {
        const storage = self.storage orelse return;
        try storage.acknowledgeDirty(id);
    }

    pub fn acknowledgeDirtyBatch(self: *Self, ids: []const i64) !void {
        const storage = self.storage orelse return;
        try storage.acknowledgeDirtyBatch(ids);
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

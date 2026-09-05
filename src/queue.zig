//! Dirty Queue — MPMC signal channel for state change notifications.
//!
//! The dirty queue is the primary signaling mechanism between the memory layer (writers)
//! and the inference engine (consumers). When a fact is written via slung_set, a DirtyEntry
//! is enqueued; workers poll the queue to discover which entities need re-evaluation.
//!
//! Design:
//! + Thread-safe FIFO queue wrapped in Arc<Mutex<>>
//! + Supports concurrent push() from multiple threads (writers)
//! + Supports concurrent pop() from multiple threads (workers)
//! + Optional blocking pop with timeout (for efficient worker scheduling)
//! + Namespace-scoped isolation (entries tagged with NamespaceId for filtering)
//! + Allocator ownership managed via wrapper struct to ensure cleanup
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Arc = @import("./primitives/arc.zig").Arc;
const Mutex = @import("./primitives/mutex.zig").Mutex;
const DirtyEntry = @import("./types.zig").DirtyEntry;
const NamespaceId = @import("./types.zig").NamespaceId;

/// A single entry in the dirty queue, tagged with its namespace for filtering.
pub const NamespacedDirtyEntry = struct {
    namespace: NamespaceId,
    entry: DirtyEntry,
};

/// Inner queue state: circular buffer + head/tail pointers + count.
/// This struct only manages the queue logic; allocator is held by the wrapper.
pub const QueueInner = struct {
    entries: []NamespacedDirtyEntry,
    head: usize,
    tail: usize,
    count: usize,
    namespace: NamespaceId,

    /// Initialize the queue with a given capacity and namespace.
    /// Caller must pass pre-allocated buffer.
    pub fn init(entries: []NamespacedDirtyEntry, namespace: NamespaceId) QueueInner {
        return .{
            .entries = entries,
            .head = 0,
            .tail = 0,
            .count = 0,
            .namespace = namespace,
        };
    }

    /// Push an entry to the queue (must hold the lock).
    /// Returns an error if the queue is full.
    pub fn push(self: *QueueInner, entry: DirtyEntry) !void {
        if (self.count >= self.entries.len) {
            return error.QueueFull;
        }
        self.entries[self.tail] = .{
            .namespace = self.namespace,
            .entry = entry,
        };
        self.tail = (self.tail + 1) % self.entries.len;
        self.count += 1;
    }

    /// Pop an entry from the queue (must hold the lock).
    /// Returns null if the queue is empty.
    pub fn pop(self: *QueueInner) ?NamespacedDirtyEntry {
        if (self.count == 0) {
            return null;
        }
        const item = self.entries[self.head];
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;
        return item;
    }

    pub fn removeLast(self: *QueueInner, entity: u32, component: u32) bool {
        if (self.count == 0) return false;
        var target: ?usize = null;
        for (0..self.count) |offset| {
            const index = (self.head + offset) % self.entries.len;
            const entry = self.entries[index].entry;
            if (entry.entity == entity and entry.component == component) target = offset;
        }
        const target_offset = target orelse return false;
        const original_count = self.count;
        for (0..original_count) |offset| {
            const item = self.pop().?;
            if (offset != target_offset) self.push(item.entry) catch unreachable;
        }
        return true;
    }

    /// Current number of entries in the queue (must hold the lock).
    pub fn size(self: *QueueInner) usize {
        return self.count;
    }

    /// Whether the queue is empty (must hold the lock).
    pub fn is_empty(self: *QueueInner) bool {
        return self.count == 0;
    }

    pub fn is_full(self: *QueueInner) bool {
        return self.count >= self.entries.len;
    }
};

/// Wrapper that owns both the allocator and the shared queue.
/// Ensures buffer allocation is freed when the wrapper is destroyed.
pub const QueueOwner = struct {
    shared: Arc(Mutex(QueueInner)),
    buffer: []NamespacedDirtyEntry,
    allocator: Allocator,

    /// Create a new queue owner with the given capacity and namespace.
    pub fn init(allocator: Allocator, capacity: usize, namespace: NamespaceId, io: std.Io) !QueueOwner {
        const buffer = try allocator.alloc(NamespacedDirtyEntry, capacity);
        const inner = QueueInner.init(buffer, namespace);
        const mutex_inner = Mutex(QueueInner).init(inner, io);
        const arc = try Arc(Mutex(QueueInner)).init(allocator, mutex_inner);
        return .{
            .shared = arc,
            .buffer = buffer,
            .allocator = allocator,
        };
    }

    /// Manually deinitialize and free resources.
    /// Must be called exactly once per QueueOwner.
    pub fn deinit(self: QueueOwner) void {
        self.shared.release();
        self.allocator.free(self.buffer);
    }
};

/// Thread-safe dirty queue shared via Arc<Mutex<>>.
/// Users interact with this via push/pop_blocking/etc.
/// Lifecycle is managed by QueueOwner; DirtyQueue is a cheap handle.
pub const DirtyQueue = struct {
    const Self = @This();

    shared: Arc(Mutex(QueueInner)),
    io: std.Io,

    /// Clone the handle to this queue (increments Arc refcount).
    /// The underlying queue remains valid as long as the QueueOwner is alive.
    pub fn clone(self: Self) Self {
        return .{ .shared = self.shared.clone(), .io = self.io };
    }

    /// Decrement the Arc refcount for this handle.
    /// Call this when you're done with a cloned handle, or let it drop (but only in tests).
    /// QueueOwner.deinit() will free the buffer when the last Arc is released.
    pub fn decrement(self: Self) void {
        self.shared.release();
    }

    /// Push an entry to the queue (non-blocking, acquires lock).
    /// Returns QueueFull if at capacity.
    pub fn push(self: Self, entry: DirtyEntry) !void {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        try guard.get().*.push(entry);
    }

    pub fn isFull(self: Self) bool {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        return guard.get().*.is_full();
    }

    /// Pop an entry from the queue without blocking (acquires lock).
    /// Returns null if empty.
    pub fn pop(self: Self) ?NamespacedDirtyEntry {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        return guard.get().*.pop();
    }

    /// Attempt to pop with a timeout in nanoseconds (acquires lock repeatedly).
    /// Spins/yields until timeout or entry available; useful for efficient polling.
    /// Returns null if timeout expires with empty queue.
    pub fn pop_blocking(self: Self, timeout_ns: u64) ?NamespacedDirtyEntry {
        const start: i128 = @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds());
        const deadline = start + @as(i128, @intCast(timeout_ns));

        while (true) {
            if (self.pop()) |entry| {
                return entry;
            }

            const now: i128 = @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds());
            if (now >= deadline) {
                return null;
            }

            const remaining = deadline - now;
            const remaining_u64: u64 = @as(u64, @intCast(@max(1, @divTrunc(remaining, 10))));
            const sleep_ns: u64 = @min(1_000_000, remaining_u64); // 1ms or 10% of remaining
            self.io.sleep(std.Io.Duration.fromNanoseconds(sleep_ns), .awake) catch {};
        }
    }

    /// Get the current queue size (acquires lock).
    pub fn size(self: Self) usize {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        return guard.get().*.size();
    }

    /// Check if the queue is empty (acquires lock).
    pub fn is_empty(self: Self) bool {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        return guard.get().*.is_empty();
    }

    /// Clear all entries (acquires lock).
    pub fn clear(self: Self) void {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        guard.get().*.head = 0;
        guard.get().*.tail = 0;
        guard.get().*.count = 0;
    }

    pub fn removeLast(self: Self, entity: u32, component: u32) bool {
        const mutex = self.shared.getMut();
        var guard = mutex.lock();
        defer guard.deinit();
        return guard.get().*.removeLast(entity, component);
    }
};

test "DirtyQueue: init and basic operations" {
    var owner = try QueueOwner.init(testing.allocator, 10, "test_ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try testing.expect(queue.is_empty());
    try testing.expectEqual(@as(usize, 0), queue.size());

    try queue.push(.{ .entity = 1, .component = 2 });
    try testing.expectEqual(@as(usize, 1), queue.size());
    try testing.expect(!queue.is_empty());
}

test "DirtyQueue: push and pop" {
    var owner = try QueueOwner.init(testing.allocator, 10, "ns1", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 1, .component = 2 });
    try queue.push(.{ .entity = 3, .component = 4 });

    const entry1 = queue.pop();
    try testing.expect(entry1 != null);
    try testing.expectEqual(@as(u32, 1), entry1.?.entry.entity);
    try testing.expectEqual(@as(u32, 2), entry1.?.entry.component);
    try testing.expectEqualStrings("ns1", entry1.?.namespace);

    const entry2 = queue.pop();
    try testing.expect(entry2 != null);
    try testing.expectEqual(@as(u32, 3), entry2.?.entry.entity);
    try testing.expectEqual(@as(u32, 4), entry2.?.entry.component);

    const empty = queue.pop();
    try testing.expect(empty == null);
}

test "DirtyQueue: size and is_empty" {
    var owner = try QueueOwner.init(testing.allocator, 10, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try testing.expectEqual(@as(usize, 0), queue.size());
    try testing.expect(queue.is_empty());

    try queue.push(.{ .entity = 5, .component = 6 });
    try testing.expectEqual(@as(usize, 1), queue.size());
    try testing.expect(!queue.is_empty());

    _ = queue.pop();
    try testing.expectEqual(@as(usize, 0), queue.size());
    try testing.expect(queue.is_empty());
}

test "DirtyQueue: queue full error" {
    var owner = try QueueOwner.init(testing.allocator, 2, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 1, .component = 1 });
    try queue.push(.{ .entity = 2, .component = 2 });

    const result = queue.push(.{ .entity = 3, .component = 3 });
    try testing.expectError(error.QueueFull, result);
}

test "DirtyQueue: circular buffer wraparound" {
    var owner = try QueueOwner.init(testing.allocator, 3, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 1, .component = 1 });
    try queue.push(.{ .entity = 2, .component = 2 });
    try queue.push(.{ .entity = 3, .component = 3 });

    _ = queue.pop();
    _ = queue.pop();
    _ = queue.pop();

    try queue.push(.{ .entity = 4, .component = 4 });
    try queue.push(.{ .entity = 5, .component = 5 });

    const e1 = queue.pop();
    try testing.expectEqual(@as(u32, 4), e1.?.entry.entity);

    const e2 = queue.pop();
    try testing.expectEqual(@as(u32, 5), e2.?.entry.entity);
}

test "DirtyQueue: clone and shared ownership" {
    var owner = try QueueOwner.init(testing.allocator, 10, "shared_ns", std.testing.io);
    defer owner.deinit();

    var q1 = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };
    var q2 = q1.clone();

    try q1.push(.{ .entity = 10, .component = 20 });
    try testing.expectEqual(@as(usize, 1), q2.size());

    const entry = q2.pop();
    try testing.expect(entry != null);
    try testing.expectEqual(@as(u32, 10), entry.?.entry.entity);
    try testing.expect(q1.is_empty());

    q2.decrement();
}

test "DirtyQueue: namespace tagging" {
    var owner = try QueueOwner.init(testing.allocator, 10, "prod", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 1, .component = 1 });
    const entry = queue.pop();
    try testing.expect(entry != null);
    try testing.expectEqualStrings("prod", entry.?.namespace);
}

test "DirtyQueue: pop_blocking with immediate entry" {
    var owner = try QueueOwner.init(testing.allocator, 10, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 42, .component = 99 });
    const entry = queue.pop_blocking(1_000_000); // 1ms timeout
    try testing.expect(entry != null);
    try testing.expectEqual(@as(u32, 42), entry.?.entry.entity);
}

test "DirtyQueue: pop_blocking timeout" {
    var owner = try QueueOwner.init(testing.allocator, 10, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    const start: i128 = @intCast(std.Io.Clock.awake.now(std.testing.io).toNanoseconds());
    const entry = queue.pop_blocking(1_000_000); // 1ms timeout
    const elapsed: i128 = @as(i128, @intCast(std.Io.Clock.awake.now(std.testing.io).toNanoseconds())) - start;

    try testing.expect(entry == null);
    try testing.expect(elapsed >= 1_000_000); // Should take at least 1ms
}

test "DirtyQueue: clear" {
    var owner = try QueueOwner.init(testing.allocator, 10, "ns", std.testing.io);
    defer owner.deinit();

    var queue = DirtyQueue{ .shared = owner.shared, .io = std.testing.io };

    try queue.push(.{ .entity = 1, .component = 1 });
    try queue.push(.{ .entity = 2, .component = 2 });
    try testing.expectEqual(@as(usize, 2), queue.size());

    queue.clear();
    try testing.expectEqual(@as(usize, 0), queue.size());
    try testing.expect(queue.is_empty());
}

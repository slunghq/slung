//! Arc(T) - Atomic Reference Counted smart pointer
//!
//! Provides shared ownership of a heap-allocated value T across threads.
//! The inner value is freed when the last reference is released.
//!
//! Design:
//! - Inner struct holds T + atomic refcount, allocated once on init
//! - retain() increments refcount with AcqRel ordering
//! - release() decrements and frees on zero with AcqRel ordering
//! - clone() returns a new Arc pointing at the same inner allocation
//! - Caller owns the Arc value - copy it to share, never alias the pointer
//!
//! Thread safety: retain/release are safe to call from multiple threads.
//! Mutating the inner value is NOT safe without external synchronisation -
//! use Arc(Mutex(T)) for mutable shared state.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AtomicUsize = std.atomic.Value(usize);

pub fn Arc(comptime T: type) type {
    return struct {
        const Self = @This();

        const Inner = struct {
            value: T,
            refcount: AtomicUsize,
            allocator: Allocator,
        };

        inner: *Inner,

        /// Allocate a new Arc wrapping `value`. Refcount starts at 1.
        pub fn init(allocator: Allocator, value: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .value = value,
                .refcount = AtomicUsize.init(1),
                .allocator = allocator,
            };
            return .{ .inner = inner };
        }

        /// Return a new Arc pointing at the same allocation.
        /// Increments the refcount.
        pub fn clone(self: Self) Self {
            _ = self.inner.refcount.fetchAdd(1, .monotonic);
            return .{ .inner = self.inner };
        }

        /// Decrement the refcount. Frees the inner allocation when it reaches zero.
        /// The Arc must not be used after release().
        pub fn release(self: Self) void {
            if (self.inner.refcount.fetchSub(1, .acq_rel) == 1) {
                const allocator = self.inner.allocator;
                allocator.destroy(self.inner);
            }
        }

        /// Return a const pointer to the inner value.
        /// Valid only while at least one Arc is alive.
        pub fn get(self: Self) *const T {
            return &self.inner.value;
        }

        /// Return a mutable pointer to the inner value.
        /// Caller must ensure no other threads are reading or writing concurrently.
        pub fn getMut(self: Self) *T {
            return &self.inner.value;
        }

        /// Current refcount. Useful for debugging; do not make logic decisions on this.
        pub fn refcount(self: Self) usize {
            return self.inner.refcount.load(.monotonic);
        }
    };
}

test "Arc: init and release" {
    const a = try Arc(u32).init(testing.allocator, 42);
    try testing.expectEqual(@as(u32, 42), a.get().*);
    try testing.expectEqual(@as(usize, 1), a.refcount());
    a.release();
}

test "Arc: clone increments refcount" {
    const a = try Arc(u32).init(testing.allocator, 7);
    const b = a.clone();
    try testing.expectEqual(@as(usize, 2), a.refcount());
    try testing.expectEqual(@as(usize, 2), b.refcount());
    b.release();
    try testing.expectEqual(@as(usize, 1), a.refcount());
    a.release();
}

test "Arc: multiple clones" {
    const a = try Arc(u64).init(testing.allocator, 100);
    const b = a.clone();
    const c = a.clone();
    const d = b.clone();
    try testing.expectEqual(@as(usize, 4), a.refcount());
    c.release();
    try testing.expectEqual(@as(usize, 3), a.refcount());
    d.release();
    b.release();
    try testing.expectEqual(@as(usize, 1), a.refcount());
    a.release();
}

test "Arc: get returns correct value" {
    const a = try Arc([]const u8).init(testing.allocator, "slung");
    defer a.release();
    try testing.expectEqualStrings("slung", a.get().*);
}

test "Arc: getMut allows mutation" {
    const a = try Arc(u32).init(testing.allocator, 1);
    defer a.release();
    a.getMut().* = 99;
    try testing.expectEqual(@as(u32, 99), a.get().*);
}

test "Arc: struct value" {
    const Point = struct { x: f32, y: f32 };
    const a = try Arc(Point).init(testing.allocator, .{ .x = 1.0, .y = 2.0 });
    defer a.release();
    try testing.expectApproxEqAbs(@as(f32, 1.0), a.get().x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), a.get().y, 0.001);
}

test "Arc: threaded retain and release" {
    const n_threads = 8;
    const arc = try Arc(u64).init(testing.allocator, 0xdeadbeef);
    defer arc.release();

    var threads: [n_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(a: Arc(u64)) void {
                const c = a.clone();
                std.atomic.spinLoopHint();
                c.release();
            }
        }.run, .{arc});
    }
    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(usize, 1), arc.refcount());
}

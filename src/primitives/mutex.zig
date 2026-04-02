const std = @import("std");
const testing = std.testing;
const Arc = @import("arc.zig").Arc;

/// Generic mutex with RAII Guard pattern.
///
/// The Guard returned by lock() enforces RAII semantics: the lock is automatically
/// released when the Guard goes out of scope or deinit() is called. This prevents
/// use-after-unlock bugs and ensures proper lock cleanup even with early returns.
///
/// Caller must call guard.deinit() or use `defer guard.deinit()` to release the lock.
pub fn Mutex(comptime T: type) type {
    return struct {
        const Self = @This();

        /// RAII guard that holds the lock and enforces automatic unlock.
        /// Obtain via lock() or try_lock(); must call deinit() or use defer.
        pub const Guard = struct {
            mutex: *Self,

            /// Release the lock. Must be called or used with defer.
            pub fn deinit(self: Guard) void {
                self.mutex.mutex.unlock();
            }

            /// Access the protected data. Valid only while Guard is alive.
            pub fn get(self: Guard) *T {
                return &self.mutex.data;
            }
        };

        mutex: std.Thread.Mutex,
        data: T,

        pub fn init(data: T) Self {
            return Self{
                .mutex = .{},
                .data = data,
            };
        }

        /// Acquire the lock (blocking) and return a Guard.
        /// The Guard must be released by calling deinit() (typically via defer).
        pub fn lock(self: *Self) Guard {
            self.mutex.lock();
            return Guard{
                .mutex = self,
            };
        }

        /// Try to acquire the lock without blocking.
        /// Returns a Guard on success, null if the lock is already held.
        /// The Guard must be released by calling deinit() (typically via defer).
        pub fn try_lock(self: *Self) ?Guard {
            if (self.mutex.tryLock()) {
                return Guard{
                    .mutex = self,
                };
            }
            return null;
        }
    };
}

test "Mutex: init and guard lock" {
    var m = Mutex(u32).init(42);
    {
        var guard = m.lock();
        defer guard.deinit();
        try testing.expectEqual(@as(u32, 42), guard.get().*);
    }
}

test "Mutex: guard allows mutation" {
    var m = Mutex(u32).init(10);
    {
        var guard = m.lock();
        defer guard.deinit();
        guard.get().* = 99;
    }
    {
        var guard = m.lock();
        defer guard.deinit();
        try testing.expectEqual(@as(u32, 99), guard.get().*);
    }
}

test "Mutex: try_lock succeeds when unlocked" {
    var m = Mutex(i64).init(123);
    if (m.try_lock()) |guard| {
        defer guard.deinit();
        try testing.expectEqual(@as(i64, 123), guard.get().*);
    } else {
        try testing.expect(false);
    }
}

test "Mutex: try_lock returns null when locked" {
    var m = Mutex(bool).init(true);
    {
        var guard1 = m.lock();
        defer guard1.deinit();
        const guard2 = m.try_lock();
        try testing.expect(guard2 == null);
    }
}

test "Mutex: struct value with guard" {
    const Point = struct { x: i32, y: i32 };
    var m = Mutex(Point).init(.{ .x = 5, .y = 10 });
    {
        var guard = m.lock();
        defer guard.deinit();
        try testing.expectEqual(@as(i32, 5), guard.get().x);
        try testing.expectEqual(@as(i32, 10), guard.get().y);
        guard.get().x = 20;
    }
    {
        var guard = m.lock();
        defer guard.deinit();
        try testing.expectEqual(@as(i32, 20), guard.get().x);
    }
}

test "Mutex: slice value with guard" {
    var m = Mutex([]const u8).init("hello");
    {
        var guard = m.lock();
        defer guard.deinit();
        try testing.expectEqualStrings("hello", guard.get().*);
    }
}

test "Mutex: with Arc for shared ownership" {
    const MutexedCounter = Mutex(u32);
    var shared = try Arc(MutexedCounter).init(testing.allocator, MutexedCounter.init(0));
    defer shared.release();

    const c1 = shared.clone();
    defer c1.release();

    const c2 = shared.clone();
    defer c2.release();

    try testing.expectEqual(@as(usize, 3), shared.refcount());

    {
        var guard = shared.getMut().lock();
        defer guard.deinit();
        guard.get().* += 1;
    }

    {
        var guard = c1.getMut().lock();
        defer guard.deinit();
        try testing.expectEqual(@as(u32, 1), guard.get().*);
        guard.get().* += 1;
    }

    {
        var guard = c2.getMut().lock();
        defer guard.deinit();
        try testing.expectEqual(@as(u32, 2), guard.get().*);
    }
}

test "Mutex: Arc with guard prevents use-after-unlock" {
    const MutexedValue = Mutex(u64);
    var shared = try Arc(MutexedValue).init(testing.allocator, MutexedValue.init(0xdeadbeef));

    const c1 = shared.clone();
    const c2 = shared.clone();

    try testing.expectEqual(@as(usize, 3), shared.refcount());

    {
        var guard = shared.getMut().lock();
        defer guard.deinit();
        try testing.expectEqual(@as(u64, 0xdeadbeef), guard.get().*);
    }

    c1.release();
    try testing.expectEqual(@as(usize, 2), shared.refcount());

    c2.release();
    try testing.expectEqual(@as(usize, 1), shared.refcount());

    shared.release();
}

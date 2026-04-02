//! Hybrid Logical Clock (HLC)
//!
//! Combines physical wall time with a logical counter and node id to produce
//! timestamps that are:
//!   - Monotonically increasing on a single node
//!   - Causally consistent across nodes (recv advances the clock)
//!   - Totally ordered with no ties (node_id breaks equal physical+logical)
//!
//! Based on: Kulkarni et al. "Logical Physical Clocks and Consistent
//! Snapshots in Globally Distributed Databases" (HLC, 2014).
//!
//! Usage:
//!   var clk = Hlc.init(node_id);
//!   const ts = clk.send();           // before sending a message
//!   clk.recv(remote_ts);             // on receiving a message
//!   const order = ts.compare(other); // total order comparison

const std = @import("std");
const testing = std.testing;

/// A single HLC timestamp.
pub const Timestamp = struct {
    wall: u64, // physical milliseconds since Unix epoch
    logical: u32, // logical counter, reset when wall advances
    node_id: u32, // breaks ties between equal (wall, logical) pairs

    pub fn compare(self: Timestamp, other: Timestamp) std.math.Order {
        if (self.wall != other.wall) return std.math.order(self.wall, other.wall);
        if (self.logical != other.logical) return std.math.order(self.logical, other.logical);
        return std.math.order(self.node_id, other.node_id);
    }

    pub fn eql(self: Timestamp, other: Timestamp) bool {
        return self.compare(other) == .eq;
    }

    pub fn after(self: Timestamp, other: Timestamp) bool {
        return self.compare(other) == .gt;
    }

    pub fn before(self: Timestamp, other: Timestamp) bool {
        return self.compare(other) == .lt;
    }
};

/// Hybrid Logical Clock. One instance per node.
pub const Hlc = struct {
    const Self = @This();

    node_id: u32,
    wall: u64,
    logical: u32,

    pub fn init(node_id: u32) Self {
        return .{
            .node_id = node_id,
            .wall = 0,
            .logical = 0,
        };
    }

    /// Call before sending a message with a provided wall time.
    /// Allows amortizing syscalls by batching wall time reads.
    pub fn send_with_wall(self: *Self, wall_now: u64) Timestamp {
        if (wall_now > self.wall) {
            self.wall = wall_now;
            self.logical = 0;
        } else {
            self.logical += 1;
        }
        return .{ .wall = self.wall, .logical = self.logical, .node_id = self.node_id };
    }

    /// Call before sending a message. Returns the timestamp to attach.
    /// Uses lazy wall sync - only bumps logical if wall hasn't advanced.
    pub fn send(self: *Self) Timestamp {
        return self.send_with_wall(wallNow());
    }

    /// Call on receiving a message. Advances the local clock past the remote
    /// timestamp so all subsequent local events are causally after it.
    pub fn recv(self: *Self, remote: Timestamp) Timestamp {
        const wall_now = wallNow();
        const max_wall = @max(wall_now, @max(self.wall, remote.wall));

        if (max_wall == self.wall and max_wall == remote.wall) {
            self.logical = @max(self.logical, remote.logical) + 1;
        } else if (max_wall == self.wall) {
            self.logical += 1;
        } else if (max_wall == remote.wall) {
            self.logical = remote.logical + 1;
        } else {
            self.logical = 0;
        }

        self.wall = max_wall;
        return .{ .wall = self.wall, .logical = self.logical, .node_id = self.node_id };
    }

    /// Current timestamp without advancing the clock.
    pub fn now(self: *const Self) Timestamp {
        return .{ .wall = self.wall, .logical = self.logical, .node_id = self.node_id };
    }

    fn wallNow() u64 {
        return @intCast(std.time.milliTimestamp());
    }
};

test "Hlc: send is monotonic (lazy wall)" {
    var clk = Hlc.init(1);
    const t1 = clk.send();
    const t2 = clk.send();
    const t3 = clk.send();
    try testing.expect(t2.logical >= t1.logical);
    try testing.expect(!t3.before(t2));
}

test "Hlc: recv advances past remote" {
    var node_a = Hlc.init(1);
    var node_b = Hlc.init(2);

    const sent = node_a.send();
    const received = node_b.recv(sent);

    try testing.expect(received.after(sent) or
        (received.wall == sent.wall and received.logical > sent.logical));
}

test "Hlc: total order - node_id breaks ties" {
    const t1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 1 };
    const t2 = Timestamp{ .wall = 100, .logical = 0, .node_id = 2 };
    try testing.expect(t1.before(t2));
    try testing.expect(t2.after(t1));
    try testing.expect(!t1.eql(t2));
}

test "Hlc: logical breaks ties before node_id" {
    const t1 = Timestamp{ .wall = 100, .logical = 0, .node_id = 99 };
    const t2 = Timestamp{ .wall = 100, .logical = 1, .node_id = 1 };
    try testing.expect(t1.before(t2));
}

test "Hlc: wall time dominates" {
    const t1 = Timestamp{ .wall = 99, .logical = 9999, .node_id = 9999 };
    const t2 = Timestamp{ .wall = 100, .logical = 0, .node_id = 0 };
    try testing.expect(t1.before(t2));
}

test "Hlc: recv handles node_b ahead of node_a" {
    var node_a = Hlc.init(1);
    var node_b = Hlc.init(2);

    node_b.wall = 9_999_999_999;
    node_b.logical = 0;

    const sent = node_a.send();
    const received = node_b.recv(sent);

    try testing.expectEqual(node_b.wall, received.wall);
}

test "Hlc: now does not advance clock" {
    var clk = Hlc.init(42);
    clk.wall = 1000;
    clk.logical = 5;

    const snap1 = clk.now();
    const snap2 = clk.now();

    try testing.expect(snap1.eql(snap2));
    try testing.expectEqual(@as(u64, 1000), snap1.wall);
    try testing.expectEqual(@as(u32, 5), snap1.logical);
    try testing.expectEqual(@as(u32, 42), snap1.node_id);
}

test "Hlc: send_with_wall allows batched wall updates" {
    var clk = Hlc.init(1);
    const wall = 5000;
    const t1 = clk.send_with_wall(wall);
    const t2 = clk.send_with_wall(wall);
    const t3 = clk.send_with_wall(wall + 1);
    try testing.expectEqual(wall, t1.wall);
    try testing.expectEqual(@as(u32, 0), t1.logical);
    try testing.expectEqual(@as(u32, 1), t2.logical);
    try testing.expectEqual(wall + 1, t3.wall);
    try testing.expectEqual(@as(u32, 0), t3.logical);
}

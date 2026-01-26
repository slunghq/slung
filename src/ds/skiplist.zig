//! A skip list implementation.
//!
//! Skip list is a probabilistic data structure that allows efficient insertion, deletion, and search operations.
//! It is a sorted linked list with a random number of levels, where each level is a subset of the previous level.
//! The probability of a node having a higher level is determined by a random number generator giving it a chance of having a O(log n) search time.
//! Inspired by [Rakator](https://github.com/Ratakor/skip/blob/master/skiplist.zig)

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

fn SkipListImpl(comptime K: type, comptime V: type, comptime max_level: usize, comptime Rng: type, comptime CompareFn: fn (K, K) Order) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            key: K,
            value: V,
            forward: []?*Node,

            pub inline fn next(self: Node) ?*Node {
                return self.forward[0];
            }
        };

        head: *Node,
        allocator: Allocator,
        rng: Rng,
        level: usize = 1,
        max_level: usize = max_level,

        /// Initialise a skip list with a given allocator and rng seed.
        pub fn init(allocator: Allocator, seed: u64) !Self {
            var head = try allocator.create(Node);
            head.key = undefined;
            head.value = undefined;
            head.forward = try allocator.alloc(?*Node, max_level);
            @memset(head.forward[0..], null);
            return Self{
                .head = head,
                .allocator = allocator,
                .rng = Rng.init(seed),
            };
        }

        /// Deinitialise a skip list.
        pub fn deinit(self: *Self) void {
            var node: ?*Node = self.head;
            while (node) |n| {
                const next = n.forward[0];
                self.allocator.free(n.forward);
                self.allocator.destroy(n);
                node = next;
            }
        }

        /// Find a node in the skip list.
        fn find(self: *Self, key: K, update: ?[]*Node) ?*Node {
            var node = self.head;
            var level = self.level - 1;

            while (true) : (level -= 1) {
                while (node.forward[level]) |next| {
                    if (CompareFn(next.key, key).compare(.gte)) break;
                    node = next;
                }
                if (update) |u| u[level] = node;
                if (level == 0) break;
            }

            return node.next();
        }

        /// Insert a node into the skip list.
        pub fn insert(self: *Self, key: K, val: V) !*Node {
            var update: [max_level]*Node = undefined;
            const maybe_node = self.find(key, &update);

            if (maybe_node) |node| {
                if (CompareFn(node.key, key).compare(.eq)) {
                    node.value = val;
                    return node;
                }
            }

            var lvl: usize = 1;
            while (self.rng.random().int(u2) == 0) lvl += 1;
            if (lvl > self.level) {
                if (lvl > max_level) lvl = max_level;
                for (self.level..lvl) |i| {
                    update[i] = self.head;
                }
                self.level = lvl;
            }

            var node = try self.allocator.create(Node);
            node.key = key;
            node.value = val;
            node.forward = try self.allocator.alloc(?*Node, lvl);

            for (0..lvl) |i| {
                node.forward[i] = update[i].forward[i];
                update[i].forward[i] = node;
            }

            return node;
        }

        fn deleteNode(self: *Self, node: *Node, update: []*Node) void {
            for (0..self.level) |lvl| {
                if (update[lvl].forward[lvl] != node) break;
                update[lvl].forward[lvl] = node.forward[lvl];
            }

            while (self.level > 1) : (self.level -= 1) {
                if (self.head.forward[self.level - 1] != null) break;
            }

            self.allocator.free(node.forward);
            self.allocator.destroy(node);
        }

        /// Delete a node from the skip list.
        pub fn delete(self: *Self, key: K) bool {
            var update: [max_level]*Node = undefined;
            const maybe_node = self.find(key, &update);

            if (maybe_node) |node| {
                if (CompareFn(node.key, key).compare(.eq)) {
                    self.deleteNode(node, &update);
                    return true;
                }
            }
            return false;
        }

        /// Search for a node in the skip list.
        pub fn search(self: *Self, key: K) ?*Node {
            const node = self.find(key, null);
            if (node != null and CompareFn(node.?.key, key).compare(.eq)) {
                return node;
            }
            return null;
        }

        /// Get the length of the skip list.
        pub fn length(self: *Self) usize {
            var lngth: usize = 0;
            var node = self.head.forward[0];
            while (node != null) : (node = node.forward[0]) {
                lngth += 1;
            }
            return lngth;
        }
    };
}

pub const SkipList = SkipListImpl;

pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn compareU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

test "skip list" {
    const allocator = std.testing.allocator;

    var skip_list = try SkipList([]const u8, []const u8, 16, std.Random.Pcg, compare).init(allocator, @intCast(std.time.microTimestamp()));
    defer skip_list.deinit();

    _ = try skip_list.insert("key", "value");
    _ = try skip_list.insert("key2", "value2");
    _ = try skip_list.insert("key3", "value3");

    try testing.expectEqualStrings("value3", skip_list.search("key3").?.value);
    try testing.expectEqualStrings("value2", skip_list.search("key2").?.value);
    try testing.expectEqualStrings("value", skip_list.search("key").?.value);
}

test "skip list delete" {
    const allocator = std.testing.allocator;

    var skip_list = try SkipList(u64, u64, 16, std.Random.Pcg, compareU64).init(allocator, @intCast(std.time.microTimestamp()));
    defer skip_list.deinit();

    _ = try skip_list.insert(1, 1);
    _ = try skip_list.insert(2, 2);
    _ = try skip_list.insert(3, 3);

    try testing.expect(skip_list.delete(2));

    try testing.expectEqual(1, skip_list.search(1).?.value);
    try testing.expect(skip_list.search(2) == null);
    try testing.expectEqual(3, skip_list.search(3).?.value);
}

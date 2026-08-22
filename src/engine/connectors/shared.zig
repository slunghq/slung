const std = @import("std");
const Allocator = std.mem.Allocator;

const LwwRegistry = @import("../../memory/lww.zig").LwwRegistry;
const Arc = @import("../../primitives/arc.zig").Arc;
const Hlc = @import("../../primitives/hlc.zig").Hlc;
const Mutex = @import("../../primitives/mutex.zig").Mutex;
const DirtyQueue = @import("../../queue.zig").DirtyQueue;
const types = @import("../../types.zig");

pub fn Source(D: type) type {
    return struct {
        allocator: Allocator,
        namespace: []const u8,
        node_id: types.NodeId,
        entity_id: types.EntityId,
        component_id: types.ComponentId,
        lww_store: Arc(Mutex(LwwRegistry)),
        dirty_queue: Arc(Mutex(DirtyQueue)),
        clock: *Hlc,
        data: ?D = null,

        const Self = @This();

        pub fn write(self: *Self, data: D) !void {
            self.data = data;
        }
    };
}

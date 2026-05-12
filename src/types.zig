const std = @import("std");

pub const ComponentId = u32;
pub const EntityId = u32;
pub const RuleId = u32;
pub const NamespaceId = []const u8;
pub const NodeId = []const u8;
pub const WasmModuleRef = []const u8;
pub const SourceRef = []const u8;
pub const WorkerId = []const u8;

/// Identifies the rule or source that triggered a write.
/// Used to inhibit conflicts and track causality in the inference loop.
pub const CausalTag = struct {
    /// could also be RuleId
    cause: ComponentId,
    entity: EntityId,
    node: NodeId,
};

pub const DirtyEntry = struct {
    entity: EntityId,
    component: ComponentId,
};

pub const Value = union(enum) {
    Bool: bool,
    Int: i64,
    Float: f64,
    Bytes: []const u8,

    pub fn compare(self: Value, b: Value) std.math.Order {
        return switch (self) {
            .Int => |v| std.math.order(v, b.Int),
            .Float => |v| std.math.order(v, b.Float),
            .Bytes => |v| std.mem.order(u8, v, b.Bytes),
            .Bool => |v| std.math.order(@intFromBool(v), @intFromBool(b.Bool)),
        };
    }

    pub fn eql(self: Value, b: Value) bool {
        return switch (self) {
            .Bool => |v| v == b.Bool,
            .Int => |v| v == b.Int,
            .Float => |v| v == b.Float,
            .Bytes => |v| std.mem.eql(u8, v, b.Bytes),
        };
    }
};

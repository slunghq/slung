const std = @import("std");
const types = @import("../types.zig");

pub const ForwardKey = struct {
    entity: types.EntityId,
    component: types.ComponentId,
};

pub const Forward = struct {
    const Self = @This();

    watchers: []types.RuleId,
    source: types.SourceRef,
    component_type: []const u8,
    mapper: []const u8,
    dynamic: bool,
};

pub const ForwardIndex = std.AutoArrayHashMapUnmanaged(ForwardKey, Forward);

pub const Reverse = struct {
    const Self = @This();

    watch: []ForwardKey, // components this rule watches
    priority: u8,
    entrypoint: []const u8, // __slung_rule_<Name>
    module: types.WasmModuleRef,
    namespace: types.NamespaceId,
};

pub const ReverseIndex = std.AutoArrayHashMapUnmanaged(types.RuleId, Reverse);

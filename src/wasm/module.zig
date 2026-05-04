//! Module loader and graph builder — three-phase descriptor loading.
//!
//! Implements the capability graph generation algorithm:
//! Phase 1: Load source descriptors — mint EntityIds, open connections, mint ComponentIds
//! Phase 2: Load component descriptors — attach serialization boundaries
//! Phase 3: Load rule descriptors — mint RuleIds, resolve watches, wire the graph
//!
//! The graph builder maintains registries to resolve symbolic references (e.g., "Orders::status")
//! to concrete (EntityId, ComponentId) pairs. It populates Forward and Reverse indices that
//! are queried at runtime by the inference loop.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const graph_index = @import("index.zig");
const ForwardKey = graph_index.ForwardKey;

/// Source descriptor from module export.
pub const ComponentField = struct {
    name: []const u8,
    type_name: []const u8,
    mapper: []const u8, // __slung_map_<Source>_<component>
    dynamic: bool,
};

pub const SourceDescriptor = struct {
    name: []const u8,
    kind: []const u8, // "builtin" or "custom"
    builtin: []const u8, // connector name if kind=="builtin"
    config: []const u8, // JSON config
    components: []const ComponentField,
};

/// Component descriptor from module export.
pub const ComponentDescriptor = struct {
    name: []const u8, // the ComponentType name
    kind: []const u8 = "struct",
    fields: []const []const u8 = &.{},
    variants: []const []const u8 = &.{},
};

/// Rule descriptor from module export.
pub const RuleDescriptor = struct {
    name: []const u8,
    watch: []const []const u8, // ["<Source>::<component>", ...]
    priority: u8,

    pub fn deinit(self: RuleDescriptor, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.watch) |w| {
            allocator.free(w);
        }
        allocator.free(self.watch);
    }
};

/// Internal registry tracking during graph building.
pub const SourceRegistry = struct {
    name: []const u8,
    entity_id: types.EntityId,
    kind: []const u8,
    builtin: []const u8,
    config: []const u8,
    components: std.StringHashMap(types.ComponentId), // component_name -> ComponentId
};

pub const ComponentRegistry = struct {
    entity_id: types.EntityId,
    component_id: types.ComponentId,
    type_name: []const u8,
    mapper: []const u8,
    dynamic: bool,
    kind: ?[]const u8 = null,
    fields: ?[]const []const u8 = null,
    variants: ?[]const []const u8 = null,
};

/// Internal registry tracking for rules during graph building.
pub const RuleRegistry = struct {
    rule_id: types.RuleId,
    desc: RuleDescriptor,
    watch_list: std.ArrayList(ForwardKey),
};

/// GraphBuilder orchestrates the three-phase descriptor loading.
pub const GraphBuilder = struct {
    const Self = @This();

    allocator: Allocator,
    namespace: types.NamespaceId,
    module_ref: types.WasmModuleRef,

    /// Phase 1: Registered sources and their minted EntityIds.
    /// source_name -> SourceRegistry (which contains component_name -> ComponentId mapping)
    sources: std.StringHashMap(SourceRegistry),

    /// Phase 2: Registered components and their metadata.
    /// (entity_id, component_id) -> ComponentRegistry
    components: std.AutoHashMap(ForwardKey, ComponentRegistry),

    /// Phase 3: Registered rules and their metadata.
    /// rule_id -> RuleRegistry
    rules: std.AutoHashMap(types.RuleId, RuleRegistry),

    /// Next IDs to mint.
    next_entity_id: types.EntityId = 0,
    next_component_id: types.ComponentId = 0,
    next_rule_id: types.RuleId = 0,

    pub fn init(
        allocator: Allocator,
        namespace: types.NamespaceId,
        module_ref: types.WasmModuleRef,
    ) Self {
        return .{
            .allocator = allocator,
            .namespace = namespace,
            .module_ref = module_ref,
            .sources = std.StringHashMap(SourceRegistry).init(allocator),
            .components = std.AutoHashMap(ForwardKey, ComponentRegistry).init(allocator),
            .rules = std.AutoHashMap(types.RuleId, RuleRegistry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var sources_iter = self.sources.iterator();
        while (sources_iter.next()) |entry| {
            var comp_iter = entry.value_ptr.components.iterator();
            while (comp_iter.next()) |comp_entry| {
                self.allocator.free(comp_entry.key_ptr.*);
            }
            entry.value_ptr.components.deinit();
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.kind);
            self.allocator.free(entry.value_ptr.builtin);
            self.allocator.free(entry.value_ptr.config);
        }
        self.sources.deinit();

        var comps_iter = self.components.iterator();
        while (comps_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.type_name);
            self.allocator.free(entry.value_ptr.mapper);
            if (entry.value_ptr.kind) |kind| {
                self.allocator.free(kind);
            }
            if (entry.value_ptr.fields) |fields| {
                for (fields) |f| {
                    self.allocator.free(f);
                }
                self.allocator.free(fields);
            }
            if (entry.value_ptr.variants) |variants| {
                for (variants) |v| {
                    self.allocator.free(v);
                }
                self.allocator.free(variants);
            }
        }
        self.components.deinit();

        var rules_iter = self.rules.iterator();
        while (rules_iter.next()) |entry| {
            entry.value_ptr.desc.deinit(self.allocator);
            entry.value_ptr.watch_list.deinit(self.allocator);
        }
        self.rules.deinit();
    }

    /// Phase 1: Register a source and its components.
    /// Mints an EntityId for the source and ComponentIds for each component.
    pub fn registerSource(
        self: *Self,
        source_desc: SourceDescriptor,
    ) !types.EntityId {
        const entity_id = self.next_entity_id;
        self.next_entity_id += 1;

        var component_map = std.StringHashMap(types.ComponentId).init(self.allocator);

        for (source_desc.components) |comp| {
            const component_id = self.next_component_id;
            self.next_component_id += 1;

            try component_map.put(try self.allocator.dupe(u8, comp.name), component_id);

            const key: ForwardKey = .{
                .entity = entity_id,
                .component = component_id,
            };

            try self.components.put(key, .{
                .entity_id = entity_id,
                .component_id = component_id,
                .type_name = try self.allocator.dupe(u8, comp.type_name),
                .mapper = try self.allocator.dupe(u8, comp.mapper),
                .dynamic = comp.dynamic,
            });
        }

        const duped_name = try self.allocator.dupe(u8, source_desc.name);
        try self.sources.put(duped_name, .{
            .name = duped_name,
            .entity_id = entity_id,
            .kind = try self.allocator.dupe(u8, source_desc.kind),
            .builtin = try self.allocator.dupe(u8, source_desc.builtin),
            .config = try self.allocator.dupe(u8, source_desc.config),
            .components = component_map,
        });

        return entity_id;
    }

    /// Phase 2: Attach serialization boundary to a component.
    /// Called after component descriptors are available.
    pub fn registerComponentType(
        self: *Self,
        comp_desc: ComponentDescriptor,
        entity_id: types.EntityId,
        component_id: types.ComponentId,
    ) !void {
        const key: ForwardKey = .{
            .entity = entity_id,
            .component = component_id,
        };

        if (self.components.getPtr(key)) |entry| {
            self.allocator.free(entry.type_name);
            entry.type_name = try self.allocator.dupe(u8, comp_desc.name);

            if (entry.kind) |old_kind| {
                self.allocator.free(old_kind);
            }
            entry.kind = try self.allocator.dupe(u8, comp_desc.kind);

            if (entry.fields) |old_fields| {
                for (old_fields) |f| self.allocator.free(f);
                self.allocator.free(old_fields);
            }

            var fields = try self.allocator.alloc([]const u8, comp_desc.fields.len);
            for (comp_desc.fields, 0..) |f, i| {
                fields[i] = try self.allocator.dupe(u8, f);
            }
            entry.fields = fields;

            if (entry.variants) |old_variants| {
                for (old_variants) |v| self.allocator.free(v);
                self.allocator.free(old_variants);
            }

            var variants = try self.allocator.alloc([]const u8, comp_desc.variants.len);
            for (comp_desc.variants, 0..) |v, i| {
                variants[i] = try self.allocator.dupe(u8, v);
            }
            entry.variants = variants;
        }
    }

    /// Phase 3: Register a rule and its watch list.
    /// Resolves watch entries like "Orders::status" to (EntityId, ComponentId) pairs.
    /// Mints a RuleId and returns it for reverse index registration.
    pub fn registerRule(
        self: *Self,
        rule_desc: RuleDescriptor,
    ) !types.RuleId {
        const rule_id = self.next_rule_id;
        self.next_rule_id += 1;

        var watch_list = std.ArrayList(ForwardKey).initCapacity(self.allocator, 0) catch unreachable;

        // Resolve watch entries: "<Source>::<component>" -> (EntityId, ComponentId)
        for (rule_desc.watch) |watch_entry| {
            var parts = std.mem.splitSequence(u8, watch_entry, "::");
            const source_name = parts.next() orelse continue;
            const component_name = parts.next() orelse continue;

            if (self.sources.get(source_name)) |source_reg| {
                if (source_reg.components.get(component_name)) |component_id| {
                    try watch_list.append(self.allocator, .{
                        .entity = source_reg.entity_id,
                        .component = component_id,
                    });
                }
            }
        }

        // Dupe descriptor fields for registry
        var watch_dupe = try self.allocator.alloc([]const u8, rule_desc.watch.len);
        for (rule_desc.watch, 0..) |w, i| {
            watch_dupe[i] = try self.allocator.dupe(u8, w);
        }

        try self.rules.put(rule_id, .{
            .rule_id = rule_id,
            .desc = .{
                .name = try self.allocator.dupe(u8, rule_desc.name),
                .watch = watch_dupe,
                .priority = rule_desc.priority,
            },
            .watch_list = watch_list,
        });

        return rule_id;
    }

    /// Build the Forward and Reverse indices from all registered descriptors.
    /// Called after all three phases are complete.
    pub fn build(
        self: *Self,
        forward: *graph_index.ForwardIndex,
        reverse: *graph_index.ReverseIndex,
    ) !void {
        // Populate Reverse index: RuleId -> rule metadata
        var rules_iter = self.rules.iterator();
        while (rules_iter.next()) |rule_entry| {
            const rule_id = rule_entry.key_ptr.*;
            const rule_reg = rule_entry.value_ptr;

            const entrypoint = try std.fmt.allocPrint(self.allocator, "__slung_rule_{s}", .{rule_reg.desc.name});

            const reverse_entry = graph_index.Reverse{
                .watch = try self.allocator.dupe(ForwardKey, rule_reg.watch_list.items),
                .priority = rule_reg.desc.priority,
                .entrypoint = entrypoint,
                .module = try self.allocator.dupe(u8, self.module_ref),
                .namespace = try self.allocator.dupe(u8, self.namespace),
            };

            try reverse.put(self.allocator, rule_id, reverse_entry);
        }

        // Populate Forward index: (EntityId, ComponentId) metadata
        var comp_iter = self.components.iterator();
        while (comp_iter.next()) |comp_entry| {
            const key = comp_entry.key_ptr.*;
            const reg = comp_entry.value_ptr;

            // Find source name for this entity_id
            var source_name: []const u8 = "";
            var sources_iter = self.sources.iterator();
            while (sources_iter.next()) |s_entry| {
                if (s_entry.value_ptr.entity_id == reg.entity_id) {
                    source_name = s_entry.value_ptr.name;
                    break;
                }
            }

            try forward.put(self.allocator, key, .{
                .watchers = try self.allocator.alloc(types.RuleId, 0),
                .source = try self.allocator.dupe(u8, source_name),
                .component_type = try self.allocator.dupe(u8, reg.type_name),
                .mapper = try self.allocator.dupe(u8, reg.mapper),
                .dynamic = reg.dynamic,
            });
        }

        // Populate Forward index: Add watchers
        var rules_iter2 = self.rules.iterator();
        while (rules_iter2.next()) |rule_entry| {
            const rule_id = rule_entry.key_ptr.*;
            const rule_reg = rule_entry.value_ptr;

            for (rule_reg.watch_list.items) |key| {
                if (forward.getPtr(key)) |f_entry| {
                    const old_watchers = f_entry.watchers;
                    const new_len = old_watchers.len + 1;
                    var new_watchers_buf = try self.allocator.alloc(types.RuleId, new_len);
                    std.mem.copyForwards(types.RuleId, new_watchers_buf[0..old_watchers.len], old_watchers);
                    new_watchers_buf[old_watchers.len] = rule_id;
                    self.allocator.free(old_watchers);
                    f_entry.watchers = new_watchers_buf;
                }
            }
        }
    }

    /// Reverse mapping for cleanup: RuleId -> [(EntityId, ComponentId)]
    pub fn getRuleWatches(self: *Self, rule_id: types.RuleId) ?[]const ForwardKey {
        if (self.rules.get(rule_id)) |rule_reg| {
            return rule_reg.watch_list.items;
        }
        return null;
    }
};

const testing = std.testing;

test "GraphBuilder: phase 1 source registration" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components = [_]ComponentField{
        .{
            .name = "status",
            .type_name = "OrderStatus",
            .mapper = "__slung_map_orders_status",
            .dynamic = false,
        },
        .{
            .name = "total",
            .type_name = "i64",
            .mapper = "__slung_map_orders_total",
            .dynamic = false,
        },
    };

    const source_desc: SourceDescriptor = .{
        .name = "orders",
        .kind = "builtin",
        .builtin = "nats",
        .config = "{\"subject\": \"orders.*\"}",
        .components = &components,
    };

    const entity_id = try builder.registerSource(source_desc);

    try testing.expectEqual(@as(types.EntityId, 0), entity_id);
    try testing.expectEqual(@as(types.ComponentId, 2), builder.next_component_id);

    var found = false;
    var iter = builder.sources.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "orders")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "GraphBuilder: phase 3 rule registration resolves watches" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components = [_]ComponentField{
        .{
            .name = "status",
            .type_name = "OrderStatus",
            .mapper = "__slung_map_orders_status",
            .dynamic = false,
        },
    };

    const source_desc: SourceDescriptor = .{
        .name = "orders",
        .kind = "builtin",
        .builtin = "nats",
        .config = "{}",
        .components = &components,
    };

    _ = try builder.registerSource(source_desc);

    const rule_desc: RuleDescriptor = .{
        .name = "CheckTotal",
        .watch = &[_][]const u8{"orders::status"},
        .priority = 10,
    };

    const rule_id = try builder.registerRule(rule_desc);

    try testing.expectEqual(@as(types.RuleId, 0), rule_id);
    const watches = builder.getRuleWatches(rule_id);
    try testing.expect(watches != null);
    try testing.expectEqual(@as(usize, 1), watches.?.len);
    try testing.expectEqual(@as(types.EntityId, 0), watches.?[0].entity);
    try testing.expectEqual(@as(types.ComponentId, 0), watches.?[0].component);
}

test "GraphBuilder: build indices from descriptors" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components = [_]ComponentField{
        .{
            .name = "status",
            .type_name = "OrderStatus",
            .mapper = "__slung_map_orders_status",
            .dynamic = false,
        },
    };

    const source_desc: SourceDescriptor = .{
        .name = "orders",
        .kind = "builtin",
        .builtin = "nats",
        .config = "{}",
        .components = &components,
    };

    _ = try builder.registerSource(source_desc);

    const rule_desc: RuleDescriptor = .{
        .name = "CheckTotal",
        .watch = &[_][]const u8{"orders::status"},
        .priority = 10,
    };

    _ = try builder.registerRule(rule_desc);

    var forward = graph_index.ForwardIndex{};
    var reverse = graph_index.ReverseIndex{};

    try builder.build(&forward, &reverse);

    try testing.expectEqual(@as(usize, 1), reverse.count());
    try testing.expectEqual(@as(usize, 1), forward.count());

    var f_iter = forward.iterator();
    while (f_iter.next()) |entry| {
        testing.allocator.free(entry.value_ptr.watchers);
        testing.allocator.free(entry.value_ptr.source);
        testing.allocator.free(entry.value_ptr.component_type);
        testing.allocator.free(entry.value_ptr.mapper);
    }
    forward.deinit(testing.allocator);

    var r_iter = reverse.iterator();
    while (r_iter.next()) |entry| {
        testing.allocator.free(entry.value_ptr.watch);
        testing.allocator.free(entry.value_ptr.entrypoint);
        testing.allocator.free(entry.value_ptr.module);
        testing.allocator.free(entry.value_ptr.namespace);
    }
    reverse.deinit(testing.allocator);
}

test "GraphBuilder: dynamic entity flag preserved" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components = [_]ComponentField{
        .{
            .name = "payload",
            .type_name = "EventPayload",
            .mapper = "__slung_map_events_payload",
            .dynamic = true,
        },
    };

    const source_desc: SourceDescriptor = .{
        .name = "events",
        .kind = "builtin",
        .builtin = "kafka",
        .config = "{}",
        .components = &components,
    };

    _ = try builder.registerSource(source_desc);

    const key: ForwardKey = .{
        .entity = 0,
        .component = 0,
    };

    const comp_reg = builder.components.get(key);
    try testing.expect(comp_reg != null);
    try testing.expect(comp_reg.?.dynamic);
}

test "GraphBuilder: SourceRegistry fields populated correctly" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components = [_]ComponentField{
        .{ .name = "status", .type_name = "OrderStatus", .mapper = "__slung_map_orders_status", .dynamic = false },
    };

    const source_desc: SourceDescriptor = .{
        .name = "orders_source",
        .kind = "builtin",
        .builtin = "test_connector",
        .config = "{\"url\":\"nats://localhost:4222\"}",
        .components = &components,
    };

    _ = try builder.registerSource(source_desc);

    const source_reg_ptr = builder.sources.getPtr("orders_source") orelse unreachable;
    try testing.expectEqualStrings("orders_source", source_reg_ptr.name);
    try testing.expectEqualStrings("builtin", source_reg_ptr.kind);
    try testing.expectEqualStrings("test_connector", source_reg_ptr.builtin);
    try testing.expectEqualStrings("{\"url\":\"nats://localhost:4222\"}", source_reg_ptr.config);
    try testing.expectEqual(@as(usize, 1), source_reg_ptr.components.count());
}

test "GraphBuilder: ComponentRegistry fields and dynamic flag updated via registerComponentType" {
    var builder = GraphBuilder.init(testing.allocator, "test_ns", "module.wasm");
    defer builder.deinit();

    const components_for_source = [_]ComponentField{
        .{
            .name = "status",
            .type_name = "OldStatusType",
            .mapper = "__slung_map_test_status",
            .dynamic = false,
        },
    };

    const source_desc: SourceDescriptor = .{
        .name = "test_source",
        .kind = "builtin",
        .builtin = "dummy",
        .config = "{}",
        .components = &components_for_source,
    };

    const entity_id = try builder.registerSource(source_desc);

    const key: ForwardKey = .{ .entity = entity_id, .component = 0 };
    var comp_reg_ptr = builder.components.getPtr(key) orelse unreachable;

    // Verify initial registration
    try testing.expectEqualStrings("OldStatusType", comp_reg_ptr.type_name);
    try testing.expect(comp_reg_ptr.kind == null);
    try testing.expect(comp_reg_ptr.fields == null);
    try testing.expect(comp_reg_ptr.variants == null);
    try testing.expectEqual(false, comp_reg_ptr.dynamic);

    const comp_fields = &[_][]const u8{ "field1", "field2" };
    const component_desc: ComponentDescriptor = .{
        .name = "NewStatusType",
        .kind = "struct",
        .fields = comp_fields,
    };

    // Register component type, updating existing entry
    try builder.registerComponentType(component_desc, entity_id, 0);

    // Verify updated values
    comp_reg_ptr = builder.components.getPtr(key) orelse unreachable; // Re-get pointer after potential rehash
    try testing.expectEqualStrings("NewStatusType", comp_reg_ptr.type_name);
    try testing.expectEqualStrings("struct", comp_reg_ptr.kind.?);
    try testing.expect(comp_reg_ptr.fields != null);
    try testing.expectEqual(@as(usize, 2), comp_reg_ptr.fields.?.len);
    try testing.expectEqualStrings("field1", comp_reg_ptr.fields.?[0]);
    try testing.expectEqualStrings("field2", comp_reg_ptr.fields.?[1]);
    try testing.expect(comp_reg_ptr.variants != null);
    try testing.expectEqual(@as(usize, 0), comp_reg_ptr.variants.?.len);
}

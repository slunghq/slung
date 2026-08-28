const std = @import("std");
const Allocator = std.mem.Allocator;
const zwasm = @import("zwasm");
const types = @import("../types.zig");
const graph_index = @import("index.zig");
const module = @import("module.zig");
const GraphBuilder = module.GraphBuilder;

pub fn wire(allocator: Allocator, wasm_module: *const zwasm.Module, instance: *zwasm.Instance, forward: *graph_index.ForwardIndex, reverse: *graph_index.ReverseIndex, namespace: types.NamespaceId, module_ref: types.WasmModuleRef) !void {
    var builder = GraphBuilder.init(allocator, namespace, module_ref);
    defer builder.deinit();
    try fetchDescriptors(allocator, wasm_module, instance, &builder);
    try builder.build(forward, reverse);
}

fn fetchDescriptors(allocator: Allocator, wasm_module: *const zwasm.Module, instance: *zwasm.Instance, builder: *GraphBuilder) !void {
    var exports = try wasm_module.exports(allocator);
    defer exports.deinit();
    for (0..3) |phase| {
        for (exports.items) |export_info| {
            if (export_info.kind != .func) continue;
            const is_source = std.mem.startsWith(u8, export_info.name, "__slung_source_") and std.mem.endsWith(u8, export_info.name, "_descriptor");
            const is_component = std.mem.startsWith(u8, export_info.name, "__slung_component_") and std.mem.endsWith(u8, export_info.name, "_descriptor");
            const is_rule = std.mem.startsWith(u8, export_info.name, "__slung_rule_") and std.mem.endsWith(u8, export_info.name, "_descriptor");
            if ((phase == 0 and !is_source) or (phase == 1 and !is_component) or (phase == 2 and !is_rule)) continue;
            var result = [_]zwasm.Value{.fromI64(0)};
            try instance.invoke(export_info.name, &.{}, &result);
            const descriptor_word: u64 = @bitCast(result[0].i64);
            const length: u32 = @truncate(descriptor_word);
            const offset: u32 = @truncate(descriptor_word >> 32);
            const memory = instance.memory() orelse return error.NoMemory;
            const bytes = try allocator.dupe(u8, try memory.sliceAt(offset, length));
            defer allocator.free(bytes);
            if (std.mem.startsWith(u8, export_info.name, "__slung_source_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
                const parsed = try std.json.parseFromSlice(module.ParsedSourceDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                const normalized = try module.normalizeSourceDescriptor(allocator, parsed.value);
                defer allocator.free(normalized.config);
                _ = try builder.registerSource(normalized);
            } else if (std.mem.startsWith(u8, export_info.name, "__slung_component_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
                const parsed = try std.json.parseFromSlice(module.ComponentDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var it = builder.components.iterator();
                while (it.next()) |entry| if (std.mem.eql(u8, entry.value_ptr.type_name, parsed.value.name)) try builder.registerComponentType(parsed.value, entry.value_ptr.entity_id, entry.value_ptr.component_id);
            } else if (std.mem.startsWith(u8, export_info.name, "__slung_rule_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
                const parsed = try std.json.parseFromSlice(module.RuleDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                _ = try builder.registerRule(parsed.value);
            }
        }
    }
}

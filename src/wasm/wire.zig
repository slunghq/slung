const std = @import("std");
const zwasm = @import("zwasm");
const host = @import("host.zig");
const module = @import("module.zig");
const GraphBuilder = module.GraphBuilder;
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const graph_index = @import("index.zig");

pub fn wire(
    allocator: Allocator,
    wasm_module: *zwasm.WasmModule,
    forward: *graph_index.ForwardIndex,
    reverse: *graph_index.ReverseIndex,
    namespace: types.NamespaceId,
    module_ref: types.WasmModuleRef,
) !void {
    var builder = GraphBuilder.init(allocator, namespace, module_ref);
    defer builder.deinit();

    try fetchSourceDescriptors(allocator, wasm_module, &builder);

    try fetchComponentDescriptors(allocator, wasm_module, &builder);

    try fetchRuleDescriptors(allocator, wasm_module, &builder);

    try builder.build(forward, reverse);
}

fn fetchSourceDescriptors(allocator: Allocator, wasm_module: *zwasm.WasmModule, builder: *GraphBuilder) !void {
    const exports = wasm_module.export_fns;
    for (exports) |export_info| {
        if (std.mem.startsWith(u8, export_info.name, "__slung_source_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
            var result: [1]u64 = undefined;
            try wasm_module.invoke(export_info.name, &.{}, result[0..]);
            const length: u32 = @intCast(result[0] & 0xFFFFFFFF);
            const offset: u32 = @intCast((result[0] >> 32) & 0xFFFFFFFF);

            const bytes = try wasm_module.memoryRead(allocator, offset, length);
            defer allocator.free(bytes);

            const parsed = try std.json.parseFromSlice(module.SourceDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            _ = try builder.registerSource(parsed.value);
        }
    }
}

fn fetchComponentDescriptors(allocator: Allocator, wasm_module: *zwasm.WasmModule, builder: *GraphBuilder) !void {
    const exports = wasm_module.export_fns;
    for (exports) |export_info| {
        if (std.mem.startsWith(u8, export_info.name, "__slung_component_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
            var result: [1]u64 = undefined;
            try wasm_module.invoke(export_info.name, &.{}, result[0..]);
            const length: u32 = @intCast(result[0] & 0xFFFFFFFF);
            const offset: u32 = @intCast((result[0] >> 32) & 0xFFFFFFFF);

            const bytes = try wasm_module.memoryRead(allocator, offset, length);
            defer allocator.free(bytes);

            const parsed = try std.json.parseFromSlice(module.ComponentDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            var comp_iter = builder.components.iterator();
            while (comp_iter.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.type_name, parsed.value.name)) {
                    try builder.registerComponentType(parsed.value, entry.value_ptr.entity_id, entry.value_ptr.component_id);
                }
            }
        }
    }
}

fn fetchRuleDescriptors(allocator: Allocator, wasm_module: *zwasm.WasmModule, builder: *GraphBuilder) !void {
    const exports = wasm_module.export_fns;
    for (exports) |export_info| {
        if (std.mem.startsWith(u8, export_info.name, "__slung_rule_") and std.mem.endsWith(u8, export_info.name, "_descriptor")) {
            var result: [1]u64 = undefined;
            try wasm_module.invoke(export_info.name, &.{}, result[0..]);
            const length: u32 = @intCast(result[0] & 0xFFFFFFFF);
            const offset: u32 = @intCast((result[0] >> 32) & 0xFFFFFFFF);

            const bytes = try wasm_module.memoryRead(allocator, offset, length);
            defer allocator.free(bytes);

            const parsed = try std.json.parseFromSlice(module.RuleDescriptor, allocator, bytes, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            _ = try builder.registerRule(parsed.value);
        }
    }
}

test "wire: parses wasm exports and builds indices from basic.wasm" {
    const bytes = @embedFile("./testdata/basic.wasm");
    const allocator = std.testing.allocator;
    var wasm_module = try zwasm.WasmModule.loadWasi(allocator, bytes);
    defer wasm_module.deinit();

    var forward = graph_index.ForwardIndex{};
    var reverse = graph_index.ReverseIndex{};
    defer {
        var f_iter = forward.iterator();
        while (f_iter.next()) |entry| {
            allocator.free(entry.value_ptr.watchers);
            allocator.free(entry.value_ptr.source);
            allocator.free(entry.value_ptr.component_type);
            allocator.free(entry.value_ptr.mapper);
        }
        forward.deinit(allocator);

        var r_iter = reverse.iterator();
        while (r_iter.next()) |entry| {
            allocator.free(entry.value_ptr.watch);
            allocator.free(entry.value_ptr.entrypoint);
            allocator.free(entry.value_ptr.module);
            allocator.free(entry.value_ptr.namespace);
        }
        reverse.deinit(allocator);
    }

    try wire(allocator, wasm_module, &forward, &reverse, "test_ns", "basic.wasm");

    try std.testing.expect(forward.count() > 0);
    try std.testing.expect(reverse.count() > 0);
}

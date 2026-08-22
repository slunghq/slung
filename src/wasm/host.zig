//! Host runtime support — exposes host ABI to Wasm modules.
//!
//! Organizes functions by capability class:
//! + Generic: core memory & runtime (slung_get, slung_set, slung_now, slung_yield)
//! + HTTP: HTTP client (slung_http_get, slung_http_post)
//! + WebSocket: WebSocket client (slung_ws_connect, slung_ws_next, slung_ws_send, slung_ws_close)
//! + TCP/UDP: raw sockets (slung_tcp_*, slung_udp_*)
//! + Queue: message brokers (slung_nats_*, slung_kafka_*)

const std = @import("std");

const zwasm = @import("zwasm");
const build_options = @import("build_options");

pub const generic = @import("host_abi/generic.zig");
pub const http = if (build_options.enable_connectors) @import("host_abi/http.zig") else null;
pub const queue = @import("host_abi/queue.zig");
pub const tcp_udp = @import("host_abi/tcp_udp.zig");
pub const ws = if (build_options.enable_connectors) @import("host_abi/ws.zig") else null;

fn buildHostImports(allocator: std.mem.Allocator, context: usize) !std.ArrayList(zwasm.HostFnEntry) {
    var host_fns: std.ArrayList(zwasm.HostFnEntry) = .empty;

    try generic.appendHostFunctions(&host_fns, allocator, context);
    if (build_options.enable_connectors) {
        try @import("host_abi/http.zig").appendHostFunctions(&host_fns, allocator, context);
        try @import("host_abi/ws.zig").appendHostFunctions(&host_fns, allocator, context);
    }
    try tcp_udp.appendHostFunctions(&host_fns, allocator, context);
    try queue.appendHostFunctions(&host_fns, allocator, context);

    return host_fns;
}

pub fn createEnvImport(allocator: std.mem.Allocator, context: usize) !zwasm.ImportEntry {
    var host_fns = try buildHostImports(allocator, context);
    defer host_fns.deinit(allocator);

    return zwasm.ImportEntry{
        .module = "env",
        .source = .{ .host_fns = try allocator.dupe(zwasm.HostFnEntry, host_fns.items) },
    };
}

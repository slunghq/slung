const std = @import("std");
const slung = @import("slung");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var rt = try @import("zio").Runtime.init(allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    // argv[0] is executable name
    _ = it.next();
    const cmd = it.next() orelse {
        usage();
        return error.InvalidArguments;
    };

    if (std.mem.eql(u8, cmd, "run")) {
        try cmdRun(allocator, io, &it);
        return;
    }

    usage();
    return error.InvalidArguments;
}

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  slung run --module <path.wasm> --namespace <ns> --node-id <id> [--ws-port <port>]
        \\
        \\Notes:
        \\  - Sources are discovered from `__slung_source_*_descriptor` exports in the module.
        \\  - WebSocket ingress routes are `/<namespace>/<source>/<component_type>`.
        \\
        \\
    , .{});
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, it: anytype) !void {
    var module_path: ?[]const u8 = null;
    var namespace: []const u8 = "default";
    var node_id: []const u8 = "node-1";
    var ws_port: u16 = 2073;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--module")) {
            module_path = it.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--namespace")) {
            namespace = it.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            node_id = it.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--ws-port")) {
            const v = it.next() orelse return error.InvalidArguments;
            ws_port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else {
            return error.InvalidArguments;
        }
    }

    const module_path_resolved = module_path orelse return error.InvalidArguments;

    const wasm_bytes = try readFile(allocator, io, module_path_resolved);
    defer allocator.free(wasm_bytes);

    const server = try allocator.create(slung.engine.Server);
    errdefer allocator.destroy(server);
    server.* = try slung.engine.Server.init(allocator, io, .{ .port = ws_port });

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *slung.engine.Server, alloc: std.mem.Allocator) !void {
            defer s.deinit();
            defer alloc.destroy(s);
            try s.serve();
        }
    }.run, .{ server, allocator });
    server_thread.detach();

    const config = slung.engine.ModuleConfig{
        .io = io,
        .namespace = namespace,
        .node_id = node_id,
        .server = server,
    };

    var session = try slung.engine.ModuleSession.init(allocator, io, wasm_bytes, config);
    defer session.deinit();

    try session.runForever();
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const data = try allocator.alloc(u8, stat.size);
    var reader = file.reader(io, &[_]u8{});
    try reader.interface.readSliceAll(data);
    return data;
}

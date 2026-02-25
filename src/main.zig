const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const http = @import("dusty");
const testing = std.testing;
const ds = @import("ds/ds.zig");
const tsm = @import("tsm/tsm.zig");
const query = @import("query.zig");
const net = std.net;
const execute = @import("host/execute.zig");
const csv = @import("csv.zig");
const config = @import("config.zig");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Channel = zio.Channel;
const Query = query.Query;
const TsmTree = tsm.TsmTree;
const Notify = zio.Notify;
const CHANNEL_CAPACITY = 8192 * 2;

pub const AppContext = struct {
    io: *zio.Runtime,
    server: *Server,
};

pub const StreamConfig = config.StreamConfig;

// rn we'll be making this single-instance
// so we don't need to hold any extra server data
const Server = struct {
    const max_queries = 16;
    const PendingEvent = struct {
        timestamp: i64,
        value: f64,
        producer: u64,
    };

    allocator: std.mem.Allocator,
    connections: Connections,
    connections_mutex: std.Thread.Mutex,
    next_connection_id: std.atomic.Value(u64),
    channel: *Channel(ChannelData),
    queries: AutoHashMap(u32, Query),
    query_events: AutoHashMap(u32, PendingEvent),
    series_key_cache: std.StringArrayHashMap([]const u8),
    series_key_by_hash: std.AutoHashMap(u64, []const u8),
    series_key_hash_collisions: std.AutoHashMap(u64, void),
    series_by_measurement: std.StringArrayHashMap(std.ArrayList([]const u8)),
    series_by_measurement_tag: std.StringArrayHashMap(std.ArrayList([]const u8)),
    next_query_id: std.atomic.Value(u32),
    tree: *TsmTree,
    notify: *Notify,
    stream_config: *StreamConfig,

    const ChannelData = struct {
        /// to be used as id if not streamed with data
        id: u64,
        data: []const u8,
    };
    const Connections = AutoHashMap(u64, *http.WebSocket);

    pub fn init(
        context: *AppContext,
        channel: *Channel(ChannelData),
        tree: *TsmTree,
        notify: *Notify,
        stream_config: *StreamConfig,
    ) !Server {
        return Server{
            .allocator = context.io.allocator,
            .connections = Connections.init(context.io.allocator),
            .connections_mutex = .{},
            .next_connection_id = std.atomic.Value(u64).init(1),
            .channel = channel,
            .queries = AutoHashMap(u32, Query).init(context.io.allocator),
            .query_events = AutoHashMap(u32, PendingEvent).init(context.io.allocator),
            .series_key_cache = std.StringArrayHashMap([]const u8).init(context.io.allocator),
            .series_key_by_hash = std.AutoHashMap(u64, []const u8).init(context.io.allocator),
            .series_key_hash_collisions = std.AutoHashMap(u64, void).init(context.io.allocator),
            .series_by_measurement = std.StringArrayHashMap(std.ArrayList([]const u8)).init(context.io.allocator),
            .series_by_measurement_tag = std.StringArrayHashMap(std.ArrayList([]const u8)).init(context.io.allocator),
            .next_query_id = std.atomic.Value(u32).init(1),
            .tree = tree,
            .notify = notify,
            .stream_config = stream_config,
        };
    }

    pub fn deinit(self: *Server) void {
        var iter_series = self.series_key_cache.iterator();
        while (iter_series.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.series_key_cache.deinit();
        self.series_key_by_hash.deinit();
        self.series_key_hash_collisions.deinit();
        var iter_measurement = self.series_by_measurement.iterator();
        while (iter_measurement.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.series_by_measurement.deinit();
        var iter_measurement_tag = self.series_by_measurement_tag.iterator();
        while (iter_measurement_tag.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.series_by_measurement_tag.deinit();
        self.connections.deinit();
        self.queries.deinit();
        self.query_events.deinit();
    }

    pub fn internSeriesKey(self: *Server, key_bytes: []const u8) !struct { key: []const u8, inserted: bool } {
        const entry = try self.series_key_cache.getOrPut(key_bytes);
        if (entry.found_existing) return .{ .key = entry.value_ptr.*, .inserted = false };

        const owned = try self.allocator.dupe(u8, key_bytes);
        entry.key_ptr.* = owned;
        entry.value_ptr.* = owned;
        return .{ .key = owned, .inserted = true };
    }

    pub fn resolveSeriesKey(self: *Server, scratch: *std.ArrayList(u8), series: []const u8, tags: []const []const u8) ![]const u8 {
        const h = hashSeriesAndTags(series, tags);
        if (!self.series_key_hash_collisions.contains(h)) {
            if (self.series_key_by_hash.get(h)) |existing_key| {
                if (matchesSeriesAndTags(existing_key, series, tags)) {
                    return existing_key;
                }
                try self.series_key_hash_collisions.put(h, {});
            }
        }

        try writeSeriesKey(scratch, self.allocator, series, tags);
        const interned = try self.internSeriesKey(scratch.items);
        const key = interned.key;
        if (interned.inserted) {
            try self.indexSeriesKey(key);
        }
        if (!self.series_key_hash_collisions.contains(h)) {
            try self.series_key_by_hash.put(h, key);
        }
        return key;
    }

    pub fn matchingSeriesKeysForQuery(self: *Server, allocator: std.mem.Allocator, q: *const Query) ![]const []const u8 {
        const universe = self.series_by_measurement.get(q.series) orelse return try allocator.alloc([]const u8, 0);
        if (q.tagsSlice().len == 0) {
            return try allocator.dupe([]const u8, universe.items);
        }

        var current = std.StringHashMap(void).init(allocator);
        defer current.deinit();

        var cursor: usize = 0;
        var combined = false;
        while (cursor < q.tagsSlice().len) {
            const token = q.tagsSlice()[cursor];

            if (!combined) {
                var first = try self.operandSetForQuery(allocator, q, &cursor, universe.items);
                defer first.deinit();
                var it = first.iterator();
                while (it.next()) |entry| {
                    try current.put(entry.key_ptr.*, {});
                }
                combined = true;
                continue;
            }

            const op = switch (token) {
                .op => |v| v,
                .tag => return error.InvalidTags,
            };
            cursor += 1;

            var rhs = try self.operandSetForQuery(allocator, q, &cursor, universe.items);
            defer rhs.deinit();

            var merged = std.StringHashMap(void).init(allocator);
            defer merged.deinit();

            if (op == .or_op) {
                var left_iter = current.iterator();
                while (left_iter.next()) |entry| {
                    try merged.put(entry.key_ptr.*, {});
                }
                var right_iter = rhs.iterator();
                while (right_iter.next()) |entry| {
                    try merged.put(entry.key_ptr.*, {});
                }
            } else {
                var left_iter = current.iterator();
                while (left_iter.next()) |entry| {
                    if (rhs.contains(entry.key_ptr.*)) {
                        try merged.put(entry.key_ptr.*, {});
                    }
                }
            }

            current.clearRetainingCapacity();
            var merged_iter = merged.iterator();
            while (merged_iter.next()) |entry| {
                try current.put(entry.key_ptr.*, {});
            }
        }

        var out = std.ArrayList([]const u8).empty;
        defer out.deinit(allocator);
        var iter = current.iterator();
        while (iter.next()) |entry| {
            try out.append(allocator, entry.key_ptr.*);
        }
        return out.toOwnedSlice(allocator);
    }

    fn operandSetForQuery(self: *Server, allocator: std.mem.Allocator, q: *const Query, cursor: *usize, universe: []const []const u8) !std.StringHashMap(void) {
        var negated = false;
        while (cursor.* < q.tagsSlice().len) {
            const token = q.tagsSlice()[cursor.*];
            switch (token) {
                .op => |op| {
                    if (op != .not_op) return error.InvalidTags;
                    negated = !negated;
                    cursor.* += 1;
                },
                .tag => |tag| {
                    cursor.* += 1;
                    var direct = try self.seriesSetForTag(allocator, q.series, tag);
                    defer direct.deinit();

                    var out = std.StringHashMap(void).init(allocator);
                    if (!negated) {
                        var it = direct.iterator();
                        while (it.next()) |entry| {
                            try out.put(entry.key_ptr.*, {});
                        }
                    } else {
                        for (universe) |series_key| {
                            if (!direct.contains(series_key)) {
                                try out.put(series_key, {});
                            }
                        }
                    }
                    return out;
                },
            }
        }
        return error.InvalidTags;
    }

    fn seriesSetForTag(self: *Server, allocator: std.mem.Allocator, series: []const u8, tag: []const u8) !std.StringHashMap(void) {
        var out = std.StringHashMap(void).init(allocator);

        var scratch = std.ArrayList(u8).empty;
        defer scratch.deinit(allocator);
        const key = try measurementTagKey(&scratch, allocator, series, tag);
        const matches = self.series_by_measurement_tag.get(key) orelse return out;
        for (matches.items) |series_key| {
            try out.put(series_key, {});
        }
        return out;
    }

    fn indexSeriesKey(self: *Server, series_key: []const u8) !void {
        var parts = std.mem.splitScalar(u8, series_key, ',');
        const measurement = parts.next() orelse return error.InvalidSeriesKey;
        try self.indexAppendMeasurement(measurement, series_key);

        while (parts.next()) |tag| {
            const trimmed = std.mem.trim(u8, tag, " \t\r\n");
            if (trimmed.len == 0) continue;
            try self.indexAppendMeasurementTag(measurement, trimmed, series_key);
        }
    }

    fn indexAppendMeasurement(self: *Server, measurement: []const u8, series_key: []const u8) !void {
        const entry = try self.series_by_measurement.getOrPut(measurement);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, measurement);
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, series_key);
    }

    fn indexAppendMeasurementTag(self: *Server, measurement: []const u8, tag: []const u8, series_key: []const u8) !void {
        var scratch = std.ArrayList(u8).empty;
        defer scratch.deinit(self.allocator);
        const key = try measurementTagKey(&scratch, self.allocator, measurement, tag);

        const entry = try self.series_by_measurement_tag.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, series_key);
    }

    pub fn addConnection(self: *Server, websocket: *http.WebSocket) !u64 {
        const id = self.next_connection_id.fetchAdd(1, .monotonic);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        try self.connections.put(id, websocket);

        return id;
    }

    pub fn removeConnection(self: *Server, id: u64) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        _ = self.connections.remove(id);
    }
};

fn handleMessage(msg: http.WebSocket.Message, id: u64, context: *AppContext) !void {
    const message = Server.ChannelData{
        .id = id,
        .data = msg.data,
    };
    if (context.server.notify.wait_queue.hasWaiters()) context.server.notify.broadcast();
    context.server.channel.send(message) catch |err| switch (err) {
        error.ChannelClosed => {
            std.log.debug("Producer {}: channel closed, exiting", .{id});
            return;
        },
        error.Canceled => {
            std.log.debug("Producer {}: canceled, exiting", .{id});
            return;
        },
    };
}

fn handleWebSocket(context: *AppContext, req: *http.Request, res: *http.Response) !void {
    var websocket = try res.upgradeWebSocket(req) orelse {
        try handleIndexPost(context, req, res);
        return;
    };
    const id = try context.server.addConnection(&websocket);
    errdefer websocket.close(.internal_error, "handler error") catch {};
    errdefer context.server.removeConnection(id);
    defer context.server.removeConnection(id);

    while (true) {
        const msg = websocket.receive() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (msg.type) {
            .text => {
                handleMessage(msg, id, context) catch return;
            },
            .binary => {
                handleMessage(msg, id, context) catch return;
            },
            .close => {
                std.log.info("Client closed connection", .{});
                break;
            },
            else => {},
        }
    }
}

fn handleHealth(_: *AppContext, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.body =
        \\{
        \\ "status": "ok",
        \\}
    ;
}

fn handleIndexPost(_: *AppContext, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "application/json");
    res.status = .bad_request;
    res.body =
        \\{
        \\ "status": "ok",
        \\ "info": "use websocket binary frames to stream data"
        \\}
    ;
}

pub fn runServer(allocator: std.mem.Allocator, context: *AppContext) !void {
    var server = http.Server(AppContext).init(allocator, .{}, context);
    defer server.deinit();

    server.router.get("/", handleWebSocket);
    server.router.post("/", handleIndexPost);
    server.router.get("/health", handleHealth);

    const addr = try zio.net.IpAddress.parseIp("0.0.0.0", 2077);

    std.log.info("Slung server listening on http://0.0.0.0:2077", .{});
    try server.listen(addr);
}

pub fn handleWasm(allocator: std.mem.Allocator, context: *AppContext) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    var wasm_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wasm")) {
            wasm_path = args.next() orelse return error.InvalidWasmPath;
            continue;
        }
    }
    const path = wasm_path orelse @panic("Set the path to the Wasm file with --wasm <path>");
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);

    const context_ptr = @intFromPtr(context);
    try context.server.notify.wait();
    try execute.spawn(allocator, bytes, context_ptr);
}

const DecodedMessage = struct {
    timestamp: i64,
    value: f64,
    series: []const u8,
    tags: []const []const u8,
};

fn decodeBinaryMessage(allocator: std.mem.Allocator, data: []const u8, tag_scratch: *std.ArrayList([]const u8)) !DecodedMessage {
    // little-endian:
    // [timestamp:i64][value:f64][series_len:u16][tag_count:u16][series][tag_len:u16+tag_bytes]...
    const header_len = 8 + 8 + 2 + 2;
    if (data.len < header_len) return error.InvalidMessage;

    var offset: usize = 0;
    const timestamp_bits = std.mem.readInt(u64, data[offset..][0..8], .little);
    const timestamp: i64 = @bitCast(timestamp_bits);
    offset += 8;

    const value_bits = std.mem.readInt(u64, data[offset..][0..8], .little);
    const value: f64 = @bitCast(value_bits);
    offset += 8;

    const series_len = @as(usize, std.mem.readInt(u16, data[offset..][0..2], .little));
    offset += 2;
    const tag_count = @as(usize, std.mem.readInt(u16, data[offset..][0..2], .little));
    offset += 2;

    if (offset + series_len > data.len) return error.InvalidMessage;
    const series = data[offset .. offset + series_len];
    offset += series_len;

    tag_scratch.clearRetainingCapacity();
    try tag_scratch.ensureTotalCapacity(allocator, tag_count);

    var i: usize = 0;
    while (i < tag_count) : (i += 1) {
        if (offset + 2 > data.len) return error.InvalidMessage;
        const tag_len = @as(usize, std.mem.readInt(u16, data[offset..][0..2], .little));
        offset += 2;
        if (offset + tag_len > data.len) return error.InvalidMessage;
        try tag_scratch.append(allocator, data[offset .. offset + tag_len]);
        offset += tag_len;
    }

    if (offset != data.len) return error.InvalidMessage;

    return .{
        .timestamp = timestamp,
        .value = value,
        .series = series,
        .tags = tag_scratch.items,
    };
}

fn writeSeriesKey(out: *std.ArrayList(u8), allocator: std.mem.Allocator, series: []const u8, tags: []const []const u8) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(allocator, series);
    for (tags) |tag| {
        if (tag.len == 0) continue;
        try out.append(allocator, ',');
        try out.appendSlice(allocator, tag);
    }
}

fn measurementTagKey(scratch: *std.ArrayList(u8), allocator: std.mem.Allocator, measurement: []const u8, tag: []const u8) ![]const u8 {
    scratch.clearRetainingCapacity();
    try scratch.appendSlice(allocator, measurement);
    try scratch.append(allocator, 0x1f);
    try scratch.appendSlice(allocator, tag);
    return scratch.items;
}

fn hashSeriesAndTags(series: []const u8, tags: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const len_buf: [8]u8 = std.mem.toBytes(@as(u64, @intCast(series.len)));
    hasher.update(&len_buf);
    hasher.update(series);
    for (tags) |tag| {
        const tag_len_buf: [8]u8 = std.mem.toBytes(@as(u64, @intCast(tag.len)));
        hasher.update(&tag_len_buf);
        hasher.update(tag);
    }
    return hasher.final();
}

fn matchesSeriesAndTags(key: []const u8, series: []const u8, tags: []const []const u8) bool {
    var offset: usize = 0;
    if (key.len < series.len) return false;
    if (!std.mem.eql(u8, key[0..series.len], series)) return false;
    offset = series.len;

    for (tags) |tag| {
        if (tag.len == 0) continue;
        if (offset >= key.len or key[offset] != ',') return false;
        offset += 1;
        if (offset + tag.len > key.len) return false;
        if (!std.mem.eql(u8, key[offset .. offset + tag.len], tag)) return false;
        offset += tag.len;
    }

    return offset == key.len;
}

fn handleWasmWebsocket(context: *AppContext) !void {
    try context.server.notify.wait();
    var key_scratch = std.ArrayList(u8).empty;
    defer key_scratch.deinit(context.io.allocator);
    var tag_scratch: std.ArrayList([]const u8) = .empty;
    defer tag_scratch.deinit(context.io.allocator);

    while (true) {
        var recv = context.server.channel.asyncReceive();
        const result = try zio.select(.{ .recv = &recv });
        switch (result) {
            .recv => |val| {
                const value = try val;
                const message = decodeBinaryMessage(context.io.allocator, value.data, &tag_scratch) catch |err| {
                    std.log.warn("Ignoring websocket payload; expected binary [i64 timestamp][f64 value][u16 series_len][u16 tag_count][series][tags...]: {}", .{err});
                    continue;
                };
                const series_key = try context.server.resolveSeriesKey(&key_scratch, message.series, message.tags);
                try context.server.tree.insert(series_key, .{
                    .timestamp = message.timestamp,
                    .value = .{ .Float = message.value },
                });

                context.server.connections_mutex.lock();
                defer context.server.connections_mutex.unlock();

                var iter_queries = context.server.queries.iterator();
                while (iter_queries.next()) |entry| {
                    const query_id = entry.key_ptr.*;
                    const q = entry.value_ptr;
                    if (!std.mem.eql(u8, q.series, message.series)) {
                        continue;
                    }
                    if (!q.matchesTags(message.tags)) {
                        continue;
                    }
                    if (q.has_time_range and (message.timestamp < q.time_start or message.timestamp > q.time_end)) {
                        continue;
                    }

                    switch (q.op) {
                        .Avg => {
                            q.*.op.Avg.count += 1;
                            q.*.op.Avg.sum += message.value;
                        },
                        .Sum => {
                            q.*.op.Sum += message.value;
                        },
                        .Count => {
                            q.*.op.Count += 1;
                        },
                        .Max => {
                            if (message.value > q.*.op.Max) q.*.op.Max = message.value;
                        },
                        .Min => {
                            if (message.value < q.*.op.Min) q.*.op.Min = message.value;
                        },
                        .None => continue,
                    }

                    context.server.query_events.put(query_id, .{
                        .timestamp = message.timestamp,
                        .value = message.value,
                        .producer = value.id,
                    }) catch {};
                }
            },
        }
    }
}

fn loadConfig(allocator: std.mem.Allocator, stream_config: *StreamConfig) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    var config_path: []const u8 = "./config.toml";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return error.InvalidConfigPath;
            continue;
        }
    }

    stream_config.* = (try config.parseFromConfigFile(allocator, config_path)).value;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    var buffer: [2 * 1024 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = switch (builtin.mode) {
        .ReleaseSmall => fba.allocator(),
        else => gpa.allocator(),
    };

    var io = try zio.Runtime.init(allocator, .{});
    defer io.deinit();

    var group: zio.Group = .init;
    defer group.cancel();

    var context: AppContext = .{
        .io = io,
        .server = undefined,
    };

    const channel_buffer = try allocator.alloc(Server.ChannelData, CHANNEL_CAPACITY);
    defer allocator.free(channel_buffer);
    var channel = Channel(Server.ChannelData).init(channel_buffer[0..]);

    var tree = try TsmTree.init(allocator, "demo");
    defer tree.deinit();

    var notify = Notify.init;

    // TODO: parse from slung.toml or cli argument
    var stream_config = StreamConfig{};
    try loadConfig(allocator, &stream_config);

    var server = try Server.init(&context, &channel, &tree, &notify, &stream_config);
    context.server = &server;
    defer server.deinit();

    try group.spawn(handleWasmWebsocket, .{&context});
    try group.spawn(handleWasm, .{ allocator, &context });
    try group.spawn(runServer, .{ allocator, &context });

    try group.wait();
}

test {
    _ = csv;
    _ = config;
    _ = ds;
    _ = tsm;
    _ = query;
}

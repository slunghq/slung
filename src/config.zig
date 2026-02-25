const std = @import("std");
const toml = @import("toml");

pub const StreamConfig = struct {
    ingest: []const Ingest = &.{.{ .WebSocket = .{ .mode = .Native, .port = 2077 } }},
    flush: Flush = .Native,
    sync: Sync = .None,
    populate: []const Populate = &.{.None},

    pub const Ingest = union(enum) {
        WebSocket: struct { mode: enum { Native, MsgPack }, port: u16 },
        NATS: struct { subscriptions: []const []const u8, url: []const u8 },
        HTTP: struct { port: u16 },
        MQTT: struct { topics: []const []const u8, url: []const u8 },
    };

    pub const Flush = enum { Native, CSV };

    pub const Sync = union(enum) {
        None,
        S3: []const u8,
        R2: []const u8,
        Socket: []const u8,
    };

    pub const Populate = union(enum) {
        None,
        CSV: []const u8,
        TDMS: []const u8,
    };
};

const RawConfig = struct {
    name: []const u8,
    lang: []const u8,
    ingest: Ingest,
    flush: Flush,
    sync: Sync,
    populate: Populate,
    tree: Tree,

    const Ingest = struct {
        method: []const []const u8,
        websocket: ?[]const struct {
            method: []const u8,
            port: u16,
        } = null,
        http: ?[]const struct { port: u16 } = null,
        nats: ?[]const struct {
            // Keep compatibility with existing typo in config.toml.
            subscribtions: ?[]const []const u8 = null,
            subscriptions: ?[]const []const u8 = null,
            url: []const u8,
        } = null,
        mqtt: ?[]const struct {
            topics: []const []const u8,
            url: []const u8,
        } = null,
    };

    const Flush = struct {
        method: []const u8,
    };

    const Sync = struct {
        method: []const u8,
        s3: ?struct { bucket: []const u8 } = null,
        r2: ?struct { bucket: []const u8 } = null,
        socket: ?struct { port: u16 } = null,
    };

    const Populate = struct {
        method: []const []const u8,
        csv: ?struct { path: []const u8 } = null,
        tdms: ?struct { path: []const u8 } = null,
    };

    const Tree = struct {
        page_size: u32,
        max_level: u32,
    };
};

pub const ParsedStreamConfig = struct {
    parsed: toml.Parsed(RawConfig),
    value: StreamConfig,

    pub fn deinit(self: *ParsedStreamConfig) void {
        self.parsed.deinit();
    }
};

fn parseRawConfigFile(allocator: std.mem.Allocator, path: []const u8) !toml.Parsed(RawConfig) {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(content);

    var parser = toml.Parser(RawConfig).init(allocator);
    defer parser.deinit();

    return parser.parseString(content);
}

fn tableItemAtOrFirst(comptime T: type, items: []const T, index: usize) T {
    if (items.len == 0) @panic("tableItemAtOrFirst called with empty items");
    if (index < items.len) return items[index];
    return items[0];
}

pub fn parseFromConfigFile(allocator: std.mem.Allocator, path: []const u8) !ParsedStreamConfig {
    var parsed = try parseRawConfigFile(allocator, path);
    errdefer parsed.deinit();

    const cfg = parsed.value;
    var stream = StreamConfig{};

    if (cfg.ingest.method.len == 0) return error.MissingIngestMethod;
    const ingest_list = try parsed.arena.allocator().alloc(StreamConfig.Ingest, cfg.ingest.method.len);
    for (cfg.ingest.method, 0..) |method, i| {
        if (std.ascii.eqlIgnoreCase(method, "websocket")) {
            const websocket_items = cfg.ingest.websocket orelse return error.MissingIngestWebSocketConfig;
            const websocket = tableItemAtOrFirst(@TypeOf(websocket_items[0]), websocket_items, i);
            if (std.ascii.eqlIgnoreCase(websocket.method, "msgpack")) {
                ingest_list[i] = .{ .WebSocket = .{ .mode = .MsgPack, .port = websocket.port } };
            } else if (std.ascii.eqlIgnoreCase(websocket.method, "native")) {
                ingest_list[i] = .{ .WebSocket = .{ .mode = .Native, .port = websocket.port } };
            } else {
                return error.InvalidIngestMethod;
            }
        } else if (std.ascii.eqlIgnoreCase(method, "nats")) {
            const nats_items = cfg.ingest.nats orelse return error.MissingIngestNatsConfig;
            const nats = tableItemAtOrFirst(@TypeOf(nats_items[0]), nats_items, i);
            const subscriptions = nats.subscriptions orelse nats.subscribtions orelse return error.MissingNatsSubscriptions;
            if (subscriptions.len == 0) return error.MissingNatsSubscriptions;
            ingest_list[i] = .{ .NATS = .{ .subscriptions = subscriptions, .url = nats.url } };
        } else if (std.ascii.eqlIgnoreCase(method, "http")) {
            const http_items = cfg.ingest.http orelse return error.MissingIngestHttpConfig;
            const http = tableItemAtOrFirst(@TypeOf(http_items[0]), http_items, i);
            ingest_list[i] = .{ .HTTP = .{ .port = http.port } };
        } else if (std.ascii.eqlIgnoreCase(method, "mqtt")) {
            const mqtt_items = cfg.ingest.mqtt orelse return error.MissingIngestMqttConfig;
            const mqtt = tableItemAtOrFirst(@TypeOf(mqtt_items[0]), mqtt_items, i);
            ingest_list[i] = .{ .MQTT = .{ .topics = mqtt.topics, .url = mqtt.url } };
        } else {
            return error.InvalidIngestMethod;
        }
    }
    stream.ingest = ingest_list;

    if (std.ascii.eqlIgnoreCase(cfg.flush.method, "native")) {
        stream.flush = .Native;
    } else if (std.ascii.eqlIgnoreCase(cfg.flush.method, "csv")) {
        stream.flush = .CSV;
    } else {
        return error.InvalidFlushMethod;
    }

    if (std.ascii.eqlIgnoreCase(cfg.sync.method, "none")) {
        stream.sync = .None;
    } else if (std.ascii.eqlIgnoreCase(cfg.sync.method, "s3")) {
        const s3 = cfg.sync.s3 orelse return error.MissingS3Config;
        stream.sync = .{ .S3 = s3.bucket };
    } else if (std.ascii.eqlIgnoreCase(cfg.sync.method, "r2")) {
        const r2 = cfg.sync.r2 orelse return error.MissingR2Config;
        stream.sync = .{ .R2 = r2.bucket };
    } else if (std.ascii.eqlIgnoreCase(cfg.sync.method, "socket")) {
        const socket = cfg.sync.socket orelse return error.MissingSocketConfig;
        const endpoint = try std.fmt.allocPrint(parsed.arena.allocator(), "0.0.0.0:{d}", .{socket.port});
        stream.sync = .{ .Socket = endpoint };
    } else {
        return error.InvalidSyncMethod;
    }

    if (cfg.populate.method.len == 0) return error.MissingPopulateMethod;
    const populate_list = try parsed.arena.allocator().alloc(StreamConfig.Populate, cfg.populate.method.len);
    for (cfg.populate.method, 0..) |method, i| {
        if (std.ascii.eqlIgnoreCase(method, "none")) {
            populate_list[i] = .None;
        } else if (std.ascii.eqlIgnoreCase(method, "csv")) {
            const csv_cfg = cfg.populate.csv orelse return error.MissingPopulateCsvConfig;
            populate_list[i] = .{ .CSV = csv_cfg.path };
        } else if (std.ascii.eqlIgnoreCase(method, "tdms")) {
            const tdms_cfg = cfg.populate.tdms orelse return error.MissingPopulateTdmsConfig;
            populate_list[i] = .{ .TDMS = tdms_cfg.path };
        } else {
            return error.InvalidPopulateMethod;
        }
    }
    stream.populate = populate_list;

    return .{
        .parsed = parsed,
        .value = stream,
    };
}

test "parse mapped stream config from config.toml" {
    var parsed = try parseFromConfigFile(std.testing.allocator, "config.toml");
    defer parsed.deinit();

    const stream = parsed.value;

    try std.testing.expectEqual(@as(usize, 2), stream.ingest.len);

    switch (stream.ingest[0]) {
        .WebSocket => |ws| {
            try std.testing.expectEqual(.Native, ws.mode);
            try std.testing.expectEqual(@as(u16, 2077), ws.port);
        },
        else => return error.TestExpectedWebSocketIngest,
    }

    switch (stream.ingest[1]) {
        .NATS => |nats| {
            try std.testing.expect(std.mem.eql(u8, nats.url, "nats://localhost:4222"));
            try std.testing.expectEqual(@as(usize, 1), nats.subscriptions.len);
            try std.testing.expect(std.mem.eql(u8, nats.subscriptions[0], "slung"));
        },
        else => return error.TestExpectedNatsIngest,
    }

    try std.testing.expectEqual(.Native, stream.flush);

    switch (stream.sync) {
        .S3 => |bucket| try std.testing.expect(std.mem.eql(u8, bucket, "slung")),
        else => return error.TestExpectedS3Sync,
    }

    try std.testing.expectEqual(@as(usize, 2), stream.populate.len);
    switch (stream.populate[0]) {
        .CSV => |csv_path| try std.testing.expect(std.mem.eql(u8, csv_path, "/tmp/data.csv")),
        else => return error.TestExpectedCsvPopulate,
    }
    switch (stream.populate[1]) {
        .TDMS => |tdms_path| try std.testing.expect(std.mem.eql(u8, tdms_path, "/tmp/data.tdms")),
        else => return error.TestExpectedTdmsPopulate,
    }
}

test "parse config.toml cases" {
    var parsed = try parseRawConfigFile(std.testing.allocator, "config.toml");
    defer parsed.deinit();

    const cfg = parsed.value;

    try std.testing.expect(std.mem.eql(u8, cfg.name, "basic"));
    try std.testing.expect(std.mem.eql(u8, cfg.lang, "rust"));

    try std.testing.expectEqual(@as(usize, 2), cfg.ingest.method.len);
    try std.testing.expect(std.mem.eql(u8, cfg.ingest.method[0], "websocket"));
    try std.testing.expect(std.mem.eql(u8, cfg.ingest.method[1], "nats"));

    const websocket_items = cfg.ingest.websocket orelse return error.TestMissingWebSocketTable;
    try std.testing.expectEqual(@as(usize, 1), websocket_items.len);
    try std.testing.expect(std.mem.eql(u8, websocket_items[0].method, "native"));
    try std.testing.expectEqual(@as(u16, 2077), websocket_items[0].port);

    const http_items = cfg.ingest.http orelse return error.TestMissingHttpTable;
    try std.testing.expectEqual(@as(usize, 1), http_items.len);
    try std.testing.expectEqual(@as(u16, 2078), http_items[0].port);

    const nats_items = cfg.ingest.nats orelse return error.TestMissingNatsTable;
    try std.testing.expectEqual(@as(usize, 1), nats_items.len);
    const nats_subs = nats_items[0].subscriptions orelse nats_items[0].subscribtions orelse return error.TestMissingNatsSubscriptions;
    try std.testing.expectEqual(@as(usize, 1), nats_subs.len);
    try std.testing.expect(std.mem.eql(u8, nats_subs[0], "slung"));
    try std.testing.expect(std.mem.eql(u8, nats_items[0].url, "nats://localhost:4222"));

    const mqtt_items = cfg.ingest.mqtt orelse return error.TestMissingMqttTable;
    try std.testing.expectEqual(@as(usize, 1), mqtt_items.len);
    try std.testing.expectEqual(@as(usize, 1), mqtt_items[0].topics.len);
    try std.testing.expect(std.mem.eql(u8, mqtt_items[0].topics[0], "slung"));
    try std.testing.expect(std.mem.eql(u8, mqtt_items[0].url, "mqtt://localhost:1883"));

    try std.testing.expect(std.mem.eql(u8, cfg.flush.method, "native"));
    try std.testing.expect(std.mem.eql(u8, cfg.sync.method, "s3"));

    const s3 = cfg.sync.s3 orelse return error.TestMissingS3;
    const r2 = cfg.sync.r2 orelse return error.TestMissingR2;
    const socket = cfg.sync.socket orelse return error.TestMissingSocket;
    try std.testing.expect(std.mem.eql(u8, s3.bucket, "slung"));
    try std.testing.expect(std.mem.eql(u8, r2.bucket, "slung"));
    try std.testing.expectEqual(@as(u16, 2080), socket.port);

    try std.testing.expectEqual(@as(usize, 2), cfg.populate.method.len);
    try std.testing.expect(std.mem.eql(u8, cfg.populate.method[0], "csv"));
    try std.testing.expect(std.mem.eql(u8, cfg.populate.method[1], "tdms"));

    const csv_cfg = cfg.populate.csv orelse return error.TestMissingPopulateCsv;
    const tdms_cfg = cfg.populate.tdms orelse return error.TestMissingPopulateTdms;
    try std.testing.expect(std.mem.eql(u8, csv_cfg.path, "/tmp/data.csv"));
    try std.testing.expect(std.mem.eql(u8, tdms_cfg.path, "/tmp/data.tdms"));

    try std.testing.expectEqual(@as(u32, 4096), cfg.tree.page_size);
    try std.testing.expectEqual(@as(u32, 100_000), cfg.tree.max_level);
}

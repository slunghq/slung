const std = @import("std");
const toml = @import("toml");

pub const Config = struct {
    version: ?i64 = null,
    cli: Cli = .{},
    run: Run = .{},
    deployment: Deployment = .{},
    storage: Storage = .{},
    observability: Observability = .{},

    pub const Cli = struct {
        color: ?[]const u8 = null,
    };

    pub const Run = struct {
        module: ?[]const u8 = null,
        namespace: ?[]const u8 = null,
    };

    pub const Deployment = struct {
        node_id: ?[]const u8 = null,
        ws_port: ?u16 = null,
        http_port: ?u16 = null,
        discovery_port: ?u16 = null,
    };

    pub const Storage = struct {
        path: ?[]const u8 = null,
        durability: ?[]const u8 = null,
    };

    pub const Observability = struct {
        enabled: ?bool = null,
        service_name: ?[]const u8 = null,
        otlp_endpoint: ?[]const u8 = null,
    };
};

pub const Parser = toml.Parser(Config);
pub const Parsed = toml.Parsed(Config);

pub fn init(allocator: std.mem.Allocator) Parser {
    return Parser.init(allocator);
}

pub fn parseFile(parser: *Parser, io: std.Io, path: []const u8) !Parsed {
    return parser.parseFile(io, path);
}

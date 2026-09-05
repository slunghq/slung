const std = @import("std");

const toml = @import("toml");
const http = @import("dusty");
const zio = @import("zio");

const config = @import("config.zig");
const deployment = @import("deployment.zig");
const InstanceConfig = @import("supervisor.zig").InstanceConfig;
const DeploymentConfig = @import("supervisor.zig").DeploymentConfig;
const Supervisor = @import("supervisor.zig").Supervisor;
const Durability = @import("slung").storage.Storage.Durability;

const Style = struct {
    pub const bold = "\x1b[1m";
    pub const reset = "\x1b[0m";
    pub const accent = "\x1b[38;2;156;172;80m";
};

const VERSION = "0.0.0";

const CommandId = enum {
    init,
    build,
    check,
    dev,
    run,
    deploy,
    instance,
    instance_list,
    instance_start,
    instance_stop,
    instance_restart,
    instance_status,
    graph,
    graph_show,
    graph_trace,
    graph_cycles,
    graph_diff,
    trace,
    trace_show,
    trace_replay,
    source,
    source_list,
    source_send,
    storage,
    storage_status,
    storage_verify,
    storage_replay,
    auth,
    auth_login,
    auth_logout,
    auth_list,
    auth_status,
};

const Flag = struct {
    name: []const u8,
    description: []const u8,
    aliases: []const []const u8,
    takes_value: bool = false,
};

const Command = struct {
    id: CommandId,
    name: []const u8,
    description: []const u8,
    commands: []const Command = &.{},
    flags: []const Flag = &.{},
};

const ParsedFlag = struct {
    flag: *const Flag,
    value: ?[]const u8,
};

const ParsedCommand = struct {
    allocator: std.mem.Allocator,
    command: *const Command,
    flags: std.ArrayListUnmanaged(ParsedFlag) = .empty,
    positionals: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *ParsedCommand) void {
        self.flags.deinit(self.allocator);
        self.positionals.deinit(self.allocator);
    }

    fn value(self: *const ParsedCommand, alias: []const u8) ?[]const u8 {
        for (self.flags.items) |parsed| {
            for (parsed.flag.aliases) |candidate| {
                if (std.mem.eql(u8, candidate, alias)) return parsed.value;
            }
        }
        return null;
    }
};

const DeployResponse = struct {
    status: []const u8,
};

const ModuleOptions = struct {
    module_path: []const u8,
    namespace: []const u8 = "default",
    node_id: []const u8 = "node-1",
    ws_port: u16 = 2073,
    http_port: u16 = 2074,
    storage_path: []const u8 = "slung.db",
    durability: Durability = .eventual,

    fn fromParsed(parsed: *const ParsedCommand, file: *const config.Config) ?ModuleOptions {
        const run_config = file.run;
        const deployment_config = file.deployment;
        const module_path = parsed.value("--module") orelse run_config.module orelse return null;

        return .{
            .module_path = module_path,
            .namespace = parsed.value("--namespace") orelse run_config.namespace orelse "default",
            .node_id = parsed.value("--node-id") orelse deployment_config.node_id orelse "node-1",
            .ws_port = parsePort(parsed, "--ws-port", deployment_config.ws_port orelse 2073),
            .http_port = parsePort(parsed, "--http-port", deployment_config.http_port orelse 2074),
            .storage_path = file.storage.path orelse "slung.db",
            .durability = parseDurability(file.storage.durability),
        };
    }

    fn instanceConfig(self: ModuleOptions) InstanceConfig {
        return .{
            .module_path = self.module_path,
            .namespace = self.namespace,
            .node_id = self.node_id,
            .ws_port = self.ws_port,
            .http_port = self.http_port,
            .storage_path = self.storage_path,
            .durability = self.durability,
        };
    }
};

pub fn run(init: std.process.Init) void {
    runInner(init) catch |err| {
        printError(err);
        std.process.exit(exitCode(err));
    };
}

fn runInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tokens.deinit(allocator);
    while (args.next()) |arg| try tokens.append(allocator, arg);

    const root = Command{
        .id = .init,
        .name = "",
        .description = "slung is a CLI that helps you manage, debug, and deploy Slung modules.",
        .commands = &topLevelCommands,
        .flags = &globalFlags,
    };

    if (tokens.items.len == 0) {
        usage(root);
        return;
    }

    for (tokens.items) |token| {
        if (std.mem.eql(u8, token, "--version") or std.mem.eql(u8, token, "-v")) {
            std.debug.print("slung {s}{s}{s}\n", .{ Style.accent, VERSION, Style.reset });
            return;
        }
    }

    var parsed = try parseCommand(allocator, &root, tokens.items);
    defer parsed.deinit();

    const config_path = parsed.value("--config") orelse "slung.toml";
    var config_parser = config.init(allocator);
    defer config_parser.deinit();
    var config_value = config.Config{};
    var config_result: ?config.Parsed = null;
    config_result = config.parseFile(&config_parser, init.io, config_path) catch |err| if (err == error.FileNotFound and parsed.value("--config") == null) null else return err;
    defer if (config_result) |*result| result.deinit();
    if (config_result) |result| config_value = result.value;

    switch (parsed.command.id) {
        .dev => try cmdDev(allocator, runtime.io(), &parsed, &config_value),
        .run => try cmdRun(allocator, runtime.io(), &parsed, &config_value),
        .deploy => try cmdDeploy(allocator, init.io, &parsed, &config_value),
        .init => cmdInit(&parsed),
        .build => cmdBuild(&parsed),
        .check => cmdCheck(&parsed),
        .instance, .instance_list, .instance_start, .instance_stop, .instance_restart, .instance_status => cmdInstance(&parsed),
        .graph, .graph_show, .graph_trace, .graph_cycles, .graph_diff => cmdGraph(&parsed),
        .trace, .trace_show, .trace_replay => cmdTrace(&parsed),
        .source, .source_list, .source_send => cmdSource(&parsed),
        .storage, .storage_status, .storage_verify, .storage_replay => cmdStorage(&parsed),
        .auth, .auth_login, .auth_logout, .auth_list, .auth_status => cmdAuth(&parsed),
    }
}

fn parseCommand(
    allocator: std.mem.Allocator,
    root: *const Command,
    tokens: []const []const u8,
) !ParsedCommand {
    var command = root;
    var index: usize = 0;

    while (index < tokens.len) {
        const token = tokens[index];
        if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h")) {
            usage(command.*);
            std.process.exit(0);
        }
        if (findFlag(&globalFlags, token)) |global_flag| {
            index += 1;
            if (global_flag.takes_value and index < tokens.len) index += 1;
            continue;
        }
        const child = findCommand(command.commands, token) orelse break;
        command = child;
        index += 1;
    }

    var parsed = ParsedCommand{
        .allocator = allocator,
        .command = command,
    };
    errdefer parsed.deinit();

    var prefix_index: usize = 0;
    while (prefix_index < index) {
        const token = tokens[prefix_index];
        if (findFlag(&globalFlags, token)) |global_flag| {
            var value: ?[]const u8 = null;
            prefix_index += 1;
            if (global_flag.takes_value and prefix_index < index) {
                value = tokens[prefix_index];
            }
            try parsed.flags.append(allocator, .{ .flag = global_flag, .value = value });
        }
        prefix_index += 1;
    }

    while (index < tokens.len) {
        const token = tokens[index];
        if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h")) {
            usage(command.*);
            std.process.exit(0);
        }

        if (token.len > 0 and token[0] == '-') {
            const flag = findFlag(command.flags, token) orelse findFlag(&globalFlags, token) orelse {
                usage(command.*);
                std.debug.print("\n", .{});
                printErrorMessageFmt("Unknown flag: {s}", .{token});
                std.process.exit(2);
            };

            var value: ?[]const u8 = null;
            if (flag.takes_value) {
                index += 1;
                if (index >= tokens.len) {
                    printErrorMessageFmt("Missing value for {s}", .{token});
                    std.process.exit(2);
                }
                value = tokens[index];
            }
            try parsed.flags.append(allocator, .{ .flag = flag, .value = value });
        } else {
            try parsed.positionals.append(allocator, token);
        }
        index += 1;
    }

    return parsed;
}

fn parseDurability(value: ?[]const u8) Durability {
    const name = value orelse return .eventual;
    if (std.mem.eql(u8, name, "eventual")) return .eventual;
    if (std.mem.eql(u8, name, "strict")) return .strict;
    printErrorMessageFmt("Invalid storage durability: {s} (expected eventual or strict)", .{name});
    std.process.exit(2);
}

fn parsePort(parsed: *const ParsedCommand, alias: []const u8, default: u16) u16 {
    const value = parsed.value(alias) orelse return default;
    return std.fmt.parseInt(u16, value, 10) catch {
        printErrorMessageFmt("Invalid value for {s}: {s}", .{ alias, value });
        std.process.exit(2);
    };
}

fn cmdDev(allocator: std.mem.Allocator, io: std.Io, parsed: *const ParsedCommand, file: *const config.Config) !void {
    const options = ModuleOptions.fromParsed(parsed, file) orelse {
        usage(parsed.command.*);
        std.debug.print("\n", .{});
        printErrorMessage("Missing value for --module");
        std.process.exit(2);
    };
    var supervisor = Supervisor.init(allocator, io);
    try supervisor.runDev(options.instanceConfig());
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, parsed: *const ParsedCommand, file: *const config.Config) !void {
    const deployment_config = file.deployment;
    const node_id = parsed.value("--node-id") orelse deployment_config.node_id orelse "node-1";
    const discovery_port = parsePort(parsed, "--discovery-port", deployment_config.discovery_port orelse 2072);
    const ws_port = parsePort(parsed, "--ws-port", deployment_config.ws_port orelse 2073);
    const http_port = parsePort(parsed, "--http-port", deployment_config.http_port orelse 2074);

    var supervisor = Supervisor.init(allocator, io);
    try supervisor.run(DeploymentConfig{
        .node_id = node_id,
        .discovery_port = discovery_port,
        .ws_port = ws_port,
        .http_port = http_port,
        .storage_path = file.storage.path orelse "slung.db",
        .durability = parseDurability(file.storage.durability),
    });
}

fn cmdDeploy(allocator: std.mem.Allocator, io: std.Io, parsed: *const ParsedCommand, file: *const config.Config) !void {
    const module_path = parsed.value("--module") orelse file.run.module orelse {
        usage(parsed.command.*);
        std.debug.print("\n", .{});
        printErrorMessage("Missing value for --module");
        std.process.exit(2);
    };
    const namespace = parsed.value("--namespace") orelse file.run.namespace orelse "default";
    const target = parsed.value("--target") orelse "local";
    const endpoint = try deploymentEndpoint(allocator, target);
    defer allocator.free(endpoint);

    const wasm = try readFile(allocator, io, module_path);
    defer allocator.free(wasm);

    const config_path = parsed.value("--config") orelse "slung.toml";
    const config_bytes = readFile(allocator, io, config_path) catch |err| if (err == error.FileNotFound and parsed.value("--config") == null) &[_]u8{} else return err;
    defer if (config_bytes.len > 0) allocator.free(config_bytes);

    const module_name = std.fs.path.basename(module_path);
    const body = try deployment.writeEnvelope(allocator, namespace, module_name, config_bytes, wasm);
    defer allocator.free(body);

    var client = http.Client.init(allocator, io, .{});
    defer client.deinit();
    var response = try client.fetch(endpoint, .{ .method = .post, .body = body });
    defer response.deinit();

    if (@intFromEnum(response.status()) < 200 or @intFromEnum(response.status()) >= 300) {
        printErrorMessageFmt("Deployment failed with HTTP status {d}", .{@intFromEnum(response.status())});
        std.process.exit(1);
    }

    if (response.body() catch null) |message| {
        const parsed_response = std.json.parseFromSlice(DeployResponse, allocator, message, .{}) catch {
            printErrorMessage("Invalid deployment response");
            std.process.exit(1);
        };
        defer parsed_response.deinit();

        if (std.mem.eql(u8, parsed_response.value.status, "first deployment")) {
            std.debug.print("First deployment: {s}\n", .{module_name});
        } else if (std.mem.eql(u8, parsed_response.value.status, "redeployment")) {
            std.debug.print("Redeployment: {s}\n", .{module_name});
        } else {
            std.debug.print("Deployment: {s}\n", .{parsed_response.value.status});
        }
    } else {
        std.debug.print("Deployed {s} to {s}\n", .{ module_name, target });
    }
}

fn deploymentEndpoint(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    if (std.mem.eql(u8, target, "local")) return allocator.dupe(u8, "http://127.0.0.1:2072/deploy");
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        return std.fmt.allocPrint(allocator, "{s}/deploy", .{std.mem.trim(u8, target, "/")});
    }
    return std.fmt.allocPrint(allocator, "http://{s}/deploy", .{target});
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);

    var reader = file.reader(io, &[_]u8{});
    try reader.interface.readSliceAll(data);
    return data;
}

fn cmdAuth(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdInit(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdBuild(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdCheck(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdInstance(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdGraph(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdTrace(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdSource(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn cmdStorage(parsed: *const ParsedCommand) noreturn {
    commandNotImplemented(parsed.command);
}

fn commandNotImplemented(command: *const Command) noreturn {
    usage(command.*);
    std.debug.print("\n", .{});
    printErrorMessageFmt("Command {s} is not implemented in this runtime yet", .{command.name});
    std.process.exit(3);
}

fn printError(err: anyerror) void {
    printErrorMessage(@errorName(err));
}

fn printErrorMessage(message: []const u8) void {
    std.debug.print("{s}error:{s} {s}\n", .{ Style.bold, Style.reset, message });
}

fn printErrorMessageFmt(comptime format: []const u8, args: anytype) void {
    std.debug.print("{s}error:{s} ", .{ Style.bold, Style.reset });
    std.debug.print(format ++ "\n", args);
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.CommandNotImplemented => 3,
        else => 1,
    };
}

fn usage(command: Command) void {
    std.debug.print("{s}\n\n", .{command.description});

    if (command.commands.len > 0) {
        var width: usize = 0;
        for (command.commands) |subcommand| width = @max(width, subcommand.name.len);

        std.debug.print("{s}COMMANDS{s}\n", .{ Style.bold, Style.reset });
        for (command.commands) |subcommand| {
            printRow(subcommand.name, subcommand.description, width);
        }
        std.debug.print("\n", .{});
    }

    if (command.flags.len > 0 and command.name.len > 0) {
        printFlags("FLAGS", command.flags);
        std.debug.print("\n", .{});
    }

    printFlags("GLOBAL FLAGS", &globalFlags);
}

fn printFlags(heading: []const u8, flags: []const Flag) void {
    var width: usize = 0;
    for (flags) |flag| width = @max(width, flagDisplayWidth(flag));

    std.debug.print("{s}{s}{s}\n", .{ Style.bold, heading, Style.reset });
    for (flags) |flag| printFlagRow(flag, width);
}

fn printRow(name: []const u8, description: []const u8, width: usize) void {
    std.debug.print("  {s}{s}{s}", .{ Style.bold, name, Style.reset });
    for (0..width - name.len) |_| std.debug.print(" ", .{});
    std.debug.print("  {s}\n", .{description});
}

fn printFlagRow(flag: Flag, width: usize) void {
    const input_start = std.mem.indexOfScalar(u8, flag.name, ' ');
    const input = if (input_start) |index| flag.name[index..] else "";

    std.debug.print("  {s}", .{Style.bold});
    for (flag.aliases, 0..) |alias, index| {
        if (index > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{alias});
    }
    std.debug.print("{s}", .{Style.reset});
    if (input.len > 0) std.debug.print(" {s}", .{input[1..]});

    const rendered_width = flagDisplayWidth(flag);
    for (0..width - rendered_width) |_| std.debug.print(" ", .{});
    std.debug.print("  {s}\n", .{flag.description});
}

fn flagDisplayWidth(flag: Flag) usize {
    var width: usize = 0;
    for (flag.aliases, 0..) |alias, index| {
        if (index > 0) width += 2;
        width += alias.len;
    }

    if (std.mem.indexOfScalar(u8, flag.name, ' ')) |input_start| {
        width += flag.name.len - input_start;
    }
    return width;
}

fn findCommand(commands: []const Command, name: []const u8) ?*const Command {
    for (commands) |*command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

fn findFlag(flags: []const Flag, alias: []const u8) ?*const Flag {
    for (flags) |*flag| {
        for (flag.aliases) |candidate| {
            if (std.mem.eql(u8, candidate, alias)) return flag;
        }
    }
    return null;
}

const globalFlags = [_]Flag{
    .{ .name = "--config <file>", .aliases = &.{ "--config", "-c" }, .description = "Path to the configuration file", .takes_value = true },
    .{ .name = "--target <target>", .aliases = &.{ "--target", "-t" }, .description = "Slung deployment or local target", .takes_value = true },
    .{ .name = "--help", .aliases = &.{ "--help", "-h" }, .description = "Show help" },
    .{ .name = "--version", .aliases = &.{ "--version", "-v" }, .description = "Show version number" },
};

const initFlags = [_]Flag{
    .{ .name = "--language <language>", .aliases = &.{ "--language", "-l" }, .description = "Language for the new project", .takes_value = true },
    .{ .name = "--path <directory>", .aliases = &.{ "--path", "-p" }, .description = "Directory for the new project", .takes_value = true },
};

const buildFlags = [_]Flag{
    .{ .name = "--module <path>", .aliases = &.{ "--module", "-m" }, .description = "Module source or project path", .takes_value = true },
    .{ .name = "--target <target>", .aliases = &.{ "--target", "-t" }, .description = "Wasm target", .takes_value = true },
    .{ .name = "--release", .aliases = &.{"--release"}, .description = "Build an optimized release module" },
};

const checkFlags = [_]Flag{
    .{ .name = "--module <path>", .aliases = &.{ "--module", "-m" }, .description = "Module source or Wasm path", .takes_value = true },
    .{ .name = "--target <target>", .aliases = &.{ "--target", "-t" }, .description = "Wasm target", .takes_value = true },
};

const runFlags = [_]Flag{
    .{ .name = "--node-id <id>", .aliases = &.{ "--node-id", "-n" }, .description = "Node identity", .takes_value = true },
    .{ .name = "--discovery-port <port>", .aliases = &.{ "--discovery-port", "-d" }, .description = "Deployment discovery port", .takes_value = true },
    .{ .name = "--ws-port <port>", .aliases = &.{ "--ws-port", "-w" }, .description = "WebSocket gateway port", .takes_value = true },
    .{ .name = "--http-port <port>", .aliases = &.{ "--http-port", "-H" }, .description = "HTTP webhook port", .takes_value = true },
};

const devFlags = [_]Flag{
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to run", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace (default: default)", .takes_value = true },
    .{ .name = "--node-id <id>", .aliases = &.{ "--node-id", "-n" }, .description = "Node identity (default: node-1)", .takes_value = true },
    .{ .name = "--ws-port <port>", .aliases = &.{ "--ws-port", "-w" }, .description = "WebSocket gateway port (default: 2073)", .takes_value = true },
    .{ .name = "--http-port <port>", .aliases = &.{ "--http-port", "-H" }, .description = "HTTP webhook port (default: 2074)", .takes_value = true },
};

const instanceNameFlags = [_]Flag{
    .{ .name = "--instance <name>", .aliases = &.{ "--instance", "-i" }, .description = "Module instance to manage", .takes_value = true },
};

const instanceStartFlags = [_]Flag{
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to run", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace", .takes_value = true },
    .{ .name = "--node-id <id>", .aliases = &.{ "--node-id", "-n" }, .description = "Node identity", .takes_value = true },
    .{ .name = "--ws-port <port>", .aliases = &.{ "--ws-port", "-w" }, .description = "WebSocket gateway port", .takes_value = true },
    .{ .name = "--http-port <port>", .aliases = &.{ "--http-port", "-H" }, .description = "HTTP webhook port", .takes_value = true },
};

const graphModuleFlags = [_]Flag{
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to inspect", .takes_value = true },
    .{ .name = "--format <format>", .aliases = &.{ "--format", "-f" }, .description = "Output format", .takes_value = true },
};

const graphTraceFlags = [_]Flag{
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to inspect", .takes_value = true },
    .{ .name = "--component <component>", .aliases = &.{ "--component", "-C" }, .description = "Component to trace", .takes_value = true },
    .{ .name = "--format <format>", .aliases = &.{ "--format", "-f" }, .description = "Output format", .takes_value = true },
};

const graphDiffFlags = [_]Flag{
    .{ .name = "--left <path.wasm>", .aliases = &.{ "--left", "-l" }, .description = "First module version", .takes_value = true },
    .{ .name = "--right <path.wasm>", .aliases = &.{ "--right", "-r" }, .description = "Second module version", .takes_value = true },
    .{ .name = "--format <format>", .aliases = &.{ "--format", "-f" }, .description = "Output format", .takes_value = true },
};

const traceShowFlags = [_]Flag{
    .{ .name = "--fact <fact>", .aliases = &.{ "--fact", "-f" }, .description = "Fact whose causal chain to show", .takes_value = true },
};

const traceReplayFlags = [_]Flag{
    .{ .name = "--seed <seed>", .aliases = &.{ "--seed", "-s" }, .description = "Seed to replay", .takes_value = true },
};

const sourceSendFlags = [_]Flag{
    .{ .name = "--source <source>", .aliases = &.{ "--source", "-s" }, .description = "Source to send the event to", .takes_value = true },
    .{ .name = "--payload <file>", .aliases = &.{ "--payload", "-p" }, .description = "Payload file to send", .takes_value = true },
};

const storageFlags = [_]Flag{
    .{ .name = "--path <file>", .aliases = &.{ "--path", "-p" }, .description = "SQLite storage database path", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace", .takes_value = true },
};

const deployFlags = [_]Flag{
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to deploy", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace", .takes_value = true },
};

const authNameFlags = [_]Flag{
    .{ .name = "--name <name>", .aliases = &.{ "--name", "-n" }, .description = "Authentication profile name", .takes_value = true },
    .{ .name = "--endpoint <url>", .aliases = &.{ "--endpoint", "-e" }, .description = "Remote deployment endpoint", .takes_value = true },
};

const authCommands = [_]Command{
    .{ .id = .auth_login, .name = "login", .description = "save authentication data for a remote deployment.", .flags = &authNameFlags },
    .{ .id = .auth_logout, .name = "logout", .description = "remove authentication data for a remote deployment.", .flags = &authNameFlags },
    .{ .id = .auth_list, .name = "list", .description = "list saved authentication profiles." },
    .{ .id = .auth_status, .name = "status", .description = "show authentication status for a remote deployment.", .flags = &authNameFlags },
};

const storageReplayFlags = [_]Flag{
    .{ .name = "--path <file>", .aliases = &.{ "--path", "-p" }, .description = "SQLite storage database path", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace", .takes_value = true },
    .{ .name = "--from <id>", .aliases = &.{"--from"}, .description = "Mutation or dirty entry to start from", .takes_value = true },
};

const instanceCommands = [_]Command{
    .{ .id = .instance_list, .name = "list", .description = "list running module instances.", .flags = &instanceNameFlags },
    .{ .id = .instance_start, .name = "start", .description = "start a module instance.", .flags = &instanceStartFlags },
    .{ .id = .instance_stop, .name = "stop", .description = "stop a module instance.", .flags = &instanceNameFlags },
    .{ .id = .instance_restart, .name = "restart", .description = "restart a module instance.", .flags = &instanceNameFlags },
    .{ .id = .instance_status, .name = "status", .description = "show the status of a module instance.", .flags = &instanceNameFlags },
};

const graphCommands = [_]Command{
    .{ .id = .graph_show, .name = "show", .description = "show the full static capability graph.", .flags = &graphModuleFlags },
    .{ .id = .graph_trace, .name = "trace", .description = "track the static capability graph of a specific component.", .flags = &graphTraceFlags },
    .{ .id = .graph_cycles, .name = "cycles", .description = "detect and report cyclic dependencies in the static capability graph.", .flags = &graphModuleFlags },
    .{ .id = .graph_diff, .name = "diff", .description = "compare the capability graph of two module versions.", .flags = &graphDiffFlags },
};

const traceCommands = [_]Command{
    .{ .id = .trace_show, .name = "show", .description = "show the causal chain of an event.", .flags = &traceShowFlags },
    .{ .id = .trace_replay, .name = "replay", .description = "replay a trace using a given seed.", .flags = &traceReplayFlags },
};

const sourceCommands = [_]Command{
    .{ .id = .source_list, .name = "list", .description = "show configured sources and their mapping function." },
    .{ .id = .source_send, .name = "send", .description = "fire a synthetic event to a given source.", .flags = &sourceSendFlags },
};

const storageCommands = [_]Command{
    .{ .id = .storage_status, .name = "status", .description = "show storage status.", .flags = &storageFlags },
    .{ .id = .storage_verify, .name = "verify", .description = "verify the storage database and WAL.", .flags = &storageFlags },
    .{ .id = .storage_replay, .name = "replay", .description = "replay durable storage records.", .flags = &storageReplayFlags },
};

const topLevelCommands = [_]Command{
    .{ .id = .init, .name = "init", .description = "scaffold a new project in your preferred language.", .flags = &initFlags },
    .{ .id = .build, .name = "build", .description = "compile module source to Wasm.", .flags = &buildFlags },
    .{ .id = .check, .name = "check", .description = "check the module against the host interface.", .flags = &checkFlags },
    .{ .id = .dev, .name = "dev", .description = "run a module in development mode.", .flags = &devFlags },
    .{ .id = .run, .name = "run", .description = "run a module using a deployment configuration.", .flags = &runFlags },
    .{ .id = .deploy, .name = "deploy", .description = "deploy a module to an existing Slung deployment.", .flags = &deployFlags },
    .{ .id = .instance, .name = "instance", .description = "manage Slung module instances.", .commands = &instanceCommands },
    .{ .id = .graph, .name = "graph", .description = "inspect the static capability graph of a module as JSON.", .commands = &graphCommands },
    .{ .id = .trace, .name = "trace", .description = "debug the causal chain of an event.", .commands = &traceCommands },
    .{ .id = .source, .name = "source", .description = "inspect and send events to configured sources.", .commands = &sourceCommands },
    .{ .id = .storage, .name = "storage", .description = "inspect and manage durable Slung storage.", .commands = &storageCommands },
    .{ .id = .auth, .name = "auth", .description = "manage authentication for remote Slung deployments.", .commands = &authCommands },
};

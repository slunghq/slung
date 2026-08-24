const std = @import("std");
const zio = @import("zio");

const Supervisor = @import("supervisor.zig").Supervisor;
const InstanceConfig = @import("supervisor.zig").InstanceConfig;

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
    run,
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

const RunOptions = struct {
    module_path: []const u8,
    namespace: []const u8 = "default",
    node_id: []const u8 = "node-1",
    ws_port: u16 = 2073,
    http_port: u16 = 2074,

    fn fromParsed(parsed: *const ParsedCommand) RunOptions {
        return .{
            .module_path = parsed.value("--module").?,
            .namespace = parsed.value("--namespace") orelse "default",
            .node_id = parsed.value("--node-id") orelse "node-1",
            .ws_port = parsePort(parsed, "--ws-port", 2073),
            .http_port = parsePort(parsed, "--http-port", 2074),
        };
    }

    fn instanceConfig(self: RunOptions) InstanceConfig {
        return .{
            .module_path = self.module_path,
            .namespace = self.namespace,
            .node_id = self.node_id,
            .ws_port = self.ws_port,
            .http_port = self.http_port,
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

    switch (parsed.command.id) {
        .run => try cmdRun(allocator, runtime.io(), &parsed),
        .init => cmdInit(&parsed),
        .build => cmdBuild(&parsed),
        .check => cmdCheck(&parsed),
        .instance, .instance_list, .instance_start, .instance_stop, .instance_restart, .instance_status => cmdInstance(&parsed),
        .graph, .graph_show, .graph_trace, .graph_cycles, .graph_diff => cmdGraph(&parsed),
        .trace, .trace_show, .trace_replay => cmdTrace(&parsed),
        .source, .source_list, .source_send => cmdSource(&parsed),
        .storage, .storage_status, .storage_verify, .storage_replay => cmdStorage(&parsed),
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
        const child = findCommand(command.commands, token) orelse break;
        command = child;
        index += 1;
    }

    var parsed = ParsedCommand{
        .allocator = allocator,
        .command = command,
    };
    errdefer parsed.deinit();

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
                printErrorMessageFmt("unknown flag: {s}", .{token});
                std.process.exit(2);
            };

            var value: ?[]const u8 = null;
            if (flag.takes_value) {
                index += 1;
                if (index >= tokens.len) {
                    printErrorMessageFmt("missing value for {s}", .{token});
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

    if (command.id == .run and parsed.value("--module") == null) {
        usage(command.*);
        std.debug.print("\n", .{});
        printErrorMessage("missing value for --module");
        std.process.exit(2);
    }

    return parsed;
}

fn parsePort(parsed: *const ParsedCommand, alias: []const u8, default: u16) u16 {
    const value = parsed.value(alias) orelse return default;
    return std.fmt.parseInt(u16, value, 10) catch {
        printErrorMessageFmt("invalid value for {s}: {s}", .{ alias, value });
        std.process.exit(2);
    };
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, parsed: *const ParsedCommand) !void {
    const options = RunOptions.fromParsed(parsed);
    var supervisor = Supervisor.init(allocator, io);
    try supervisor.run(options.instanceConfig());
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
    printErrorMessageFmt("{s} is not implemented in this runtime yet", .{command.name});
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
    .{ .name = "--config <file>", .aliases = &.{ "--config", "-c" }, .description = "Path to the runtime configuration file", .takes_value = true },
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
    .{ .name = "--module <path.wasm>", .aliases = &.{ "--module", "-m" }, .description = "Module to run", .takes_value = true },
    .{ .name = "--namespace <name>", .aliases = &.{ "--namespace", "-N" }, .description = "Isolation namespace (default: default)", .takes_value = true },
    .{ .name = "--node-id <id>", .aliases = &.{ "--node-id", "-n" }, .description = "Node identity (default: node-1)", .takes_value = true },
    .{ .name = "--ws-port <port>", .aliases = &.{ "--ws-port", "-w" }, .description = "WebSocket gateway port (default: 2073)", .takes_value = true },
    .{ .name = "--http-port <port>", .aliases = &.{ "--http-port", "-H" }, .description = "HTTP webhook port (default: 2074)", .takes_value = true },
};

const sourceSendFlags = [_]Flag{
    .{ .name = "--source <source>", .aliases = &.{"--source"}, .description = "Source to send the event to.", .takes_value = true },
    .{ .name = "--payload <file>", .aliases = &.{"--payload"}, .description = "Payload file to send.", .takes_value = true },
};

const instanceCommands = [_]Command{
    .{ .id = .instance_list, .name = "list", .description = "list running module instances." },
    .{ .id = .instance_start, .name = "start", .description = "start a module instance." },
    .{ .id = .instance_stop, .name = "stop", .description = "stop a module instance." },
    .{ .id = .instance_restart, .name = "restart", .description = "restart a module instance." },
    .{ .id = .instance_status, .name = "status", .description = "show the status of a module instance." },
};

const graphCommands = [_]Command{
    .{ .id = .graph_show, .name = "show", .description = "show the full static capability graph." },
    .{ .id = .graph_trace, .name = "trace", .description = "track the static capability graph of a specific component." },
    .{ .id = .graph_cycles, .name = "cycles", .description = "detect and report cyclic dependencies in the static capability graph." },
    .{ .id = .graph_diff, .name = "diff", .description = "compare the capability graph of two module versions." },
};

const traceCommands = [_]Command{
    .{ .id = .trace_show, .name = "show", .description = "show the causal chain of an event." },
    .{ .id = .trace_replay, .name = "replay", .description = "replay a trace using a given seed." },
};

const sourceCommands = [_]Command{
    .{ .id = .source_list, .name = "list", .description = "show configured sources and their mapping function." },
    .{ .id = .source_send, .name = "send", .description = "fire a synthetic event to a given source.", .flags = &sourceSendFlags },
};

const storageCommands = [_]Command{
    .{ .id = .storage_status, .name = "status", .description = "show storage status." },
    .{ .id = .storage_verify, .name = "verify", .description = "verify the storage database and WAL." },
    .{ .id = .storage_replay, .name = "replay", .description = "replay durable storage records." },
};

const topLevelCommands = [_]Command{
    .{ .id = .init, .name = "init", .description = "scaffold a new project in your preferred language.", .flags = &initFlags },
    .{ .id = .build, .name = "build", .description = "compile module source to Wasm.", .flags = &buildFlags },
    .{ .id = .check, .name = "check", .description = "check the module against the host interface.", .flags = &checkFlags },
    .{ .id = .run, .name = "run", .description = "run a module in development mode.", .flags = &runFlags },
    .{ .id = .instance, .name = "instance", .description = "manage Slung module instances.", .commands = &instanceCommands },
    .{ .id = .graph, .name = "graph", .description = "inspect the static capability graph of a module as JSON.", .commands = &graphCommands },
    .{ .id = .trace, .name = "trace", .description = "debug the causal chain of an event.", .commands = &traceCommands },
    .{ .id = .source, .name = "source", .description = "inspect and send events to configured sources.", .commands = &sourceCommands },
    .{ .id = .storage, .name = "storage", .description = "inspect and manage durable Slung storage.", .commands = &storageCommands },
};

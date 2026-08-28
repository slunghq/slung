const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const cli = @import("cli.zig");

pub const std_options = std.Options{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (builtin.mode != .Debug and scope != .slung) return;
    customLogFn(level, scope, format, args);
}

fn scopeColor(comptime name: []const u8) []const u8 {
    const palette = [_][]const u8{
        "\x1b[38;2;156;172;80m",
        "\x1b[38;2;80;156;172m",
        "\x1b[38;2;172;120;80m",
        "\x1b[38;2;140;80;172m",
        "\x1b[38;2;172;80;100m",
        "\x1b[38;2;80;140;172m",
    };
    comptime var hash: usize = 0;
    inline for (name) |c| hash = hash *% 31 +% c;
    return palette[hash % palette.len];
}

// Log capture for suppressing logs in passing tests.
// The Io is stashed at startup so the global log callback can perform mutex
// operations without having to thread `Io` through every call site.
const LogCapture = struct {
    capture_writer: ?*std.Io.Writer = null,
    mutex: Io.Mutex = .init,
    io: ?Io = null,

    pub fn logFn(
        self: *@This(),
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (builtin.mode != .Debug and scope != .slung) return;

        const reset = "\x1b[0m";
        const level_str = comptime switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERR",
        };
        const level_color = comptime switch (level) {
            .debug => "\x1b[2m",
            .info => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
        const scope_color = comptime if (scope == .slung) scopeColor(@tagName(scope)) else "\x1b[90m";

        const io = self.io orelse {
            const scope_prefix = comptime scope_color ++ @tagName(scope) ++ reset ++ " " ++ level_color ++ level_str ++ reset ++ " ";
            std.debug.print(scope_prefix ++ format ++ "\n", args);
            return;
        };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(std.Io.Clock.real.now(io).toSeconds()) };

        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();

        const scope_part = comptime if (builtin.mode == .Debug)
            scope_color ++ @tagName(scope) ++ reset ++ " "
        else
            "";

        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} " ++ scope_part ++ "{s}{s}{s} ", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            level_color,
            level_str,
            reset,
        }) catch unreachable;

        if (self.capture_writer) |writer| {
            // Write to capture buffer
            writer.writeAll(prefix) catch return;
            writer.print(format ++ "\n", args) catch return;
        } else {
            // Write to stderr (std.debug.print handles its own locking)
            std.debug.print("{s}", .{prefix});
            std.debug.print(format ++ "\n", args);
        }
    }

    pub fn startCapture(self: *@This(), io: Io, writer: *std.Io.Writer) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = writer;
    }

    pub fn stopCapture(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = null;
    }
};

var log_capture = LogCapture{};

pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_capture.logFn(level, scope, format, args);
}

pub fn main(init: std.process.Init) void {
    log_capture.io = init.io;
    defer log_capture.io = null;
    cli.run(init);
}

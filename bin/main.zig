const std = @import("std");
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
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) void {
    cli.run(init);
}

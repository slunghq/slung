//! Shared benchmark utilities

const std = @import("std");
const builtin = @import("builtin");

pub fn getResidentMemory() !u64 {
    if (builtin.os.tag == .linux) {
        const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = try file.read(&buf);
        var it = std.mem.splitScalar(u8, buf[0..n], ' ');
        _ = it.next();
        const pages_str = it.next() orelse return error.ParseError;
        return try std.fmt.parseInt(u64, pages_str, 10) * 4096;
    } else if (builtin.os.tag == .macos) {
        var info: std.c.task_basic_info = undefined;
        var count = std.c.TASK_BASIC_INFO_COUNT;
        _ = std.c.task_info(std.c.mach_task_self(), std.c.TASK_BASIC_INFO, @ptrCast(&info), &count);
        return info.resident_size;
    } else if (builtin.os.tag == .windows) {
        var info: std.os.windows.PROCESS_MEMORY_COUNTERS = undefined;
        if (std.os.windows.kernel32.GetProcessMemoryInfo(std.os.windows.kernel32.GetCurrentProcess(), &info, @sizeOf(std.os.windows.PROCESS_MEMORY_COUNTERS)) != 0) {
            return info.WorkingSetSize;
        }
        return error.UnsupportedOS;
    } else {
        return error.UnsupportedOS;
    }
}

pub fn randomSeed() u64 {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return seed;
}

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
        var count: std.c.mach_msg_type_number_t = std.c.TASK_BASIC_INFO_COUNT;
        const result = std.c.task_info(
            std.c.mach_task_self(),
            std.c.TASK_BASIC_INFO,
            @ptrCast(&info),
            &count,
        );
        if (result != std.c.KERN_SUCCESS) return error.TaskInfoFailed;
        return info.resident_size;
    } else if (builtin.os.tag == .windows) {
        var info: std.os.windows.PROCESS_MEMORY_COUNTERS = undefined;
        if (std.os.windows.GetProcessMemoryInfo(
            std.os.windows.GetCurrentProcess(),
            &info,
            @sizeOf(std.os.windows.PROCESS_MEMORY_COUNTERS),
        ) == 0) {
            return error.GetProcessMemoryInfoFailed;
        }
        return info.WorkingSetSize;
    } else {
        return error.UnsupportedOS;
    }
}

pub fn randomSeed() u64 {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return seed;
}

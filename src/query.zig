//! Query DSL syntax
//! OP:SERIES:[TAGS]:[RANGE]
//! RANGE is optional.
//!
//! OP
//! + AVG
//! + MIN
//! + MAX
//! + SUM
//! + COUNT
//! Note: OP is optional, its absence (via ?) we can get all equal values.
//!
//! TAGS: [tag1 AND tag2] ... example
//! + AND
//! + OR
//! + NOT
//!
//! Examples:
//! AVG:series1:[tag1 AND tag2]:[start_time,end_time]
//! MIN:series2:[tag3 OR tag4]:[start_time,end_time]
//! MAX:series3:[tag5 NOT tag6]:[start_time,end_time]
//! SUM:series4:[tag7]:[start_time,end_time]
//! COUNT:series5:[tag8]:[start_time,end_time]
//! SUM:series6:[tag9]

const std = @import("std");
const PollState = @import("host/host.zig").PollState;

pub const Query = struct {
    const Self = @This();
    const MAX_SERIES = 16;
    const MAX_TAG_TOKENS = 32;

    pub const TagOp = enum {
        and_op,
        or_op,
        not_op,
    };

    pub const TagToken = union(enum) {
        tag: []const u8,
        op: TagOp,
    };

    const Range = struct {
        start: i64,
        end: i64,
    };

    op: PollState,
    series: []const u8,
    tags: [MAX_TAG_TOKENS]TagToken,
    tags_len: usize,
    has_time_range: bool,
    time_start: i64,
    time_end: i64,

    pub fn init(filter: []const u8) !Self {
        var query = Self{
            .op = parseOp(filter),
            .series = "",
            .tags = undefined,
            .tags_len = 0,
            .has_time_range = false,
            .time_start = 0,
            .time_end = 0,
        };

        var iter_parts = std.mem.splitScalar(u8, filter, ':');
        _ = iter_parts.next() orelse return error.InvalidQuery;

        query.series = iter_parts.next() orelse return error.InvalidQuery;

        const tags_part = iter_parts.next() orelse return error.InvalidQuery;
        query.tags_len = try parseTags(tags_part, query.tags[0..]);

        if (iter_parts.next()) |range_part| {
            const range = try parseRange(range_part);
            query.has_time_range = true;
            query.time_start = range.start;
            query.time_end = range.end;

            if (iter_parts.next() != null) {
                return error.InvalidQuery;
            }
        }

        return query;
    }

    fn parseOp(filter: []const u8) PollState {
        if (std.mem.startsWith(u8, filter, "AVG")) {
            return .{ .Avg = .{ .sum = 0, .count = 0 } };
        } else if (std.mem.startsWith(u8, filter, "MIN")) {
            return .{ .Min = std.math.inf(f64) };
        } else if (std.mem.startsWith(u8, filter, "MAX")) {
            return .{ .Max = -std.math.inf(f64) };
        } else if (std.mem.startsWith(u8, filter, "SUM")) {
            return .{ .Sum = 0 };
        } else if (std.mem.startsWith(u8, filter, "COUNT")) {
            return .{ .Count = 0 };
        } else {
            return .{ .Sum = 0 };
        }
    }

    pub fn tagsSlice(self: *const Self) []const TagToken {
        return self.tags[0..self.tags_len];
    }

    pub fn matchesTags(self: *const Self, tags: []const []const u8) bool {
        if (self.tags_len == 0) return true;

        var idx: usize = 0;
        var current = self.consumeOperand(tags, &idx) orelse return false;

        while (idx < self.tags_len) {
            const token = self.tags[idx];
            idx += 1;
            const op = switch (token) {
                .op => |v| v,
                .tag => return false,
            };

            var rhs_negated = false;
            var combine_op = op;
            if (op == .not_op) {
                combine_op = .and_op;
                rhs_negated = true;
            }

            const rhs = self.consumeOperandWithNegation(tags, &idx, rhs_negated) orelse return false;
            current = switch (combine_op) {
                .and_op => current and rhs,
                .or_op => current or rhs,
                .not_op => unreachable,
            };
        }

        return current;
    }

    fn consumeOperand(self: *const Self, tags: []const []const u8, idx: *usize) ?bool {
        return self.consumeOperandWithNegation(tags, idx, false);
    }

    fn consumeOperandWithNegation(self: *const Self, tags: []const []const u8, idx: *usize, initial_negated: bool) ?bool {
        var negated = initial_negated;
        while (idx.* < self.tags_len) {
            switch (self.tags[idx.*]) {
                .op => |op| {
                    if (op == .not_op) {
                        negated = !negated;
                        idx.* += 1;
                        continue;
                    }
                    return null;
                },
                .tag => |tag| {
                    idx.* += 1;
                    const contains = containsTag(tags, tag);
                    return if (negated) !contains else contains;
                },
            }
        }
        return null;
    }

    fn containsTag(tags: []const []const u8, needle: []const u8) bool {
        for (tags) |tag| {
            if (std.mem.eql(u8, tag, needle)) return true;
        }
        return false;
    }

    fn parseTagOp(token: []const u8) ?TagOp {
        if (std.ascii.eqlIgnoreCase(token, "AND")) return .and_op;
        if (std.ascii.eqlIgnoreCase(token, "OR")) return .or_op;
        if (std.ascii.eqlIgnoreCase(token, "NOT")) return .not_op;
        return null;
    }

    fn parseRange(range_part: []const u8) error{ InvalidRange, InvalidCharacter, Overflow }!Range {
        return parseRangeAtNow(range_part, std.time.microTimestamp());
    }

    fn parseRangeAtNow(range_part: []const u8, now_us: i64) error{ InvalidRange, InvalidCharacter, Overflow }!Range {
        var inner = std.mem.trim(u8, range_part, " \t\r\n");
        if (inner.len < 2 or inner[0] != '[' or inner[inner.len - 1] != ']') {
            return error.InvalidRange;
        }

        inner = std.mem.trim(u8, inner[1 .. inner.len - 1], " \t\r\n");
        var parts = std.mem.splitScalar(u8, inner, ',');
        const start_raw = parts.next() orelse return error.InvalidRange;
        const end_raw = parts.next() orelse return error.InvalidRange;
        if (parts.next() != null) return error.InvalidRange;

        const start = try parseTimeSpec(start_raw, now_us);
        const end = try parseTimeSpec(end_raw, now_us);

        const range_start = @min(start, end);
        const range_end = @max(start, end);

        return Range{ .start = range_start, .end = range_end };
    }

    fn parseTimeSpec(raw: []const u8, now_us: i64) error{ InvalidRange, InvalidCharacter, Overflow }!i64 {
        const spec = std.mem.trim(u8, raw, " \t\r\n");
        if (spec.len == 0) return error.InvalidRange;

        if (std.ascii.eqlIgnoreCase(spec, "now")) {
            return now_us;
        }

        if (std.ascii.isDigit(spec[spec.len - 1])) {
            return std.fmt.parseInt(i64, spec, 10) catch |err| switch (err) {
                error.InvalidCharacter => error.InvalidRange,
                error.Overflow => error.Overflow,
            };
        }

        var amount_end: usize = 0;
        while (amount_end < spec.len and std.ascii.isDigit(spec[amount_end])) : (amount_end += 1) {}
        if (amount_end == 0) return error.InvalidRange;

        const amount = std.fmt.parseInt(i64, spec[0..amount_end], 10) catch |err| switch (err) {
            error.InvalidCharacter => return error.InvalidRange,
            error.Overflow => return error.Overflow,
        };
        if (amount < 0) return error.InvalidRange;

        const unit_raw = std.mem.trim(u8, spec[amount_end..], " \t\r\n");
        if (unit_raw.len == 0) return error.InvalidRange;

        const unit_seconds: i64 = if (std.ascii.eqlIgnoreCase(unit_raw, "s") or
            std.ascii.eqlIgnoreCase(unit_raw, "sec") or
            std.ascii.eqlIgnoreCase(unit_raw, "secs") or
            std.ascii.eqlIgnoreCase(unit_raw, "second") or
            std.ascii.eqlIgnoreCase(unit_raw, "seconds"))
            1
        else if (std.ascii.eqlIgnoreCase(unit_raw, "m") or
            std.ascii.eqlIgnoreCase(unit_raw, "min") or
            std.ascii.eqlIgnoreCase(unit_raw, "mins") or
            std.ascii.eqlIgnoreCase(unit_raw, "minute") or
            std.ascii.eqlIgnoreCase(unit_raw, "minutes"))
            60
        else if (std.ascii.eqlIgnoreCase(unit_raw, "h") or
            std.ascii.eqlIgnoreCase(unit_raw, "hr") or
            std.ascii.eqlIgnoreCase(unit_raw, "hrs") or
            std.ascii.eqlIgnoreCase(unit_raw, "hour") or
            std.ascii.eqlIgnoreCase(unit_raw, "hours"))
            60 * 60
        else if (std.ascii.eqlIgnoreCase(unit_raw, "d") or
            std.ascii.eqlIgnoreCase(unit_raw, "day") or
            std.ascii.eqlIgnoreCase(unit_raw, "days"))
            60 * 60 * 24
        else if (std.ascii.eqlIgnoreCase(unit_raw, "w") or
            std.ascii.eqlIgnoreCase(unit_raw, "wk") or
            std.ascii.eqlIgnoreCase(unit_raw, "wks") or
            std.ascii.eqlIgnoreCase(unit_raw, "week") or
            std.ascii.eqlIgnoreCase(unit_raw, "weeks"))
            60 * 60 * 24 * 7
        else
            return error.InvalidRange;

        const duration_seconds = try std.math.mul(i64, amount, unit_seconds);
        const duration_us = try std.math.mul(i64, duration_seconds, 1_000_000);
        return std.math.sub(i64, now_us, duration_us) catch return error.Overflow;
    }

    fn parseTags(tags: []const u8, out: []TagToken) error{ InvalidTags, TooManyTags }!usize {
        var inner = std.mem.trim(u8, tags, " \t\r\n");
        if (inner.len < 2 or inner[0] != '[' or inner[inner.len - 1] != ']') {
            return error.InvalidTags;
        }
        inner = std.mem.trim(u8, inner[1 .. inner.len - 1], " \t\r\n");
        if (inner.len == 0) return 0;

        var iter_tags = std.mem.splitScalar(u8, inner, ' ');
        var expect_tag = true;
        var out_len: usize = 0;

        while (iter_tags.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t\r\n");
            if (token.len == 0) continue;

            if (expect_tag) {
                if (parseTagOp(token)) |op| {
                    if (op != .not_op) return error.InvalidTags;
                    if (out_len >= out.len) return error.TooManyTags;
                    out[out_len] = .{ .op = .not_op };
                    out_len += 1;
                    continue;
                }

                if (out_len >= out.len) return error.TooManyTags;
                out[out_len] = .{ .tag = token };
                out_len += 1;
                expect_tag = false;
            } else {
                const op = parseTagOp(token) orelse return error.InvalidTags;
                if (out_len >= out.len) return error.TooManyTags;
                out[out_len] = .{ .op = op };
                out_len += 1;
                expect_tag = true;
            }
        }

        if (expect_tag) return error.InvalidTags;
        return out_len;
    }
};

test "parseTags parses infix tags" {
    var tokens: [8]Query.TagToken = undefined;
    const len = try Query.parseTags("[site=eu AND env=prod OR region=west]", tokens[0..]);

    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("site=eu", tokens[0].tag);
    try std.testing.expectEqual(Query.TagOp.and_op, tokens[1].op);
    try std.testing.expectEqualStrings("env=prod", tokens[2].tag);
    try std.testing.expectEqual(Query.TagOp.or_op, tokens[3].op);
    try std.testing.expectEqualStrings("region=west", tokens[4].tag);
}

test "parseTags supports unary not" {
    var tokens: [4]Query.TagToken = undefined;
    const len = try Query.parseTags("[NOT muted]", tokens[0..]);

    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(Query.TagOp.not_op, tokens[0].op);
    try std.testing.expectEqualStrings("muted", tokens[1].tag);
}

test "parseTags rejects malformed tags" {
    var tokens: [4]Query.TagToken = undefined;
    try std.testing.expectError(error.InvalidTags, Query.parseTags("[foo AND]", tokens[0..]));
    try std.testing.expectError(error.InvalidTags, Query.parseTags("foo AND bar", tokens[0..]));
}

test "Query.init parses full query" {
    const query = try Query.init("AVG:cpu.total:[region=us-west AND NOT host=test]:[1700000000,1700000100]");

    try std.testing.expectEqualStrings("cpu.total", query.series);
    try std.testing.expectEqual(@as(i64, 1700000000), query.time_start);
    try std.testing.expectEqual(@as(i64, 1700000100), query.time_end);

    switch (query.op) {
        .Avg => |avg| {
            try std.testing.expectEqual(@as(f64, 0), avg.sum);
            try std.testing.expectEqual(@as(u64, 0), avg.count);
        },
        else => return error.TestUnexpectedResult,
    }

    const tags = query.tagsSlice();
    try std.testing.expectEqual(@as(usize, 4), tags.len);
    try std.testing.expectEqualStrings("region=us-west", tags[0].tag);
    try std.testing.expectEqual(Query.TagOp.and_op, tags[1].op);
    try std.testing.expectEqual(Query.TagOp.not_op, tags[2].op);
    try std.testing.expectEqualStrings("host=test", tags[3].tag);
}

test "parseRange supports relative ranges and normalizes order" {
    const now_us: i64 = 1_000_000_000;
    const range = try Query.parseRangeAtNow("[now,1s]", now_us);

    try std.testing.expectEqual(@as(i64, now_us - 1_000_000), range.start);
    try std.testing.expectEqual(now_us, range.end);
}

test "parseRange supports minute/hour/day/week units" {
    const now_us: i64 = 10_000_000_000;

    const minute = try Query.parseRangeAtNow("[2m,now]", now_us);
    try std.testing.expectEqual(now_us - 120 * 1_000_000, minute.start);
    try std.testing.expectEqual(now_us, minute.end);

    const hour = try Query.parseRangeAtNow("[3h,now]", now_us);
    try std.testing.expectEqual(now_us - (3 * 60 * 60 * 1_000_000), hour.start);

    const day = try Query.parseRangeAtNow("[4d,now]", now_us);
    try std.testing.expectEqual(now_us - (4 * 24 * 60 * 60 * 1_000_000), day.start);

    const week = try Query.parseRangeAtNow("[5w,now]", now_us);
    try std.testing.expectEqual(now_us - (5 * 7 * 24 * 60 * 60 * 1_000_000), week.start);
}

test "parseRange supports full unit names" {
    const now_us: i64 = 20_000_000_000;
    const range = try Query.parseRangeAtNow("[1 minute,now]", now_us);
    try std.testing.expectEqual(now_us - 60 * 1_000_000, range.start);
    try std.testing.expectEqual(now_us, range.end);

    const weeks = try Query.parseRangeAtNow("[2weeks,now]", now_us);
    try std.testing.expectEqual(now_us - (2 * 7 * 24 * 60 * 60 * 1_000_000), weeks.start);
}

test "Query.init supports relative range in full query" {
    const before = std.time.microTimestamp();
    const query = try Query.init("SUM:s1:[enabled]:[1m,now]");
    const after = std.time.microTimestamp();

    try std.testing.expect(query.has_time_range);
    try std.testing.expect(query.time_start <= query.time_end);
    try std.testing.expect(query.time_end >= before);
    try std.testing.expect(query.time_end <= after);
}

test "Query.init allows query without range" {
    const query = try Query.init("SUM:s1:[enabled]");

    try std.testing.expectEqualStrings("s1", query.series);
    try std.testing.expectEqual(@as(usize, 1), query.tagsSlice().len);
    try std.testing.expectEqualStrings("enabled", query.tagsSlice()[0].tag);
    try std.testing.expect(!query.has_time_range);
    try std.testing.expectEqual(0, query.time_start);
    try std.testing.expectEqual(0, query.time_end);
}

test "Query.init rejects malformed full query parts" {
    try std.testing.expectError(error.InvalidRange, Query.init("AVG:series1:[x]:1,2"));
    try std.testing.expectError(error.InvalidTags, Query.init("AVG:series1:x:[1,2]"));
    try std.testing.expectError(error.InvalidRange, Query.init("AVG:series1:[x]:[1mo,now]"));
    try std.testing.expectError(error.InvalidQuery, Query.init("AVG:series1:[x]:[1,2]:extra"));
}

test "Query.matchesTags supports infix boolean expressions" {
    const query = try Query.init("SUM:cpu.total:[env=prod AND host=h-9]");
    const tags_ok = [_][]const u8{ "region=eu", "env=prod", "host=h-9" };
    const tags_fail = [_][]const u8{ "env=prod", "host=h-8" };
    try std.testing.expect(query.matchesTags(tags_ok[0..]));
    try std.testing.expect(!query.matchesTags(tags_fail[0..]));
}

test "Query.matchesTags supports OR and unary NOT" {
    const query = try Query.init("SUM:cpu.total:[service=db OR NOT muted]");
    const tags_a = [_][]const u8{"service=db"};
    const tags_b = [_][]const u8{"muted=false"};
    const tags_c = [_][]const u8{"muted"};
    try std.testing.expect(query.matchesTags(tags_a[0..]));
    try std.testing.expect(query.matchesTags(tags_b[0..]));
    try std.testing.expect(!query.matchesTags(tags_c[0..]));
}

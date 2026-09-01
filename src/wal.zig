const std = @import("std");
const types = @import("types.zig");
const Timestamp = @import("primitives/hlc.zig").Timestamp;

pub const FactMutation = struct {
    namespace: []const u8,
    entity: types.EntityId,
    component: types.ComponentId,
    value: []const u8,
    timestamp: Timestamp,
    cause: types.CausalTag,
};

pub const Fact = struct {
    value: []u8,
    timestamp: Timestamp,
    cause: types.CausalTag,

    pub fn deinit(self: Fact, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const PendingDirty = struct {
    id: i64,
    namespace: []u8,
    entity: types.EntityId,
    component: types.ComponentId,

    pub fn deinit(self: PendingDirty, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
    }
};

const Self = @This();

pub const Durability = enum { eventual, strict };

const Request = struct {
    allocator: std.mem.Allocator,
    mutations: std.ArrayList(FactMutation) = .empty,
    accepted: []bool,
    record_kind: u8 = RecordBatch,
    ack_id: i64 = 0,
    done: bool = false,
    err: ?anyerror = null,
    caller_waits: bool = false,

    fn deinit(self: *Request) void {
        for (self.mutations.items) |mutation| {
            self.allocator.free(mutation.namespace);
            self.allocator.free(mutation.value);
            self.allocator.free(mutation.cause.node);
        }
        self.mutations.deinit(self.allocator);
        self.allocator.free(self.accepted);
        self.allocator.destroy(self);
    }
};

const RecordBatch: u8 = 1;
const RecordAck: u8 = 2;
const RecordCascade: u8 = 3;
const HeaderSize = @sizeOf(u32);
const TrailerSize = @sizeOf(u32);

allocator: std.mem.Allocator,
io: std.Io,
file: std.Io.File,
facts: std.StringHashMapUnmanaged(Fact) = .empty,
pending: std.ArrayList(PendingDirty) = .empty,
next_id: i64 = 1,

// The queue is deliberately owned by the WAL. Requests contain copies of
// every slice, so callers never lend memory to the writer thread.
mutex: std.Io.Mutex = .init,
write_mutex: std.Io.Mutex = .init,
requests: std.ArrayList(*Request) = .empty,
worker: ?std.Thread = null,
stopping: bool = false,

pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Self {
    return open(allocator, io, path);
}

pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Self {
    const dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    var wal = Self{ .allocator = allocator, .io = io, .file = file };
    errdefer wal.deinit();
    try wal.recover();
    return wal;
}

/// Starts the single serialized writer after the WAL has reached its final
/// address. Storage calls this after assigning the returned value.
pub fn start(self: *Self) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.worker != null) return;
    self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
}

pub fn deinit(self: *Self) void {
    if (self.worker) |thread| {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        thread.join();
        self.worker = null;
    }
    var it = self.facts.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.value);
    }
    self.facts.deinit(self.allocator);
    for (self.pending.items) |item| item.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.requests.deinit(self.allocator);
    self.file.close(self.io);
}

/// Appends one durable transaction. Older mutations are retained in the journal
/// but do not replace the current fact or create new dirty work.
pub fn append(self: *Self, mutations: []const FactMutation) !void {
    const accepted = try self.allocator.alloc(bool, mutations.len);
    defer self.allocator.free(accepted);
    try self.appendBatch(mutations, accepted);
}

/// Variant useful to callers that need the LWW acceptance result.
pub fn appendBatch(self: *Self, mutations: []const FactMutation, accepted: []bool) !void {
    try self.enqueueBatch(mutations, accepted, .strict);
}

/// Applies LWW state immediately, then queues the durable record. Strict mode
/// waits for the writer (including fsync); eventual mode returns after enqueue.
pub fn enqueueBatch(self: *Self, mutations: []const FactMutation, accepted: []bool, durability: Durability) !void {
    if (accepted.len != mutations.len) return error.InvalidResultBuffer;
    @memset(accepted, false);
    if (mutations.len == 0) return;
    if (self.worker == null) try self.start();

    var request = try self.allocator.create(Request);
    request.* = .{ .allocator = self.allocator, .accepted = try self.allocator.alloc(bool, mutations.len), .caller_waits = durability == .strict };
    errdefer request.deinit();
    @memset(request.accepted, false);
    for (mutations) |mutation| {
        try request.mutations.append(self.allocator, .{
            .namespace = try self.allocator.dupe(u8, mutation.namespace),
            .entity = mutation.entity,
            .component = mutation.component,
            .value = try self.allocator.dupe(u8, mutation.value),
            .timestamp = mutation.timestamp,
            .cause = .{ .cause = mutation.cause.cause, .entity = mutation.cause.entity, .node = try self.allocator.dupe(u8, mutation.cause.node) },
        });
    }

    self.mutex.lockUncancelable(self.io);
    for (request.mutations.items, 0..) |mutation, i| {
        request.accepted[i] = self.applyMutation(mutation) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
    }
    self.requests.append(self.allocator, request) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    if (durability == .eventual) {
        @memcpy(accepted, request.accepted);
        self.mutex.unlock(self.io);
        return;
    }
    self.mutex.unlock(self.io);
    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (request.done) break;
        self.mutex.unlock(self.io);
        self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
    }
    @memcpy(accepted, request.accepted);
    const err = request.err;
    self.mutex.unlock(self.io);
    request.deinit();
    if (err) |failure| return failure;
}

fn workerMain(self: *Self) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (self.requests.items.len == 0 and self.stopping) {
            self.mutex.unlock(self.io);
            return;
        }
        if (self.requests.items.len == 0) {
            self.mutex.unlock(self.io);
            self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
            continue;
        }
        const request = self.requests.orderedRemove(0);
        self.mutex.unlock(self.io);

        var failure: ?anyerror = null;
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const result = if (request.record_kind == RecordCascade)
                self.writeCascade(request.mutations.items, request.ack_id)
            else
                self.writeBatch(request.mutations.items);
            if (result) |_| {
                failure = null;
                break;
            } else |err| {
                failure = err;
                self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
            }
        }
        self.mutex.lockUncancelable(self.io);
        request.err = failure;
        request.done = true;
        self.mutex.unlock(self.io);
        if (failure) |err| std.log.err("WAL write failed after retries: {}", .{err});
        if (!request.caller_waits) request.deinit();
    }
}

fn writeBatch(self: *Self, mutations: []const FactMutation) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    try putU32(&payload, self.allocator, @intCast(mutations.len));
    for (mutations) |mutation| try encodeMutation(&payload, self.allocator, mutation);
    try self.writeRecord(RecordBatch, payload.items);
}

fn writeCascade(self: *Self, mutations: []const FactMutation, ack_id: i64) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    try putU64(&payload, self.allocator, @bitCast(ack_id));
    try putU32(&payload, self.allocator, @intCast(mutations.len));
    for (mutations) |mutation| try encodeMutation(&payload, self.allocator, mutation);
    try self.writeRecord(RecordCascade, payload.items);
}

pub fn recover(self: *Self) !void {
    const size = (try self.file.stat(self.io)).size;
    if (size == 0) return;
    const bytes = try self.allocator.alloc(u8, @intCast(size));
    defer self.allocator.free(bytes);
    const got = try self.file.readPositionalAll(self.io, bytes, 0);
    var pos: usize = 0;
    while (pos + HeaderSize <= got) {
        const length = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const end = pos + HeaderSize + @as(usize, length) + TrailerSize;
        if (length < 1 or end > got) break;
        const body = bytes[pos + HeaderSize ..][0..length];
        const stored = std.mem.readInt(u32, bytes[pos + HeaderSize + length ..][0..4], .little);
        if (checksum(body) != stored) break;
        switch (body[0]) {
            RecordBatch => self.replayBatch(body[1..]) catch break,
            RecordAck => self.replayAck(body[1..]) catch break,
            RecordCascade => self.replayCascade(body[1..]) catch break,
            else => break,
        }
        pos = end;
    }
}

pub fn getFact(self: *Self, namespace: []const u8, entity: types.EntityId, component: types.ComponentId) !?Fact {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const key = try makeKey(self.allocator, namespace, entity, component);
    defer self.allocator.free(key);
    const found = self.facts.get(key) orelse return null;
    return .{ .value = try self.allocator.dupe(u8, found.value), .timestamp = found.timestamp, .cause = found.cause };
}

pub fn latestTimestamp(self: *Self, namespace: []const u8) !?Timestamp {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var result: ?Timestamp = null;
    var it = self.facts.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, namespace)) continue;
        if (entry.key_ptr.*.len <= namespace.len or entry.key_ptr.*[namespace.len] != 0) continue;
        if (result == null or entry.value_ptr.timestamp.after(result.?)) result = entry.value_ptr.timestamp;
    }
    return result;
}

pub fn pendingCountFor(self: *Self, namespace: ?[]const u8) u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var count: u64 = 0;
    for (self.pending.items) |item| {
        if (namespace == null or std.mem.eql(u8, namespace.?, item.namespace)) count += 1;
    }
    return count;
}

pub fn nextPending(self: *Self) !?PendingDirty {
    return self.nextPendingFor(null);
}

pub fn nextPendingFor(self: *Self, namespace: ?[]const u8) !?PendingDirty {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.pending.items) |item| {
        if (namespace == null or std.mem.eql(u8, namespace.?, item.namespace)) {
            return .{ .id = item.id, .namespace = try self.allocator.dupe(u8, item.namespace), .entity = item.entity, .component = item.component };
        }
    }
    return null;
}

pub fn ack(self: *Self, id: i64) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var payload: [8]u8 = undefined;
    std.mem.writeInt(i64, &payload, id, .little);
    try self.writeRecord(RecordAck, &payload);
    for (self.pending.items, 0..) |item, i| {
        if (item.id == id) {
            item.deinit(self.allocator);
            _ = self.pending.orderedRemove(i);
            return;
        }
    }
}

/// Queues a cascade checkpoint. Eventual mode returns after the checkpoint
/// has been copied into the writer queue; strict mode waits for the fsync.
/// The in-memory fact and pending state is advanced immediately so execution
/// does not wait on the file writer.
pub fn flushCascade(self: *Self, mutations: []const FactMutation, ack_id: i64, durability: Durability) !void {
    if (self.worker == null) try self.start();

    var request = try self.allocator.create(Request);
    request.* = .{
        .allocator = self.allocator,
        .accepted = try self.allocator.alloc(bool, 0),
        .record_kind = RecordCascade,
        .ack_id = ack_id,
        .caller_waits = durability == .strict,
    };
    errdefer request.deinit();
    for (mutations) |mutation| {
        try request.mutations.append(self.allocator, .{
            .namespace = try self.allocator.dupe(u8, mutation.namespace),
            .entity = mutation.entity,
            .component = mutation.component,
            .value = try self.allocator.dupe(u8, mutation.value),
            .timestamp = mutation.timestamp,
            .cause = .{
                .cause = mutation.cause.cause,
                .entity = mutation.cause.entity,
                .node = try self.allocator.dupe(u8, mutation.cause.node),
            },
        });
    }

    self.mutex.lockUncancelable(self.io);
    for (mutations) |mutation| self.applyMutationNoDirty(mutation) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    for (self.pending.items, 0..) |item, i| {
        if (item.id == ack_id) {
            item.deinit(self.allocator);
            _ = self.pending.orderedRemove(i);
            break;
        }
    }
    self.requests.append(self.allocator, request) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);

    if (durability == .eventual) return;
    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (request.done) break;
        self.mutex.unlock(self.io);
        self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
    }
    const err = request.err;
    self.mutex.unlock(self.io);
    request.deinit();
    if (err) |failure| return failure;
}

/// Applies a mutation to the in-memory fact map without adding a pending dirty entry.
/// Used to materialise cascade output facts that have already been applied to the LWW store.
fn applyMutationNoDirty(self: *Self, mutation: FactMutation) !void {
    const key = try makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component);
    if (self.facts.getPtr(key)) |current| {
        self.allocator.free(key);
        if (mutation.timestamp.compare(current.timestamp) != .gt) return;
        self.allocator.free(current.value);
        current.* = .{ .value = try self.allocator.dupe(u8, mutation.value), .timestamp = mutation.timestamp, .cause = mutation.cause };
    } else {
        try self.facts.put(self.allocator, key, .{ .value = try self.allocator.dupe(u8, mutation.value), .timestamp = mutation.timestamp, .cause = mutation.cause });
    }
}

fn applyMutation(self: *Self, mutation: FactMutation) !bool {
    const key = try makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component);
    if (self.facts.getPtr(key)) |current| {
        self.allocator.free(key);
        if (mutation.timestamp.compare(current.timestamp) != .gt) return false;
        self.allocator.free(current.value);
        current.* = .{ .value = try self.allocator.dupe(u8, mutation.value), .timestamp = mutation.timestamp, .cause = mutation.cause };
    } else {
        try self.facts.put(self.allocator, key, .{ .value = try self.allocator.dupe(u8, mutation.value), .timestamp = mutation.timestamp, .cause = mutation.cause });
    }
    try self.pending.append(self.allocator, .{ .id = self.next_id, .namespace = try self.allocator.dupe(u8, mutation.namespace), .entity = mutation.entity, .component = mutation.component });
    self.next_id += 1;
    return true;
}

fn writeRecord(self: *Self, kind: u8, payload: []const u8) !void {
    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    const length: u32 = @intCast(payload.len + 1);
    const total = HeaderSize + @as(usize, length) + TrailerSize;
    const bytes = try self.allocator.alloc(u8, total);
    defer self.allocator.free(bytes);
    std.mem.writeInt(u32, bytes[0..4], length, .little);
    bytes[4] = kind;
    @memcpy(bytes[5 .. 5 + payload.len], payload);
    std.mem.writeInt(u32, bytes[5 + payload.len ..][0..4], checksum(bytes[4 .. 5 + payload.len]), .little);
    const offset = (try self.file.stat(self.io)).size;
    try self.file.writePositionalAll(self.io, bytes, offset);
    try self.file.sync(self.io);
}

fn replayBatch(self: *Self, bytes: []const u8) !void {
    if (bytes.len < 4) return error.CorruptWal;
    var pos: usize = 4;
    const count = std.mem.readInt(u32, bytes[0..4], .little);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const decoded = try decodeMutation(bytes, &pos, self.allocator);
        defer self.allocator.free(decoded.namespace);
        defer self.allocator.free(decoded.value);
        defer self.allocator.free(decoded.cause.node);
        _ = try self.applyMutation(decoded);
    }
    if (pos != bytes.len) return error.CorruptWal;
}

fn replayAck(self: *Self, bytes: []const u8) !void {
    if (bytes.len != 8) return error.CorruptWal;
    const id = std.mem.readInt(i64, bytes[0..8], .little);
    for (self.pending.items, 0..) |item, i| if (item.id == id) {
        item.deinit(self.allocator);
        _ = self.pending.orderedRemove(i);
        break;
    };
}

fn replayCascade(self: *Self, bytes: []const u8) !void {
    if (bytes.len < 12) return error.CorruptWal;
    var pos: usize = 0;
    const ack_id: i64 = @bitCast(try getU64(bytes, &pos));
    const count = try getU32(bytes, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const decoded = try decodeMutation(bytes, &pos, self.allocator);
        defer self.allocator.free(decoded.namespace);
        defer self.allocator.free(decoded.value);
        defer self.allocator.free(decoded.cause.node);
        try self.applyMutationNoDirty(decoded);
    }
    for (self.pending.items, 0..) |item, idx| if (item.id == ack_id) {
        item.deinit(self.allocator);
        _ = self.pending.orderedRemove(idx);
        break;
    };
}

fn encodeMutation(out: *std.ArrayList(u8), allocator: std.mem.Allocator, m: FactMutation) !void {
    try putBytes(out, allocator, m.namespace);
    try putU32(out, allocator, m.entity);
    try putU32(out, allocator, m.component);
    try putBytes(out, allocator, m.value);
    try putU64(out, allocator, m.timestamp.wall);
    try putU32(out, allocator, m.timestamp.logical);
    try putU32(out, allocator, m.timestamp.node_id);
    try putU32(out, allocator, m.cause.cause);
    try putU32(out, allocator, m.cause.entity);
    try putBytes(out, allocator, m.cause.node);
}

fn decodeMutation(bytes: []const u8, pos: *usize, allocator: std.mem.Allocator) !FactMutation {
    const namespace = try getBytes(bytes, pos, allocator);
    errdefer allocator.free(namespace);
    const entity = try getU32(bytes, pos);
    const component = try getU32(bytes, pos);
    const value = getBytes(bytes, pos, allocator) catch |err| {
        allocator.free(namespace);
        return err;
    };
    const wall = try getU64(bytes, pos);
    const logical = try getU32(bytes, pos);
    const node_id = try getU32(bytes, pos);
    const cause = types.CausalTag{ .cause = try getU32(bytes, pos), .entity = try getU32(bytes, pos), .node = try getBytes(bytes, pos, allocator) };
    return .{ .namespace = namespace, .entity = entity, .component = component, .value = value, .timestamp = .{ .wall = wall, .logical = logical, .node_id = node_id }, .cause = cause };
}

fn putU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, value, .little);
    try out.appendSlice(allocator, &b);
}
fn putU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, value, .little);
    try out.appendSlice(allocator, &b);
}
fn putBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try putU32(out, allocator, @intCast(bytes.len));
    try out.appendSlice(allocator, bytes);
}
fn getU32(bytes: []const u8, pos: *usize) !u32 {
    if (bytes.len -| pos.* < 4) return error.CorruptWal;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}
fn getU64(bytes: []const u8, pos: *usize) !u64 {
    if (bytes.len -| pos.* < 8) return error.CorruptWal;
    const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}
fn getBytes(bytes: []const u8, pos: *usize, allocator: std.mem.Allocator) ![]u8 {
    const n = try getU32(bytes, pos);
    if (n > bytes.len - pos.*) return error.CorruptWal;
    const result = try allocator.dupe(u8, bytes[pos.*..][0..n]);
    pos.* += n;
    return result;
}

fn makeKey(allocator: std.mem.Allocator, namespace: []const u8, entity: u32, component: u32) ![]u8 {
    const key = try allocator.alloc(u8, namespace.len + 9);
    @memcpy(key[0..namespace.len], namespace);
    key[namespace.len] = 0;
    std.mem.writeInt(u32, key[namespace.len + 1 ..][0..4], entity, .little);
    std.mem.writeInt(u32, key[namespace.len + 5 ..][0..4], component, .little);
    return key;
}
fn checksum(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}

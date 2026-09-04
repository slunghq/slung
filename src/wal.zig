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
        allocator.free(self.cause.node);
    }
};

const FactUndo = struct {
    key: []u8,
    previous: ?Fact,
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
    apply_after_write: bool = false,

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
const MaxRecordSize: u32 = 16 * 1024 * 1024;
const MaxFieldSize: u32 = 8 * 1024 * 1024;
const MaxMutationCount: u32 = 1 * 1024 * 1024;
const MaxQueuedRequests: usize = 4096;

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
failed: bool = false,

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
        self.allocator.free(entry.value_ptr.cause.node);
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
    request.* = .{ .allocator = self.allocator, .accepted = try self.allocator.alloc(bool, mutations.len), .caller_waits = durability == .strict, .apply_after_write = durability == .strict };
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

    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (self.failed) {
            self.mutex.unlock(self.io);
            return error.WalUnavailable;
        }
        if (self.requests.items.len < MaxQueuedRequests) break;
        self.mutex.unlock(self.io);
        self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
    }
    // Reserve admission before publishing eventual mutations. The worker
    // cannot consume this slot while the mutex is held.
    self.requests.ensureUnusedCapacity(self.allocator, 1) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    if (!request.apply_after_write) {
        const pending_start = self.pending.items.len;
        const next_id_start = self.next_id;
        var undo: std.ArrayList(FactUndo) = .empty;
        defer {
            for (undo.items) |item| {
                self.allocator.free(item.key);
                if (item.previous) |fact| fact.deinit(self.allocator);
            }
            undo.deinit(self.allocator);
        }
        for (request.mutations.items, 0..) |mutation, i| {
            const key = makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component) catch |err| {
                self.rollbackFacts(undo.items);
                self.rollbackPending(pending_start, next_id_start);
                self.mutex.unlock(self.io);
                return err;
            };
            const previous = if (self.facts.get(key)) |fact|
                (cloneFact(self.allocator, fact) catch |err| {
                    self.allocator.free(key);
                    self.rollbackFacts(undo.items);
                    self.rollbackPending(pending_start, next_id_start);
                    self.mutex.unlock(self.io);
                    return err;
                })
            else
                null;
            undo.append(self.allocator, .{ .key = key, .previous = previous }) catch |err| {
                self.allocator.free(key);
                if (previous) |fact| fact.deinit(self.allocator);
                self.rollbackFacts(undo.items);
                self.rollbackPending(pending_start, next_id_start);
                self.mutex.unlock(self.io);
                return err;
            };
            request.accepted[i] = self.applyMutation(mutation) catch |err| {
                self.rollbackFacts(undo.items);
                self.rollbackPending(pending_start, next_id_start);
                self.mutex.unlock(self.io);
                return err;
            };
        }
    }
    // Capacity was reserved while holding the same mutex the worker uses.
    // appendAssumeCapacity makes admission atomic with respect to mutation
    // publication: a queue allocation failure cannot expose live state.
    self.requests.appendAssumeCapacity(request);
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
        // Take a snapshot of all currently queued requests. They become one
        // commit group: records are appended in order, followed by one fsync.
        var batch = self.requests;
        self.requests = .empty;
        self.mutex.unlock(self.io);

        var failure: ?anyerror = null;
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            failure = null;
            for (batch.items) |request| {
                const result = if (request.record_kind == RecordCascade)
                    self.writeCascade(request.mutations.items, request.ack_id)
                else
                    self.writeBatch(request.mutations.items);
                if (result) |_| {} else |err| {
                    failure = err;
                    break;
                }
            }
            if (failure == null) {
                self.write_mutex.lockUncancelable(self.io);
                const sync_result = self.file.sync(self.io);
                self.write_mutex.unlock(self.io);
                if (sync_result) |_| {} else |err| failure = err;
            }
            if (failure == null) break;
            self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
        }

        // Strict requests are admitted to the queue before they become live.
        // Publish them only after the record and its fsync have succeeded.
        if (failure == null) {
            self.mutex.lockUncancelable(self.io);
            const publication_pending_start = self.pending.items.len;
            const publication_next_id = self.next_id;
            var publication_undo: std.ArrayList(FactUndo) = .empty;
            for (batch.items) |request| {
                if (!request.apply_after_write) continue;
                for (request.mutations.items, 0..) |mutation, i| {
                    const key = makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component) catch |err| {
                        failure = err;
                        break;
                    };
                    const previous = if (self.facts.get(key)) |fact|
                        (cloneFact(self.allocator, fact) catch |err| {
                            self.allocator.free(key);
                            failure = err;
                            break;
                        })
                    else
                        null;
                    publication_undo.append(self.allocator, .{ .key = key, .previous = previous }) catch |err| {
                        self.allocator.free(key);
                        if (previous) |fact| fact.deinit(self.allocator);
                        failure = err;
                        break;
                    };
                    if (request.record_kind == RecordCascade) {
                        self.applyMutationNoDirty(mutation) catch |err| {
                            failure = err;
                            break;
                        };
                    } else {
                        request.accepted[i] = self.applyMutation(mutation) catch |err| {
                            failure = err;
                            break;
                        };
                    }
                }
                if (failure != null) break;
            }
            if (failure != null) {
                self.rollbackFacts(publication_undo.items);
                self.rollbackPending(publication_pending_start, publication_next_id);
            }
            for (publication_undo.items) |item| {
                self.allocator.free(item.key);
                if (item.previous) |fact| fact.deinit(self.allocator);
            }
            publication_undo.deinit(self.allocator);
            self.mutex.unlock(self.io);
        }

        self.mutex.lockUncancelable(self.io);
        for (batch.items) |request| {
            request.err = failure;
            request.done = true;
        }
        if (failure) |err| {
            self.failed = true;
            // Wake strict callers and reject queued work instead of leaving
            // requests waiting forever after a terminal writer failure.
            for (self.requests.items) |queued| {
                queued.err = error.WalUnavailable;
                queued.done = true;
                if (!queued.caller_waits) queued.deinit();
            }
            self.requests.clearRetainingCapacity();
            std.log.err("WAL commit failed after retries: {}", .{err});
        }
        self.mutex.unlock(self.io);

        for (batch.items) |request| {
            if (!request.caller_waits) request.deinit();
        }
        batch.deinit(self.allocator);
    }
}

fn writeBatch(self: *Self, mutations: []const FactMutation) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    try putU32(&payload, self.allocator, @intCast(mutations.len));
    for (mutations) |mutation| try encodeMutation(&payload, self.allocator, mutation);
    try self.writeRecord(RecordBatch, payload.items, false);
}

fn writeCascade(self: *Self, mutations: []const FactMutation, ack_id: i64) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    try putU64(&payload, self.allocator, @bitCast(ack_id));
    try putU32(&payload, self.allocator, @intCast(mutations.len));
    for (mutations) |mutation| try encodeMutation(&payload, self.allocator, mutation);
    try self.writeRecord(RecordCascade, payload.items, false);
}

pub fn recover(self: *Self) !void {
    const size = (try self.file.stat(self.io)).size;
    if (size == 0) return;
    const bytes = try self.allocator.alloc(u8, @intCast(size));
    defer self.allocator.free(bytes);
    const got = try self.file.readPositionalAll(self.io, bytes, 0);
    var pos: usize = 0;
    while (pos < got) {
        // A short header or body is a torn final write. Discard only that
        // incomplete tail; a complete malformed record is a hard failure.
        if (got - pos < HeaderSize) {
            try self.file.setLength(self.io, @intCast(pos));
            return;
        }
        const length = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        if (length < 1 or length > MaxRecordSize) return error.CorruptWal;
        const remaining = got - pos;
        if (@as(usize, length) > remaining -| HeaderSize -| TrailerSize) {
            try self.file.setLength(self.io, @intCast(pos));
            return;
        }
        const end = pos + HeaderSize + @as(usize, length) + TrailerSize;
        const body = bytes[pos + HeaderSize ..][0..length];
        const stored = std.mem.readInt(u32, bytes[pos + HeaderSize + length ..][0..4], .little);
        if (checksum(body) != stored) return error.CorruptWal;
        switch (body[0]) {
            RecordBatch => try self.replayBatch(body[1..]),
            RecordAck => try self.replayAck(body[1..]),
            RecordCascade => try self.replayCascade(body[1..]),
            else => return error.CorruptWal,
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
    const value = try self.allocator.dupe(u8, found.value);
    errdefer self.allocator.free(value);
    const cause_node = try self.allocator.dupe(u8, found.cause.node);
    return .{
        .value = value,
        .timestamp = found.timestamp,
        .cause = .{
            .cause = found.cause.cause,
            .entity = found.cause.entity,
            .node = cause_node,
        },
    };
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
    try self.writeRecord(RecordAck, &payload, true);
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
        .apply_after_write = durability == .strict,
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

    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (self.failed) {
            self.mutex.unlock(self.io);
            return error.WalUnavailable;
        }
        if (self.requests.items.len < MaxQueuedRequests) break;
        self.mutex.unlock(self.io);
        self.io.sleep(std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
    }
    // Enqueue before changing WAL-owned live state. The worker cannot take
    // this request until the mutex is released, so an enqueue failure leaves
    // the pending root and fact map untouched.
    self.requests.append(self.allocator, request) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    if (durability == .eventual) {
        var undo: std.ArrayList(FactUndo) = .empty;
        defer {
            for (undo.items) |item| {
                self.allocator.free(item.key);
                if (item.previous) |fact| fact.deinit(self.allocator);
            }
            undo.deinit(self.allocator);
        }
        for (mutations) |mutation| {
            const key = makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component) catch |err| {
                self.rollbackFacts(undo.items);
                _ = self.requests.pop();
                self.mutex.unlock(self.io);
                return err;
            };
            const previous = if (self.facts.get(key)) |fact|
                (cloneFact(self.allocator, fact) catch |err| {
                    self.allocator.free(key);
                    self.rollbackFacts(undo.items);
                    _ = self.requests.pop();
                    self.mutex.unlock(self.io);
                    return err;
                })
            else
                null;
            undo.append(self.allocator, .{ .key = key, .previous = previous }) catch |err| {
                self.rollbackFacts(undo.items);
                self.allocator.free(key);
                if (previous) |fact| fact.deinit(self.allocator);
                _ = self.requests.pop();
                self.mutex.unlock(self.io);
                return err;
            };
            self.applyMutationNoDirty(mutation) catch |err| {
                self.rollbackFacts(undo.items);
                _ = self.requests.pop();
                self.mutex.unlock(self.io);
                return err;
            };
        }
        self.removePending(ack_id);
    }
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

    self.mutex.lockUncancelable(self.io);
    self.removePending(ack_id);
    self.mutex.unlock(self.io);
}

fn removePending(self: *Self, ack_id: i64) void {
    for (self.pending.items, 0..) |item, i| {
        if (item.id == ack_id) {
            item.deinit(self.allocator);
            _ = self.pending.orderedRemove(i);
            return;
        }
    }
}

fn rollbackFacts(self: *Self, undo: []FactUndo) void {
    var i = undo.len;
    while (i > 0) {
        i -= 1;
        const item = &undo[i];
        if (item.previous) |fact| {
            // The mutation that produced this undo record must still have a
            // live entry. Restore its owned bytes in place; allocating during
            // rollback could turn a durable failure into a missing fact.
            if (self.facts.getPtr(item.key)) |current| {
                self.allocator.free(current.value);
                self.allocator.free(current.cause.node);
                current.* = fact;
                item.previous = null;
            }
        } else {
            if (self.facts.fetchRemove(item.key)) |removed| {
                self.allocator.free(removed.key);
                removed.value.deinit(self.allocator);
            }
        }
    }
}

fn rollbackPending(self: *Self, pending_start: usize, next_id: i64) void {
    while (self.pending.items.len > pending_start) {
        const item = self.pending.pop().?;
        item.deinit(self.allocator);
    }
    self.next_id = next_id;
}

fn cloneFact(allocator: std.mem.Allocator, fact: Fact) !Fact {
    const value = try allocator.dupe(u8, fact.value);
    errdefer allocator.free(value);
    const node = try allocator.dupe(u8, fact.cause.node);
    return .{ .value = value, .timestamp = fact.timestamp, .cause = .{
        .cause = fact.cause.cause,
        .entity = fact.cause.entity,
        .node = node,
    } };
}

/// Applies a mutation to the in-memory fact map without adding a pending dirty entry.
/// Used to materialise cascade output facts that have already been applied to the LWW store.
fn applyMutationNoDirty(self: *Self, mutation: FactMutation) !void {
    const key = try makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component);
    const value = try self.allocator.dupe(u8, mutation.value);
    errdefer self.allocator.free(value);
    const cause_node = try self.allocator.dupe(u8, mutation.cause.node);
    errdefer self.allocator.free(cause_node);
    const cause: types.CausalTag = .{ .cause = mutation.cause.cause, .entity = mutation.cause.entity, .node = cause_node };
    if (self.facts.getPtr(key)) |current| {
        self.allocator.free(key);
        if (mutation.timestamp.compare(current.timestamp) != .gt) {
            self.allocator.free(value);
            self.allocator.free(cause_node);
            return;
        }
        self.allocator.free(current.value);
        self.allocator.free(current.cause.node);
        current.* = .{ .value = value, .timestamp = mutation.timestamp, .cause = cause };
    } else {
        self.facts.put(self.allocator, key, .{ .value = value, .timestamp = mutation.timestamp, .cause = cause }) catch |err| {
            self.allocator.free(key);
            return err;
        };
    }
}

fn applyMutation(self: *Self, mutation: FactMutation) !bool {
    try self.pending.ensureUnusedCapacity(self.allocator, 1);
    var pending_namespace: ?[]u8 = try self.allocator.dupe(u8, mutation.namespace);
    errdefer if (pending_namespace) |namespace| self.allocator.free(namespace);

    const key = try makeKey(self.allocator, mutation.namespace, mutation.entity, mutation.component);
    const value = try self.allocator.dupe(u8, mutation.value);
    errdefer self.allocator.free(value);
    const cause_node = try self.allocator.dupe(u8, mutation.cause.node);
    errdefer self.allocator.free(cause_node);
    const cause: types.CausalTag = .{ .cause = mutation.cause.cause, .entity = mutation.cause.entity, .node = cause_node };
    if (self.facts.getPtr(key)) |current| {
        self.allocator.free(key);
        if (mutation.timestamp.compare(current.timestamp) != .gt) {
            self.allocator.free(value);
            self.allocator.free(cause_node);
            self.allocator.free(pending_namespace.?);
            pending_namespace = null;
            return false;
        }
        self.allocator.free(current.value);
        self.allocator.free(current.cause.node);
        current.* = .{ .value = value, .timestamp = mutation.timestamp, .cause = cause };
    } else {
        self.facts.put(self.allocator, key, .{ .value = value, .timestamp = mutation.timestamp, .cause = cause }) catch |err| {
            self.allocator.free(key);
            return err;
        };
    }
    self.pending.appendAssumeCapacity(.{
        .id = self.next_id,
        .namespace = pending_namespace.?,
        .entity = mutation.entity,
        .component = mutation.component,
    });
    pending_namespace = null;
    self.next_id += 1;
    return true;
}

fn writeRecord(self: *Self, kind: u8, payload: []const u8, sync: bool) !void {
    if (payload.len > MaxRecordSize - 1) return error.WalRecordTooLarge;
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
    if (sync) try self.file.sync(self.io);
}

fn replayBatch(self: *Self, bytes: []const u8) !void {
    if (bytes.len < 4) return error.CorruptWal;
    var pos: usize = 4;
    const count = std.mem.readInt(u32, bytes[0..4], .little);
    if (count > MaxMutationCount) return error.CorruptWal;
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
    if (count > MaxMutationCount) return error.CorruptWal;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const decoded = try decodeMutation(bytes, &pos, self.allocator);
        defer self.allocator.free(decoded.namespace);
        defer self.allocator.free(decoded.value);
        defer self.allocator.free(decoded.cause.node);
        try self.applyMutationNoDirty(decoded);
    }
    if (pos != bytes.len) return error.CorruptWal;
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
    if (n > MaxFieldSize or n > bytes.len - pos.*) return error.CorruptWal;
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

const std = @import("std");
const sqlite = @import("slung.zig").sqlite;
const types = @import("types.zig");
const Timestamp = @import("primitives/hlc.zig").Timestamp;
const Wal = @import("wal.zig");

pub const Storage = @This();

const sqlite_ok = 0;
const sqlite_row = 100;
const sqlite_done = 101;
const sqlite_open_readwrite = 0x00000002;
const sqlite_open_create = 0x00000004;
const sqlite_open_fullmutex = 0x00010000;

pub const FactMutation = Wal.FactMutation;
pub const Fact = Wal.Fact;
pub const PendingDirty = Wal.PendingDirty;
pub const Durability = Wal.Durability;

allocator: std.mem.Allocator,
db: *sqlite.sqlite3,
wal: Wal,
wal_path: []u8,
temporary_wal: bool,
io: std.Io,
durability: Durability = .eventual,

pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Storage {
    return openWithDurability(allocator, io, path, .eventual);
}

pub fn openWithDurability(allocator: std.mem.Allocator, io: std.Io, path: []const u8, durability: Durability) !Storage {
    var db: ?*sqlite.sqlite3 = null;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const rc = sqlite.sqlite3_open_v2(
        path_z.ptr,
        &db,
        sqlite_open_readwrite | sqlite_open_create | sqlite_open_fullmutex,
        null,
    );
    if (rc != sqlite_ok or db == null) {
        if (db) |handle| _ = sqlite.sqlite3_close(handle);
        return error.SqliteOpenFailed;
    }

    const wal_path = if (std.mem.eql(u8, path, ":memory:"))
        try std.fmt.allocPrint(allocator, ".slung-memory-{x}.wal", .{@intFromPtr(db.?)})
    else
        try std.fmt.allocPrint(allocator, "{s}.slung.wal", .{path});
    errdefer allocator.free(wal_path);

    var storage = Storage{
        .allocator = allocator,
        .db = db.?,
        .wal = undefined,
        .wal_path = wal_path,
        .temporary_wal = std.mem.eql(u8, path, ":memory:"),
        .io = io,
    };
    storage.wal = Wal.open(allocator, io, wal_path) catch |err| {
        _ = sqlite.sqlite3_close(storage.db);
        return err;
    };
    errdefer storage.deinit();

    try storage.configure();
    try storage.createSchema();
    storage.durability = durability;
    return storage;
}

pub fn deinit(self: *Storage) void {
    self.wal.deinit();
    if (self.temporary_wal) {
        std.Io.Dir.cwd().deleteFile(self.io, self.wal_path) catch {};
    }
    self.allocator.free(self.wal_path);
    _ = sqlite.sqlite3_close(self.db);
}

/// Applies a fact mutation and creates its pending inference work atomically.
/// Returns false when the mutation loses the LWW comparison.
pub fn applyMutation(self: *Storage, mutation: FactMutation) !bool {
    var accepted = [_]bool{false};
    try self.applyMutations(&.{mutation}, accepted[0..]);
    return accepted[0];
}

/// Appends a batch to the durable fact journal.
pub fn applyMutations(
    self: *Storage,
    mutations: []const FactMutation,
    accepted: []bool,
) !void {
    try self.wal.enqueueBatch(mutations, accepted, self.durability);
}

/// Reads the latest persisted fact for a namespace/entity/component.
pub fn getFact(
    self: *Storage,
    namespace: []const u8,
    entity: types.EntityId,
    component: types.ComponentId,
) !?Fact {
    return self.wal.getFact(namespace, entity, component);
}

/// Returns the oldest unacknowledged dirty entry. The caller owns the namespace.
pub fn nextPendingDirty(self: *Storage) !?PendingDirty {
    return self.nextPendingDirtyFor(null);
}

pub fn nextPendingDirtyFor(self: *Storage, namespace: ?[]const u8) !?PendingDirty {
    return self.wal.nextPendingFor(namespace);
}

/// Writes all rule-produced mutations and the dirty acknowledgement in one WAL record.
/// Caller must have already updated the LWW store. In-memory WAL state is updated
/// atomically under the WAL mutex. No blocking task is needed in eventual mode.
pub fn flushCascade(self: *Storage, mutations: []const FactMutation, ack_id: i64) !void {
    try self.wal.flushCascade(mutations, ack_id, self.durability);
}

/// Acknowledges work after the inference step has completed successfully.
pub fn acknowledgeDirty(self: *Storage, id: i64) !void {
    const ids = [_]i64{id};
    try self.acknowledgeDirtyBatch(ids[0..]);
}

/// Acknowledges several completed inference entries in one transaction.
pub fn acknowledgeDirtyBatch(self: *Storage, ids: []const i64) !void {
    for (ids) |id| try self.wal.ack(id);
}

pub fn pendingDirtyCount(self: *Storage) !u64 {
    return self.pendingDirtyCountFor(null);
}

pub fn pendingDirtyCountFor(self: *Storage, namespace: ?[]const u8) !u64 {
    return self.wal.pendingCountFor(namespace);
}

/// Reads opaque module-owned data scoped to a namespace, module, and entity.
/// The returned value is owned by the caller.
pub fn get(
    self: *Storage,
    namespace: []const u8,
    module: []const u8,
    key: []const u8,
) !?[]u8 {
    const stmt = try self.prepare(
        "SELECT value FROM module_kv WHERE namespace = ? AND module = ? AND key = ?;",
    );
    defer self.finalize(stmt);

    try bindText(stmt, 1, namespace);
    try bindText(stmt, 2, module);
    try bindBlob(stmt, 3, key);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite_done) return null;
    if (rc != sqlite_row) return self.sqliteError();

    const value_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
    if (value_len == 0) return try self.allocator.alloc(u8, 0);

    const value_ptr = sqlite.sqlite3_column_blob(stmt, 0) orelse return error.SqliteInvalidRow;
    return try self.allocator.dupe(u8, @as([*]const u8, @ptrCast(value_ptr))[0..value_len]);
}

/// Stores opaque module-owned data. The write is durable when this returns.
pub fn set(
    self: *Storage,
    namespace: []const u8,
    module: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    try self.exec("BEGIN IMMEDIATE;");
    var committed = false;
    errdefer if (!committed) self.exec("ROLLBACK;") catch {};

    const stmt = try self.prepare(
        "INSERT INTO module_kv (namespace, module, key, value) VALUES (?, ?, ?, ?) " ++
            "ON CONFLICT(namespace, module, key) DO UPDATE SET value = excluded.value;",
    );
    defer self.finalize(stmt);

    try bindText(stmt, 1, namespace);
    try bindText(stmt, 2, module);
    try bindBlob(stmt, 3, key);
    try bindBlob(stmt, 4, value);
    try self.step(stmt);

    try self.exec("COMMIT;");
    committed = true;
}

/// Deletes module-owned data. Returns true if a value existed.
pub fn delete(
    self: *Storage,
    namespace: []const u8,
    module: []const u8,
    key: []const u8,
) !bool {
    try self.exec("BEGIN IMMEDIATE;");
    var committed = false;
    errdefer if (!committed) self.exec("ROLLBACK;") catch {};

    const stmt = try self.prepare(
        "DELETE FROM module_kv WHERE namespace = ? AND module = ? AND key = ?;",
    );
    defer self.finalize(stmt);

    try bindText(stmt, 1, namespace);
    try bindText(stmt, 2, module);
    try bindBlob(stmt, 3, key);
    try self.step(stmt);

    const deleted = sqlite.sqlite3_changes(self.db) != 0;
    try self.exec("COMMIT;");
    committed = true;
    return deleted;
}

pub fn latestTimestamp(self: *Storage, namespace: []const u8) !?Timestamp {
    return self.wal.latestTimestamp(namespace);
}

fn configure(self: *Storage) !void {
    try self.exec("PRAGMA journal_mode = WAL;");
    try self.exec("PRAGMA synchronous = FULL;");
    try self.exec("PRAGMA foreign_keys = ON;");
}

fn createSchema(self: *Storage) !void {
    try self.exec(
        "CREATE TABLE IF NOT EXISTS facts (" ++
            "namespace TEXT NOT NULL, " ++
            "entity_id INTEGER NOT NULL, " ++
            "component_id INTEGER NOT NULL, " ++
            "value BLOB NOT NULL, " ++
            "hlc_wall INTEGER NOT NULL, " ++
            "hlc_logical INTEGER NOT NULL, " ++
            "hlc_node INTEGER NOT NULL, " ++
            "cause_component INTEGER NOT NULL, " ++
            "cause_entity INTEGER NOT NULL, " ++
            "cause_node TEXT NOT NULL, " ++
            "PRIMARY KEY (namespace, entity_id, component_id)" ++
            ");" ++
            "CREATE TABLE IF NOT EXISTS mutations (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
            "namespace TEXT NOT NULL, " ++
            "entity_id INTEGER NOT NULL, " ++
            "component_id INTEGER NOT NULL, " ++
            "value BLOB NOT NULL, " ++
            "hlc_wall INTEGER NOT NULL, " ++
            "hlc_logical INTEGER NOT NULL, " ++
            "hlc_node INTEGER NOT NULL, " ++
            "cause_component INTEGER NOT NULL, " ++
            "cause_entity INTEGER NOT NULL, " ++
            "cause_node TEXT NOT NULL" ++
            ");" ++
            "CREATE TABLE IF NOT EXISTS pending_dirty (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
            "namespace TEXT NOT NULL, " ++
            "entity_id INTEGER NOT NULL, " ++
            "component_id INTEGER NOT NULL" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS pending_dirty_order ON pending_dirty(id);" ++
            "CREATE TABLE IF NOT EXISTS module_kv (" ++
            "namespace TEXT NOT NULL, " ++
            "module TEXT NOT NULL, " ++
            "key BLOB NOT NULL, " ++
            "value BLOB NOT NULL, " ++
            "PRIMARY KEY (namespace, module, key)" ++
            ");",
    );
}

fn exec(self: *Storage, sql: []const u8) !void {
    const sql_z = try self.allocator.dupeZ(u8, sql);
    defer self.allocator.free(sql_z);

    var error_message: [*c]u8 = null;
    const rc = sqlite.sqlite3_exec(self.db, sql_z.ptr, null, null, &error_message);
    if (error_message != null) sqlite.sqlite3_free(error_message);
    if (rc != sqlite_ok) return self.sqliteError();
}

fn prepare(self: *Storage, sql: []const u8) !*sqlite.sqlite3_stmt {
    const sql_z = try self.allocator.dupeZ(u8, sql);
    defer self.allocator.free(sql_z);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const rc = sqlite.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
    if (rc != sqlite_ok or stmt == null) return self.sqliteError();
    return stmt.?;
}

fn finalize(_: *Storage, stmt: *sqlite.sqlite3_stmt) void {
    _ = sqlite.sqlite3_finalize(stmt);
}

fn step(self: *Storage, stmt: *sqlite.sqlite3_stmt) !void {
    if (sqlite.sqlite3_step(stmt) != sqlite_done) return self.sqliteError();
}

fn sqliteError(self: *Storage) error{SqliteError} {
    _ = self;
    return error.SqliteError;
}

fn bindInt64(stmt: *sqlite.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (sqlite.sqlite3_bind_int64(stmt, index, @intCast(value)) != sqlite_ok) return error.SqliteError;
}

fn bindText(stmt: *sqlite.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (sqlite.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqlite.SQLITE_TRANSIENT) != sqlite_ok) {
        return error.SqliteError;
    }
}

fn bindBlob(stmt: *sqlite.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (sqlite.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), sqlite.SQLITE_TRANSIENT) != sqlite_ok) {
        return error.SqliteError;
    }
}

test "Storage: mutation and pending dirty work are atomic" {
    var storage = try Storage.open(std.testing.allocator, std.testing.io, ":memory:");
    defer storage.deinit();

    const mutation = FactMutation{
        .namespace = "test",
        .entity = 7,
        .component = 11,
        .value = "encoded-fact",
        .timestamp = .{ .wall = 100, .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 11, .entity = 7, .node = "node-1" },
    };

    try std.testing.expect(try storage.applyMutation(mutation));
    try std.testing.expectEqual(@as(u64, 1), try storage.pendingDirtyCount());

    const pending = (try storage.nextPendingDirty()).?;
    defer pending.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), pending.id);
    try std.testing.expectEqualStrings("test", pending.namespace);
    try std.testing.expectEqual(@as(types.EntityId, 7), pending.entity);
    try std.testing.expectEqual(@as(types.ComponentId, 11), pending.component);

    try storage.acknowledgeDirty(pending.id);
    try std.testing.expectEqual(@as(u64, 0), try storage.pendingDirtyCount());
}

test "Storage: older LWW mutation does not create pending work" {
    var storage = try Storage.open(std.testing.allocator, std.testing.io, ":memory:");
    defer storage.deinit();

    const newer = FactMutation{
        .namespace = "test",
        .entity = 1,
        .component = 2,
        .value = "new",
        .timestamp = .{ .wall = 200, .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 2, .entity = 1, .node = "node-1" },
    };
    const older = FactMutation{
        .namespace = "test",
        .entity = 1,
        .component = 2,
        .value = "old",
        .timestamp = .{ .wall = 100, .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 2, .entity = 1, .node = "node-1" },
    };

    try std.testing.expect(try storage.applyMutation(newer));
    try std.testing.expect(!try storage.applyMutation(older));
    try std.testing.expectEqual(@as(u64, 1), try storage.pendingDirtyCount());
}

test "Storage: module store is scoped and durable" {
    var storage = try Storage.open(std.testing.allocator, std.testing.io, ":memory:");
    defer storage.deinit();

    try storage.set("ns", "module-a", "counter", "42");

    const value = (try storage.get("ns", "module-a", "counter")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("42", value);

    try std.testing.expect((try storage.get("ns", "module-b", "counter")) == null);

    try storage.set("ns", "module-a", "counter", "43");
    try std.testing.expect(try storage.delete("ns", "module-a", "counter"));
    try std.testing.expect(!try storage.delete("ns", "module-a", "counter"));
    try std.testing.expect((try storage.get("ns", "module-a", "counter")) == null);
}

test "Storage: eventual durability owns queued mutation buffers" {
    var storage = try Storage.open(std.testing.allocator, std.testing.io, ":memory:");
    defer storage.deinit();

    const namespace = try std.testing.allocator.dupe(u8, "owned");
    const value = try std.testing.allocator.dupe(u8, "value");
    const node = try std.testing.allocator.dupe(u8, "node");
    defer std.testing.allocator.free(namespace);
    defer std.testing.allocator.free(value);
    defer std.testing.allocator.free(node);

    try std.testing.expect(try storage.applyMutation(.{
        .namespace = namespace,
        .entity = 3,
        .component = 4,
        .value = value,
        .timestamp = .{ .wall = 1, .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 4, .entity = 3, .node = node },
    }));
    @memset(namespace, 'x');
    @memset(value, 'x');
    @memset(node, 'x');
    try std.testing.expectEqual(@as(u64, 1), try storage.pendingDirtyCount());
}

test "Storage: returns latest namespace timestamp" {
    var storage = try Storage.open(std.testing.allocator, std.testing.io, ":memory:");
    defer storage.deinit();

    try std.testing.expect(
        (try storage.latestTimestamp("test")) == null,
    );

    try std.testing.expect(try storage.applyMutation(.{
        .namespace = "test",
        .entity = 1,
        .component = 1,
        .value = "old",
        .timestamp = .{ .wall = 100, .logical = 2, .node_id = 1 },
        .cause = .{ .cause = 1, .entity = 1, .node = "node-1" },
    }));

    try std.testing.expect(try storage.applyMutation(.{
        .namespace = "test",
        .entity = 2,
        .component = 1,
        .value = "new",
        .timestamp = .{ .wall = 200, .logical = 0, .node_id = 1 },
        .cause = .{ .cause = 1, .entity = 2, .node = "node-1" },
    }));

    const timestamp = (try storage.latestTimestamp("test")).?;
    try std.testing.expectEqual(@as(u64, 200), timestamp.wall);
    try std.testing.expectEqual(@as(u32, 0), timestamp.logical);
    try std.testing.expectEqual(@as(u32, 1), timestamp.node_id);
}

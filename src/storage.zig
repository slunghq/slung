const std = @import("std");
const sqlite = @import("slung.zig").sqlite;
const types = @import("types.zig");
const Timestamp = @import("primitives/hlc.zig").Timestamp;

const Storage = @This();

const sqlite_ok = 0;
const sqlite_row = 100;
const sqlite_done = 101;
const sqlite_open_readwrite = 0x00000002;
const sqlite_open_create = 0x00000004;
const sqlite_open_fullmutex = 0x00010000;

pub const FactMutation = struct {
    namespace: []const u8,
    entity: types.EntityId,
    component: types.ComponentId,
    value: []const u8,
    timestamp: Timestamp,
    cause: types.CausalTag,
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

allocator: std.mem.Allocator,
db: *sqlite.sqlite3,

pub fn open(allocator: std.mem.Allocator, path: []const u8) !Storage {
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

    var storage = Storage{
        .allocator = allocator,
        .db = db.?,
    };
    errdefer storage.deinit();

    try storage.configure();
    try storage.createSchema();
    return storage;
}

pub fn deinit(self: *Storage) void {
    _ = sqlite.sqlite3_close(self.db);
}

/// Applies a fact mutation and creates its pending inference work atomically.
/// Returns false when the mutation loses the LWW comparison.
pub fn applyMutation(self: *Storage, mutation: FactMutation) !bool {
    try self.exec("BEGIN IMMEDIATE;");
    var committed = false;
    errdefer if (!committed) self.exec("ROLLBACK;") catch {};

    const fact_stmt = try self.prepare(
        "INSERT INTO facts (namespace, entity_id, component_id, value, hlc_wall, hlc_logical, hlc_node, cause_component, cause_entity, cause_node) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " ++
            "ON CONFLICT(namespace, entity_id, component_id) DO UPDATE SET " ++
            "value=excluded.value, hlc_wall=excluded.hlc_wall, hlc_logical=excluded.hlc_logical, hlc_node=excluded.hlc_node, " ++
            "cause_component=excluded.cause_component, cause_entity=excluded.cause_entity, cause_node=excluded.cause_node " ++
            "WHERE excluded.hlc_wall > facts.hlc_wall " ++
            "OR (excluded.hlc_wall = facts.hlc_wall AND excluded.hlc_logical > facts.hlc_logical) " ++
            "OR (excluded.hlc_wall = facts.hlc_wall AND excluded.hlc_logical = facts.hlc_logical AND excluded.hlc_node > facts.hlc_node);",
    );
    defer self.finalize(fact_stmt);

    try bindText(fact_stmt, 1, mutation.namespace);
    try bindInt64(fact_stmt, 2, mutation.entity);
    try bindInt64(fact_stmt, 3, mutation.component);
    try bindBlob(fact_stmt, 4, mutation.value);
    try bindInt64(fact_stmt, 5, mutation.timestamp.wall);
    try bindInt64(fact_stmt, 6, mutation.timestamp.logical);
    try bindInt64(fact_stmt, 7, mutation.timestamp.node_id);
    try bindInt64(fact_stmt, 8, mutation.cause.cause);
    try bindInt64(fact_stmt, 9, mutation.cause.entity);
    try bindText(fact_stmt, 10, mutation.cause.node);
    try self.step(fact_stmt);

    if (sqlite.sqlite3_changes(self.db) == 0) {
        try self.exec("ROLLBACK;");
        committed = true;
        return false;
    }

    const mutation_stmt = try self.prepare(
        "INSERT INTO mutations (namespace, entity_id, component_id, value, hlc_wall, hlc_logical, hlc_node, cause_component, cause_entity, cause_node) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
    );
    defer self.finalize(mutation_stmt);
    try bindText(mutation_stmt, 1, mutation.namespace);
    try bindInt64(mutation_stmt, 2, mutation.entity);
    try bindInt64(mutation_stmt, 3, mutation.component);
    try bindBlob(mutation_stmt, 4, mutation.value);
    try bindInt64(mutation_stmt, 5, mutation.timestamp.wall);
    try bindInt64(mutation_stmt, 6, mutation.timestamp.logical);
    try bindInt64(mutation_stmt, 7, mutation.timestamp.node_id);
    try bindInt64(mutation_stmt, 8, mutation.cause.cause);
    try bindInt64(mutation_stmt, 9, mutation.cause.entity);
    try bindText(mutation_stmt, 10, mutation.cause.node);
    try self.step(mutation_stmt);

    const dirty_stmt = try self.prepare(
        "INSERT INTO pending_dirty (namespace, entity_id, component_id) VALUES (?, ?, ?);",
    );
    defer self.finalize(dirty_stmt);
    try bindText(dirty_stmt, 1, mutation.namespace);
    try bindInt64(dirty_stmt, 2, mutation.entity);
    try bindInt64(dirty_stmt, 3, mutation.component);
    try self.step(dirty_stmt);

    try self.exec("COMMIT;");
    committed = true;
    return true;
}

/// Returns the oldest unacknowledged dirty entry. The caller owns the namespace.
pub fn nextPendingDirty(self: *Storage) !?PendingDirty {
    const stmt = try self.prepare(
        "SELECT id, namespace, entity_id, component_id FROM pending_dirty ORDER BY id LIMIT 1;",
    );
    defer self.finalize(stmt);

    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite_done) return null;
    if (rc != sqlite_row) return self.sqliteError();

    const namespace_bytes = sqlite.sqlite3_column_blob(stmt, 1) orelse return error.SqliteInvalidRow;
    const namespace_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
    const namespace = try self.allocator.dupe(u8, @as([*]const u8, @ptrCast(namespace_bytes))[0..namespace_len]);
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .namespace = namespace,
        .entity = @intCast(sqlite.sqlite3_column_int64(stmt, 2)),
        .component = @intCast(sqlite.sqlite3_column_int64(stmt, 3)),
    };
}

/// Acknowledges work after the inference step has completed successfully.
pub fn acknowledgeDirty(self: *Storage, id: i64) !void {
    const stmt = try self.prepare("DELETE FROM pending_dirty WHERE id = ?;");
    defer self.finalize(stmt);
    try bindInt64(stmt, 1, id);
    try self.step(stmt);
}

pub fn pendingDirtyCount(self: *Storage) !u64 {
    const stmt = try self.prepare("SELECT COUNT(*) FROM pending_dirty;");
    defer self.finalize(stmt);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite_row) return self.sqliteError();
    return @intCast(sqlite.sqlite3_column_int64(stmt, 0));
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
    var storage = try Storage.open(std.testing.allocator, ":memory:");
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
    var storage = try Storage.open(std.testing.allocator, ":memory:");
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
    var storage = try Storage.open(std.testing.allocator, ":memory:");
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

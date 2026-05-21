# MySQL

`zono.mysql` is a compact MySQL driver for apps that want a database helper
without adding a C client dependency. It uses `std.Io.net` streams, supports a
small connection pool, text queries, server-side prepared statements,
transactions, streaming row callbacks, server error details, and direct row
mapping into Zig structs.

```zig
var pool = try zono.mysql.Pool.init(allocator, runtime.io(), .{
    .host = "127.0.0.1",
    .port = 3306,
    .database = "app",
    .user = "app",
    .password = "secret",
    .pool_size = 4,
});
defer pool.deinit();
```

## Queries

Use `queryAll()` for many rows and `queryOne()` for an optional single row:

```zig
const User = struct {
    id: u64,
    email: []const u8,
    active: bool,
};

const users = try pool.queryAll(
    User,
    "SELECT id, email, active FROM users WHERE active = ?",
    .{true},
);
defer pool.deinitAll(User, users);

var maybe_user = try pool.queryOne(
    User,
    "SELECT id, email, active FROM users WHERE id = ?",
    .{42},
);
defer if (maybe_user) |*user| pool.deinitValue(User, user);
```

Struct field names are matched to column names case-insensitively. Missing
optional fields become `null`; missing required fields return
`error.MissingColumn`. `NULL` values map to optional fields or return
`error.NullValue` for required fields.

The typed mapper supports booleans, integers, floats, byte slices, enums, and
the MySQL temporal helpers `zono.mysql.Date`, `zono.mysql.Time`, and
`zono.mysql.DateTime`. It also includes light wrappers for exact decimal, JSON,
and binary payloads: `zono.mysql.Decimal`, `zono.mysql.Json`, and
`zono.mysql.Blob`.

For single-column queries, use a scalar result type:

```zig
const ids = try pool.queryAll(u64, "SELECT id FROM users", .{});
```

When you want query-owned memory to live in a request arena, use the explicit
allocator variants: `queryAllAlloc()`, `queryOneAlloc()`, and `queryRowsAlloc()`.
The default query APIs use the pool or connection allocator, so ordinary call
sites do not need to pass an allocator on every query.

Use `forEach()` for large result sets. It maps and releases one row at a
time instead of materializing the whole result:

```zig
const Counter = struct {
    fn onUser(count: *usize, user: User) !void {
        _ = user;
        count.* += 1;
    }
};

var count: usize = 0;
try pool.forEach(
    User,
    "SELECT id, email, active FROM users",
    .{},
    &count,
    Counter.onUser,
);
```

## Writes

`executeVoid()` is for statements where success/failure is the only value you need:

```zig
try pool.executeVoid("DELETE FROM sessions WHERE expires_at < NOW()", .{});
```

Use `execute()` when you need affected rows or last insert id from the MySQL
OK packet:

```zig
const result = try pool.execute(
    "INSERT INTO users(email, active) VALUES (?, ?)",
    .{ "ada@example.com", true },
);
_ = result.last_insert_id;
```

## Prepared Statements

Use `prepare()` when a statement is reused or when you want binary parameter
binding instead of rendered SQL literals:

```zig
var stmt = try pool.prepare(
    "SELECT id, email, active FROM users WHERE active = ? AND created_at >= ?",
);
defer stmt.deinit();

const users = try stmt.queryAll(
    User,
    .{ true, zono.mysql.DateTime{ .year = 2026, .month = 1, .day = 1 } },
);
defer stmt.deinitAll(User, users);
```

Prepared parameters support `NULL`/optionals, bools, integers, floats, strings
or byte slices, enums, `zono.mysql.Date`, `zono.mysql.Time`,
`zono.mysql.DateTime`, `zono.mysql.Decimal`, `zono.mysql.Json`, and
`zono.mysql.Blob`.

Prepared statements also support `forEach()` for row-at-a-time mapping.
When prepared through a pool, the statement keeps one connection checked out
until `deinit()`/`close()`, because MySQL statement ids are scoped to a single
server connection.

## Reconnects

Pools keep an owned copy of the connection config. If a checked-out connection
has been closed by MySQL or the network, ordinary pool operations such as
`execute()`, `executeVoid()`, `queryRows()`, `queryAll()`, `queryOne()`,
`ping()`, and `prepare()` will
reconnect that slot and retry once.

Already-open transactions and prepared statement handles return the connection
error instead of reconnecting transparently, because their server-side state is
lost when the socket is gone.

## Transactions

Transactions keep one connection checked out until `commit()`, `rollback()`, or
`deinit()`:

```zig
var tx = try pool.transaction();
defer tx.deinit();

try tx.executeVoid("UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ 100, 1 });
try tx.executeVoid("UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ 100, 2 });
try tx.commit();
```

For short units of work, `transact()` handles rollback on callback errors and
commits only after the callback succeeds:

```zig
const Transfer = struct { from: u64, to: u64, amount: u64 };

try pool.transact(Transfer{ .from = 1, .to = 2, .amount = 100 }, struct {
    fn run(input: Transfer, tx: *zono.mysql.Transaction) !void {
        try tx.executeVoid("UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ input.amount, input.from });
        try tx.executeVoid("UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ input.amount, input.to });
    }
}.run);
```

## Raw Results

Use `queryRows()` when you want column metadata and string values:

```zig
var result = try pool.queryRows("SELECT * FROM users WHERE id = ?", .{42});
defer result.deinit();

for (result.rows) |row| {
    const email = row.get(&result, "email") orelse "";
    _ = email;
}
```

Use `forEachRow()` when you want the same row shape without storing the
full result set. The row values are valid only during the callback:

```zig
var count: usize = 0;
try pool.forEachRow("SELECT id, email FROM users", .{}, &count, struct {
    fn row(seen: *usize, result: *const zono.mysql.ResultSet, row_value: zono.mysql.Row) !void {
        const email = row_value.get(result, "email") orelse "";
        _ = email;
        seen.* += 1;
    }
}.row);
```

`queryOne()` maps the first row and drains the rest without materializing the
whole result set, so it is the preferred helper for single-row lookups.

## Error Details

When MySQL returns an error packet, the operation returns `error.ServerError`.
Use `errorDetail(err)` for logs, or `lastError()` when you need structured
fields:

```zig
pool.executeVoid("SELECT * FROM missing_table", .{}) catch |err| {
    std.log.err("{f}", .{pool.errorDetail(err)});
    return err;
};
```

`Connection`, `Pool`, `Statement`, and `Transaction` all expose
`errorDetail(err)` and `lastError()`. There is no module-level default pool;
keep an explicit `Pool` or `Connection` and read details from that handle.
Transactions created from a pool also copy server error details back to
`pool.lastError()`.

The pool retries once after reconnectable transport/protocol failures. If that
reconnect also fails, the checked-out connection is marked broken before it is
returned; the next acquire attempts to repair it before reuse instead of
silently handing out a known-bad socket.

For HTTP apps, register the pool as an observed error-detail source once and
let `zono.errorHandler(.{})` handle logging:

```zig
try app.errors.observe(&pool);
try app.onError(zono.errorHandler(.{}));
```

When a route returns `error.ServerError`, the handler logs the formatted MySQL
detail and returns a safe `500` JSON error:

```json
{ "code": "DATABASE_ERROR", "message": "Database error." }
```

`zono.mysql.ServerError` itself is format-aware, so structured details can be
logged directly:

```zig
if (pool.lastError()) |server| {
    std.log.err("{f}", .{server});
}
```

## Authentication

The driver supports `mysql_native_password` and the fast-authentication path of
MySQL 8 `caching_sha2_password`. If the server asks for full
`caching_sha2_password` authentication without TLS, the driver returns
`error.FullAuthenticationRequiresTls` instead of sending the password in clear
text.

## Debug Logs

In Debug builds, zio may print messages such as
`debug(zio): poll() timed out` when the event loop wakes without work. That is
runtime debug logging, not a MySQL driver error. Application executables can
hide it with:

```zig
pub const std_options: std.Options = .{ .log_level = .info };
```

# zono

`zono` is a small Zig HTTP/WebSocket toolkit.

The API is shaped after Hono: `App`, `Context`, route methods, middleware,
`app.fetch()`, `app.request()`, and response helpers such as `c.text()`,
`c.json()`, `c.html()`, `c.body()`, and `c.redirect()`.

The feature budget is closer to Hical: keep the server, router, middleware,
request/response helpers, streaming, SSE, file responses, errors, WebSocket
upgrades, and a tiny helper set for CORS, static files, and in-memory sessions.
Extra compatibility facades are kept out of the root API so the hot path stays
small.

## Core Surface

- `App` for routes, composition, middleware, `notFound()`, and `onError()`
- `Context` for Hono-style handlers and response helpers
- `Request` for params, query, headers, cookies, body parsing, and uploads
- `Response` for text, html, json, redirects, cookies, file responses,
  streaming, SSE, and inline storage for small header sets
- `Router` with a hash fast path for exact routes, plus `:param` segments
  and final `*catchAll` routes
- `Server` for the zio-backed HTTP/1.1 runtime, request-pool reuse, hard
  request-target limits, and connection write nodes
- `WebSocketConnection`, `app.ws()`, and `c.upgradeWebSocket()` for RFC 6455
  upgrades
- `cors()`, `serveStatic()`, `logger()`, `requestId()`, `session()`, and
  `sessionWithManager()` as focused core helpers
- `AppErrorDef`, `app.errors`, `app.errors.observe()`, and `errorHandler()`
  for lightweight JSON API error responses and detail logging
- `mysql` for a small zio/std.Io MySQL driver with pooling, escaped `?`
  parameters, prepared statements, transactions, raw result sets, and typed row
  mapping
- `HTTPException` for status/message errors

Removed from the public root surface: Fetch facade wrappers, proxy helpers,
validator handoff, typed/test clients, route manifests, TLS/HTTP2/compression
facades, and broad helper modules.

## Quick Start

Requirements: Zig `0.16.0`

```bash
zig build test
zig build examples
```

```zig
const std = @import("std");
const zono = @import("zono");

fn hello(c: *zono.Context) zono.Response {
    return c.text("hi");
}

pub fn main() !void {
    const runtime = try zono.ZioRuntime.init(std.heap.smp_allocator, .{});
    defer runtime.deinit();

    var app = zono.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/", hello);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080),
    });
    try server.serveZio(runtime, &app);
}
```

## Routing

```zig
try app.get("/users", listUsers);
try app.get("/users/:id", showUser);
try app.get("/assets/*path", serveAsset);
try app.ws("/ws", WsCallbacks);
try app.on(.{ .GET, .POST }, .{ "/a", "/b" }, handler);
try app.all("/raw", rawHandler);
```

Supported route shapes are intentionally simple: exact paths, named params,
and a trailing catch-all. Regex params, optional params, and middle wildcards
are outside the core router.

Apps compose through Hono-style methods:

```zig
var api = zono.App.init(allocator);
defer api.deinit();
try api.basePath("/v1");
try api.get("/users/:id", showUser);

var app = zono.App.init(allocator);
defer app.deinit();
try app.basePath("/api");
try app.route("/", &api);
```

## Middleware

```zig
fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    next.run();
    _ = c.header("x-powered-by", "zono");
    return c.takeResponse();
}

try app.use(poweredBy);
try app.useAt("/admin", requireApiKey);
try app.post("/posts", .{ requireApiKey, createPost });
```

Use `c.set()` / `c.get()` for per-request typed state. Built-in helper
coverage is deliberately limited to `cors()`, `serveStatic()`, and
`session()`.

```zig
try app.use(zono.cors(.{}));
try app.use(zono.requestId(.{}));
try app.use(zono.logger(.{}));
try app.use(zono.serveStatic(.{ .root = "public", .prefix = "/assets" }));
try app.use(zono.serveStatic(.{ .root = "dist", .spa_fallback = "index.html" }));
try app.use(zono.session(.{ .cookie_name = "sid" }));
```

Use an explicit manager when you need to share or inspect the in-memory store:

```zig
var sessions = zono.SessionManager.init(allocator, .{ .cookie_name = "sid" });
defer sessions.deinit();
try app.use(zono.sessionWithManager(&sessions));
```

Direct `SessionManager.find()`, `create()`, and `regenerate()` calls return a
retained session pointer. Call `sessions.release(session)` when the direct use is
finished. The `session()` middleware handles this automatically for request
sessions.

## Request And Response

```zig
fn search(c: *zono.Context) !zono.Response {
    var query = try c.req.queryAll();
    defer query.deinit();

    return c.json(.{
        .q = query.value("q") orelse "",
        .page = c.req.query("page") orelse "1",
    });
}

fn created(c: *zono.Context) zono.Response {
    return c.text(.{ "created", .created });
}
```

For large bodies, use `c.bodyReader()`, `c.saveBodyToFile()`, or
`c.req.saveMultipartToDir()` instead of materializing everything first.

## MySQL

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

var user = try pool.queryOne(
    User,
    "SELECT id, email, active FROM users WHERE id = ?",
    .{42},
);
defer if (user) |*value| pool.deinitValue(User, value);
_ = user;
```

`zono.mysql` speaks MySQL over `std.Io.net.Stream`. It supports text queries,
server-side prepared statements, transactions, `executeVoid()` for no-result
writes, row-at-a-time `forEach()`, typed temporal/decimal/json/blob values,
row result sets, server error details, pool reconnects for stale sockets,
`mysql_native_password`, and the fast path for MySQL 8 `caching_sha2_password`;
full clear-password/RSA authentication without TLS is rejected instead of
sending credentials insecurely.

## WebSocket

```zig
const WsCallbacks = struct {
    fn onMessage(socket: *zono.WebSocketConnection, message: zono.WebSocketMessage) !void {
        if (message.opcode == .text) try socket.writeText(message.data);
    }
};

try app.ws("/ws", WsCallbacks);

// Lower-level form when you want the upgrade inside a normal handler.
fn ws(c: *zono.Context) zono.Response {
    return c.upgradeWebSocket(zono.webSocketHandler(WsCallbacks), .{});
}
```

Long-lived WebSocket servers should use `request_timeout_ms = 0`.

## Testing

```zig
test "search route" {
    var app = zono.App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("zig", res.body);
}
```

`app.request()` covers ordinary HTTP handlers. Test WebSocket routes through
`Server` with an external or integration WebSocket client.

Response headers stay inline for small sets; overflow needs an owned response
or a header allocator. `Context` response helpers automatically use the
request allocator.

## Docs

- [Routing & composition](./docs/routing.md)
- [Context responses](./docs/context.md)
- [Request parsing](./docs/request.md)
- [Large uploads](./docs/upload.md)
- [Migration notes](./docs/migration.md)
- [Middleware](./docs/middleware.md)
- [Core helpers](./docs/helpers.md)
- [MySQL](./docs/mysql.md)
- [Hooks](./docs/hooks.md)
- [HTTPException](./docs/http-exception.md)
- [Streaming & SSE](./docs/streaming.md)
- [Server](./docs/server.md)
- [WebSocket](./docs/websocket.md)

## Benchmark

CI benchmarks compare `zono` `examples/benchmark.zig` on `GET /api/json`
with a trimmed `merjs` starter-style baseline, then run a zono feature matrix
covering common HTTP helpers and routing paths.

# Core Helpers

zono keeps the root API small, but ships focused Hono-style helpers that map
to common server features without adding broad compatibility packages:

- `zono.cors(...)`
- `zono.serveStatic(...)`
- `zono.logger(...)`
- `zono.requestId(...)`
- `zono.session(...)`
- `zono.sessionWithManager(...)`

Each helper returns an ordinary middleware function, so it can be registered
with `use()`, `useAt()`, `useOn()`, or route-level middleware tuples.

## CORS

```zig
try app.use(zono.cors(.{
    .origin = &.{ "https://app.example", "https://admin.example" },
    .allow_methods = &.{ "GET", "POST", "OPTIONS" },
    .allow_headers = &.{ "Content-Type", "Authorization" },
    .expose_headers = &.{"X-Request-Id"},
    .credentials = true,
    .max_age = 600,
}));
```

Preflight `OPTIONS` requests with `Access-Control-Request-Method` are answered
directly with `204 No Content`. Normal requests run downstream first, then CORS
headers are applied to the response. When `allow_headers` is empty, preflight
responses reflect `Access-Control-Request-Headers`.

## Static Files

```zig
try app.use(zono.serveStatic(.{
    .root = "public",
    .prefix = "/assets",
    .cache_control = "public, max-age=3600",
    .max_file_bytes = 16 * 1024 * 1024,
}));
```

`serveStatic` resolves paths under `root`, strips an optional URL `prefix`,
serves `index.html` for directory-like paths, rejects unsafe paths (`..`,
absolute paths, backslashes, and drive-style `:` paths), caps file size, and
adds a weak `ETag`, `Last-Modified`, and `Accept-Ranges: bytes`. It handles
`If-None-Match`, `If-Modified-Since`, single byte ranges, suffix ranges, and
`416 Range Not Satisfiable` with `Content-Range`. It returns zono's file
response, so `Server` streams from disk through the connection write queue
instead of reading the whole file into memory.

Use `.fallthrough = false` when a static miss should return `404` immediately
instead of letting downstream routes handle the request.

For frontend bundles with history routing, enable SPA fallback in the same
helper:

```zig
try app.use(zono.serveStatic(.{
    .root = "dist",
    .spa_fallback = "index.html",
    .cache_control = "public, max-age=31536000, immutable",
    .spa_fallback_cache_control = "no-cache",
}));
```

Static files are still served first. If a file is missing, downstream routes
run next; only a `GET`/`HEAD` `404` navigation that accepts HTML and has no
file extension falls back to `index.html`. That keeps API 404s and missing
assets like `/app.js` from accidentally returning the frontend shell.

## Observability

`requestId()` mirrors Hono's request-id middleware shape. It reuses an incoming
`X-Request-Id` when present, otherwise generates an id, stores it under
`zono.requestIdContextKey`, and writes the response header:

```zig
try app.use(zono.requestId(.{}));

fn handler(c: *zono.Context) zono.Response {
    return c.text(c.get([]const u8, zono.requestIdContextKey) orelse "missing");
}
```

Use `logger()` for a tiny request/response log middleware. It records method,
status, elapsed time, request id when one has been set, and path. The default
log line keeps short fields first and leaves variable-length fields such as
`path=` and `body=` at the end:

```zig
try app.use(zono.requestId(.{}));
try app.use(zono.logger(.{}));
```

Both helpers accept option structs. `requestId(.{ .header_name = "X-Correlation-Id" })`
changes the request id header, and `logger(.{ .print = myPrint })` redirects
log entries to your own sink.

Enable request body logging explicitly when needed:

```zig
try app.use(zono.logger(.{
    .include_request_body = true,
    .request_body_max_bytes = 4096,
}));
```

The logger only prints buffered request bodies. It does not read live streaming
bodies, so enabling this option does not consume body readers before handlers
run. Body logs stay on one line by folding control characters such as newlines
and tabs into spaces.

## Sessions

```zig
try app.use(zono.session(.{
    .cookie_name = "sid",
    .max_age_seconds = 3600,
    .max_sessions = 10_000,
    .secure = false, // local HTTP only
}));

fn profile(c: *zono.Context) !zono.Response {
    const s = c.get(*zono.Session, zono.sessionContextKey) orelse
        return zono.internalError("session missing");

    try s.set("user_id", "42");
    return c.text(s.get([]const u8, "user_id") orelse "missing");
}
```

Sessions are in-memory and process-local. The cookie stores only the session
id; values live in the server-side `SessionManager`, expire lazily, and are
bounded by `max_sessions`. String-like values are copied into the session
store, while other values are stored by value.

Use `sessionWithManager()` when the app should own the manager explicitly, for
example to share one store across composed apps or inspect session count in
tests:

```zig
var sessions = zono.SessionManager.init(allocator, .{
    .cookie_name = "sid",
    .secure = false,
});
defer sessions.deinit();

try app.use(zono.sessionWithManager(&sessions));
```

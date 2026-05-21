# Server

`zono.Server` is the built-in HTTP/1.1 runtime. It is written against
Zig 0.16 `std.Io`, and the default path is to drive it with zio via
`serveZio`. It binds a listening socket, accepts connections, drives the
request/response loop, and hands each request through your `App`.

TLS, HTTP/2, and compression are intentionally outside this runtime. Deploy
zono behind a front proxy such as Nginx when you need those edge concerns.

## Lifecycle

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    const runtime = try zono.ZioRuntime.init(std.heap.smp_allocator, .{});
    defer runtime.deinit();

    var app = zono.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/", struct {
        fn run(c: *zono.Context) zono.Response { return c.text("hi"); }
    }.run);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080),
    });
    try server.serveZio(runtime, &app);
}
```

`serveZio` runs the same server loop on a `zio.Runtime`; `serve`
remains available when you already have another `std.Io` implementation.
Both run until either the accept loop fails or a stop request is observed.

## Options

```zig
pub const Options = struct {
    /// Allocator used for connection buffers, request arenas, and temporary
    /// response header storage.
    allocator: std.mem.Allocator = std.heap.smp_allocator,

    address: std.Io.net.IpAddress,
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 64 * 1024,

    /// Maximum bytes accepted in a single request body. Requests
    /// exceeding this limit receive `413 Payload Too Large` and the
    /// connection is closed (no follow-up keep-alive request).
    max_body_bytes: usize = 4 * 1024 * 1024,

    /// Maximum body bytes to materialize into Request.bodyBytes() before
    /// dispatch. Larger bodies are exposed through Request.bodyReader().
    /// Set to 0 to stream every request body.
    body_buffer_bytes: usize = 4 * 1024 * 1024,

    /// Buffer handed to streaming/SSE writers. Larger values reduce
    /// syscalls; smaller values lower latency for chatty event streams.
    stream_buffer_size: usize = 8 * 1024,

    /// Maximum concurrently accepted connections. `0` means unlimited.
    max_connections: usize = 0,

    /// Maximum in-memory bytes queued for one response before the connection
    /// applies backpressure and closes with 503. `0` disables this check.
    max_write_queue_bytes: usize = 16 * 1024 * 1024,

    /// Idle keep-alive read deadline between completed requests. `0`
    /// disables the idle deadline while still honoring per-request deadlines.
    idle_timeout_ms: u64 = 75_000,

    /// Maximum requests served on one keep-alive connection. `0` is unlimited.
    max_keep_alive_requests: usize = 0,

    /// Maximum header fields accepted before dispatch. 0 disables this
    /// count check, but the parser's read buffer limit still applies.
    max_request_headers: usize = 64,

    /// Maximum summed header name/value bytes accepted before dispatch.
    /// 0 disables this byte check, but read_buffer_size still caps the
    /// parsed header block.
    max_request_header_bytes: usize = 16 * 1024,

    /// Maximum request-target bytes (`path?query`) accepted before dispatch.
    max_request_target_bytes: usize = 8 * 1024,

    /// Maximum query string bytes accepted before dispatch.
    max_query_bytes: usize = 16 * 1024,

    /// Maximum slash-delimited path segments accepted before dispatch.
    max_path_segments: usize = 64,

    /// Request-level arena capacity retained between keep-alive requests.
    /// Set to `0` to free all request-pool memory after every request.
    request_pool_retain_bytes: usize = 64 * 1024,

    /// Per-request wall-clock deadline (milliseconds). Includes header
    /// parse, body read, handler execution, and body write. `0` disables.
    request_timeout_ms: u64 = 30_000,

    /// On `Server.stop`, wait this long for in-flight connections to
    /// finish before forcibly canceling them. `0` cancels immediately.
    shutdown_drain_ms: u64 = 5_000,
};
```

### Body buffering and upload limits

`max_body_bytes` is the hard per-request limit. The server returns `413
Payload Too Large` when the declared `Content-Length` exceeds it, or when
a chunked/live body crosses it while being read or drained.

`body_buffer_bytes` controls memory shape:

- default: buffer up to 4 MiB, matching the default `max_body_bytes`, so
  `bodyBytes()`, `text()`, `json(T)`, and `formData()` use the buffered
  path.
- `0`: never prebuffer; use `c.bodyReader()` or `c.saveBodyToFile()`.
- smaller than `max_body_bytes`: small bodies stay allocation-friendly,
  larger bodies stream through the live reader.

If a handler returns without consuming a live body, zono drains the
remaining bytes before writing the response. That keeps HTTP/1.1
keep-alive framing correct while still enforcing `max_body_bytes`.

### Request pool and target limits

Each keep-alive connection owns a request-level arena. The arena is reset
before every request and retained up to `request_pool_retain_bytes`, giving
the hot path Hical-style monotonic allocation without letting one large
request pin memory for the lifetime of the connection.

The server also rejects oversized headers and request targets before body
handling:

- `max_request_headers` limits header field count.
- `max_request_header_bytes` limits summed header name/value bytes.
- `max_request_target_bytes` limits the full `path?query`.
- `max_query_bytes` limits just the query string.
- `max_path_segments` limits slash-delimited path segments.

Exceeded header limits return `431 Request Header Fields Too Large`.
Exceeded target limits return `414 URI Too Long`. Both paths close the
connection.

### Connection resource limits

`max_connections` is a process-local hard cap for accepted connections. When
the cap is reached, the newly accepted connection receives `503 Service
Unavailable` and is closed before handler dispatch. Use
`server.connectionCount()` when you need a cheap live gauge for tests or
metrics.

`idle_timeout_ms` applies only while a keep-alive connection is waiting for the
next request. It does not shorten an in-flight request; use
`request_timeout_ms` for that. `max_keep_alive_requests` retires a connection
after it has served the configured number of requests, which is useful when you
want predictable per-connection memory and socket lifetimes under load.

Idle deadlines use the server's timed-read path. On backends that cannot
interrupt a blocking read, this option is retained in configuration but cannot
force the waiting read to return.

### Connection write queue

Responses are lowered into connection write nodes before delivery:
buffered memory, streams, SSE, files, and WebSocket upgrades each have a
dedicated node. File responses use a `FileWriteNode` so the connection layer
opens, stats, and streams the file without materializing it in memory.
Small response header sets are stored inline on `Response`. Overflow uses
`header_allocator` or an owned response; `Context` response helpers provide
the request allocator automatically.

`max_write_queue_bytes` is checked before draining a response. Buffered memory
bodies count against the limit; streaming, SSE, file, and WebSocket nodes stay
zero-copy at this layer and do not count as queued memory. When a buffered
response exceeds the high-water mark, zono returns `503 Service Unavailable`
and closes the connection.

### `request_timeout_ms` and long-lived handlers

The default deadline (30s) is fine for ordinary request/response.
Streaming, SSE, and WebSocket handlers can run for minutes or hours
and **must** be configured explicitly:

- For long streams set `request_timeout_ms = 0` and rely on the
  writer's `isAborted()` to drop work when the peer goes away (see
  [streaming.md](./streaming.md)).
- For WebSocket-heavy services set `request_timeout_ms = 0`, then use
  WebSocket `idle_timeout_ms` / `heartbeat_interval_ms` on the route options.

If you need both short HTTP timeouts and long-lived WebSocket sessions,
run two `Server` instances bound to different ports, each with their
own deadline.

## Stopping cleanly

`Server.requestStop()` is the atomic-only, signal-handler-safe path.
`Server.stop(io)` requests stop and best-effort wakes a blocking `accept`.

From a signal handler, call `requestStop()`. From normal execution, call
`stop(io)` to request shutdown and wake the server if it is blocked.

```zig
// In a SIGINT/SIGTERM handler.
server.requestStop();

// Later, from normal execution:
try server.stop(io);
```

`shutdown_drain_ms` controls how long `serve` waits for in-flight
handlers after the loop breaks. After the budget elapses, remaining
handlers are canceled.

## Reading the bound port

When you bind to port `0` (ephemeral), use `server.bound_port` after
`serve` has had a moment to bind:

```zig
// On a worker thread that's running `serve`.
const port = server.bound_port.load(.acquire);
```

Useful for tests that need to know which port to connect to.

# Streaming & SSE

zono supports two streaming response shapes:

- `c.stream(content_type, runFn, options)` — arbitrary chunked bodies.
- `c.sse(runFn)` — `text/event-stream` with framing helpers.
- `c.streamText(runFn, options)` / `zono.streamText(c, runFn, options)` —
  text streaming convenience.
- `c.streamSSE(runFn)` / `zono.streamSSE(c, runFn)` — SSE convenience alias.

Both share the same lifecycle: your handler returns immediately, and
the server invokes your callback later during response write. The
handler-returned `Response` keeps `*Context` alive for the response.

Live request bodies are single-consumption. Before a streaming/SSE
callback runs, the server drains any remaining live body. If the
callback needs request data, consume, clone, or save it before
returning the streaming response.

## `stream`

```zig
fn ndjson(c: *zono.Context) zono.Response {
    return c.stream("application/x-ndjson", struct {
        fn run(w: *zono.StreamWriter) !void {
            for (0..10) |i| {
                if (w.isAborted()) return;
                try w.print("{{\"i\":{d}}}\n", .{i});
                try w.flush();
            }
        }
    }.run, .{});
}
```

`StreamWriter` is a thin facade over `std.Io.Writer`:

```zig
pub fn write(self: *StreamWriter, bytes: []const u8) !usize;
pub fn writeAll(self: *StreamWriter, bytes: []const u8) !void;
pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) !void;
pub fn pipeFrom(self: *StreamWriter, reader: *std.Io.Reader, max_bytes: ?usize) !usize;
pub fn flush(self: *StreamWriter) !void;
pub fn isAborted(self: *const StreamWriter) bool;  // poll between chunks
pub fn writer(self: *StreamWriter) *std.Io.Writer; // escape hatch
```

`isAborted()` flips to `true` when the peer closed or the server is
shutting down. Polling it between chunks lets long streams cooperate
with shutdown without surfacing transport errors.

## `StreamOptions`

```zig
pub const StreamOptions = struct {
    /// When set, the response advertises `Content-Length` instead of
    /// `Transfer-Encoding: chunked`. Use this when the total body size
    /// is known ahead of time — it slightly reduces framing overhead
    /// and lets HTTP/1.0 clients without chunked support consume the
    /// stream.
    content_length: ?u64 = null,
};
```

Default (`null`) emits chunked encoding, which is usually what you
want for genuine streams.

## Server-sent events

```zig
fn sseRoute(c: *zono.Context) zono.Response {
    return c.streamSSE(struct {
        fn run(sse: *zono.SseWriter) !void {
            var i: u64 = 0;
            while (!sse.isAborted()) : (i += 1) {
                try sse.send(.{
                    .event = "tick",
                    .id = std.fmt.allocPrint(allocator, "{d}", .{i}) catch return,
                    .data = "hello",
                });
                try sse.flush();
                std.time.sleep(1 * std.time.ns_per_s);
            }
        }
    }.run);
}
```

`SseEvent` mirrors the EventSource spec:

```zig
pub const SseEvent = struct {
    event: ?[]const u8 = null,    // event: <name>
    id: ?[]const u8 = null,       // id: <id>
    retry_ms: ?u64 = null,        // retry: <ms>
    data: []const u8 = "",        // data: <line>\n (handles embedded \n)
};
```

`SseWriter.comment(text)` emits `: text\n` — useful as a keep-alive
ping when no real event is ready. `sendText(data)` and
`sendNamed(event, data)` are short aliases for the common cases.

## Server config

For long-lived streams, raise or disable the per-request deadline:

```zig
var srv = zono.Server.init(.{
    .address = addr,
    .request_timeout_ms = 0,        // no deadline; rely on isAborted()
    .stream_buffer_size = 16 * 1024,
});
```

See [server.md](./server.md) for the full options struct.

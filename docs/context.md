# Context responses

`zono.Context` keeps Hono's response helper shape where Zig can express
it directly. Text and HTML helpers accept either plain content or a
tuple/struct with response options:

```zig
fn text(c: *zono.Context) zono.Response {
    const headers = &[_]std.http.Header{
        .{ .name = "x-message", .value = "created" },
    };

    return c.text(.{ "created", .created, headers });
}

fn html(c: *zono.Context) zono.Response {
    return c.html(.{
        .content = "<strong>ok</strong>",
        .status = .accepted,
        .headers = &[_]std.http.Header{
            .{ .name = "x-view", .value = "detail" },
        },
    });
}
```

`body()` is the raw response helper. It defaults to no content type,
matching raw body semantics; pass a content type as an option when you
want one:

```zig
fn raw(c: *zono.Context) zono.Response {
    return c.body(.{ "raw", .created, "application/custom" });
}

fn rawStruct(c: *zono.Context) zono.Response {
    return c.body(.{
        .content = "raw",
        .content_type = "application/custom",
        .status = .created,
    });
}
```

The public response helpers are intentionally single-argument. Prefer
tuple or struct options instead of compatibility-style multi-argument
methods:

```zig
return c.body(.{ "raw", "application/custom" });
```

## Request body access

`c.bodyReader()` is the live-aware body reader. It replays buffered bodies
and streams large bodies when `Server.Options.body_buffer_bytes` is below
the request size:

```zig
fn upload(c: *zono.Context) zono.Response {
    const written = c.saveBodyToFile("upload.bin", .{
        .max_bytes = 512 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
        else => return c.text(.{ "upload failed", .internal_server_error }),
    };
    return c.json(.{ .bytes = written });
}
```

Use `c.isAborted()` in long-running handlers to observe peer disconnects,
body limit aborts, and request deadlines.

Request path, header, body, and param slices are only valid for the
request/response lifetime. Clone anything you need in background work or
global storage. `c.set()` stores string-like values as slices, not deep
copies; clone unstable memory to `c.req.allocator` first.

Borrowed response headers are inline for small sets. If you exceed the
inline capacity outside `Context` helpers, use `header_allocator` or an
owned response.

## Connection info

`c.connInfo()` exposes the local and remote socket addresses when the built-in
server handled the request. In `App.request` tests, pass `.conn_info` in
`App.RequestOptions` when a handler needs it.

```zig
fn who(c: *zono.Context) zono.Response {
    const info = c.connInfo();
    return c.json(.{ .has_remote = info.remote != null });
}
```

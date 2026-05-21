# Migration notes

## Response helpers

zono response helpers use the single-argument style:

```zig
return c.body(.{ "raw", .created, "application/custom" });
return c.text(.{ "created", .created });
return c.json(.{ .{ .ok = true }, .accepted });
```

The older compatibility helpers and multi-argument response forms are not
part of the public API. Prefer tuples or named fields:

```zig
return c.body(.{
    .content = "raw",
    .status = .created,
    .content_type = "application/custom",
});
```

## Query access

Use the explicit aggregate helpers where Hono would use a no-argument
overload:

```zig
const q = c.req.query("q");              // raw zero-copy value
const decoded = try c.req.queryDecoded("q");
var all = try c.req.queryAll();          // decoded aggregate
var repeated = try c.req.queriesDecoded("tag");
```

## Body access

Request body helpers now follow Hono's shape more closely. Use `json(T)` for
the high-level JSON value and `bodyBytes()` only when you need raw buffered
bytes:

```zig
const body = try c.req.json(types.CreateUser);
const raw = c.req.bodyBytes();
const text = c.req.text();
var form = try c.req.formData();
defer form.deinit();
```

The older `json(T) -> ?std.json.Parsed(T)` behavior moved to
`jsonParsed(T)`:

```zig
var parsed = try c.req.jsonParsed(types.CreateUser);
defer if (parsed) |*value| value.deinit();
```

For endpoints that may receive large bodies, move to `bodyReader()`:

```zig
fn upload(c: *zono.Context) zono.Response {
    var reader = c.bodyReader();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
            else => return c.text(.{ "upload failed", .internal_server_error }),
        };
        if (n == 0) break;
    }
    return c.text("ok");
}
```

Configure the server so large bodies are not prebuffered:

```zig
var server = zono.Server.init(.{
    .address = addr,
    .max_body_bytes = 512 * 1024 * 1024,
    .body_buffer_bytes = 0,
});
```

Raw upload endpoints can use `c.saveBodyToFile()`:

```zig
const bytes = try c.saveBodyToFile("upload.bin", .{
    .max_bytes = 512 * 1024 * 1024,
});
```

`formData()` remains the buffered multipart/urlencoded parser. Use it for
normal forms; use a raw streaming endpoint for large files.

## Cancellation checks

Long handlers should poll:

```zig
if (c.isAborted()) return c.text(.{ "request aborted", .request_timeout });
```

This covers peer disconnects observed by the server, streaming body limit
failures, and request deadlines. Response streams still use
`StreamWriter.isAborted()` / `SseWriter.isAborted()` inside the stream
callback.

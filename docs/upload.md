# Large uploads

zono has two request-body paths:

- buffered: small bodies are available through `c.req.bodyBytes()`,
  `c.req.text()`, `c.req.json(T)`, `c.req.formData()`, etc.
- streaming: large or explicitly unbuffered bodies are read through
  `c.bodyReader()` without materializing the whole payload.

The server defaults to buffered behavior for compatibility:

```zig
var server = zono.Server.init(.{
    .address = addr,
    .max_body_bytes = 4 * 1024 * 1024,
    .body_buffer_bytes = 4 * 1024 * 1024,
});
```

For upload endpoints, lower the buffering threshold:

```zig
var server = zono.Server.init(.{
    .address = addr,
    .max_body_bytes = 512 * 1024 * 1024,
    .body_buffer_bytes = 0,
    .request_timeout_ms = 0,
});
```

## Stream the body

```zig
fn upload(c: *zono.Context) zono.Response {
    var reader = c.bodyReader();
    var total: usize = 0;
    var buf: [128 * 1024]u8 = undefined;

    while (true) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
            else => return c.text(.{ "upload failed", .internal_server_error }),
        };
        if (n == 0) break;
        total += n;

        if (c.isAborted()) {
            return c.text(.{ "request aborted", .request_timeout });
        }
    }

    return c.json(.{ .bytes = total });
}
```

`bodyReader()` also works when the body was buffered, so shared helpers do
not need two paths.

## Save raw uploads

For a raw upload endpoint, let zono stream directly into a file:

```zig
fn uploadRaw(c: *zono.Context) zono.Response {
    const written = c.saveBodyToFile("upload.bin", .{
        .max_bytes = 512 * 1024 * 1024,
        .buffer_size = 128 * 1024,
    }) catch |err| switch (err) {
        error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
        else => return c.text(.{ "upload failed", .internal_server_error }),
    };

    return c.json(.{ .ok = true, .bytes = written });
}
```

`saveBodyToFile()` requires the built-in server path because it uses the
request's live `std.Io`. Unit tests that call `app.request()` directly can
use `c.req.saveBodyToFileIo(io, path, options)` when they provide an
explicit `std.Io`.

## Multipart forms

`formData()` and `parseBody()` remain buffered form parsers. They are the
right fit for normal browser forms and small multipart payloads.

For large browser uploads, stream file parts directly to disk:

```zig
fn uploadForm(c: *zono.Context) zono.Response {
    var saved = c.req.saveMultipartToDir("uploads", .{
        .max_file_bytes = 512 * 1024 * 1024,
        .file_buffer_size = 128 * 1024,
    }) catch |err| switch (err) {
        error.MultipartFileTooLarge => return c.text(.{ "file too large", .payload_too_large }),
        else => return c.text(.{ "upload failed", .internal_server_error }),
    };
    defer saved.deinit();

    return c.json(.{
        .fields = saved.fields.len,
        .files = saved.files.len,
    });
}
```

`saveMultipartToDir()` uses the request's live `std.Io`. It writes file
parts as `{index}-{sanitized filename}` under the target directory,
captures text fields up to `max_field_bytes`, and returns paths plus
metadata. File bodies are scanned with a byte-level multipart boundary
scanner, so binary payloads and long chunks without newlines are fine.
`max_line_bytes` only caps multipart preamble/header lines. Tests can use
`saveMultipartToDirIo(io, dir, options)` with an explicit runtime.

## Lifecycle

If a handler does not consume a live body, zono drains the unread bytes
before writing the response. This preserves HTTP/1.1 keep-alive framing
and still enforces `max_body_bytes`.

`c.isAborted()` becomes true when the peer disconnects, a streaming body
crosses its size limit, or the request deadline has elapsed. Poll it in
long uploads and other long-running handlers.

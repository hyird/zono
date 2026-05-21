# HTTPException

`HTTPException` is zono's Zig-shaped equivalent of Hono's
`HTTPException`. Since Zig errors do not carry payloads, the exception
is stored on the request `Context` and the handler returns the sentinel
`error.HTTPException` through `raise(c)`.

## Status and message

```zig
fn private(c: *zono.Context) !zono.Response {
    return zono.HTTPException.init(.unauthorized, .{
        .message = "Unauthorized",
    }).raise(c);
}
```

Without a custom `onError`, zono returns the exception response
directly. If no message is supplied, the status phrase is used.

## Custom response

```zig
fn private(c: *zono.Context) !zono.Response {
    var res = zono.text(.ok, "Unauthorized");
    _ = res.header("www-authenticate", "Bearer");

    return zono.HTTPException.init(.unauthorized, .{
        .res = res,
    }).raise(c);
}
```

Like Hono, the constructor status is applied to the response generated
from the exception.

## `onError`

```zig
try app.onError(struct {
    fn run(_: anyerror, c: *zono.Context) zono.Response {
        if (c.httpException()) |exception| {
            return exception.getResponse(c.req.allocator);
        }
        return c.text(.{ "Internal Server Error", .internal_server_error });
    }
}.run);
```

`c.httpException()` is the Zig equivalent of checking
`err instanceof HTTPException` in Hono. If your `onError` handler itself
fails, zono keeps the existing reentry guard and falls back to a static
`500 Internal Server Error`.

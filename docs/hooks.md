# Hooks

Two app-level hooks let you customise the unhappy paths:

- `try app.notFound(handler)` — when no route matches.
- `try app.onError(handler)` — when a fallible handler returns an error
  (handler signature `fn(...) !Response`) **or** when an error escapes
  middleware.

Both are optional. Without them you get framework defaults: a plain
404 and a plain 500 respectively. `zono.HTTPException` is the exception:
without a custom `onError`, it renders its own status/message response.

## `notFound`

```zig
try app.notFound(struct {
    fn run(c: *zono.Context) zono.Response {
        return c.json(.{ .{ .error = "no such route" }, .not_found });
    }
}.run);
```

The handler receives the same `*Context` your normal handlers do, so
you can read headers, set custom status codes, or return JSON — exactly
like a regular route.

## `onError`

```zig
try app.onError(struct {
    fn run(err: anyerror, c: *zono.Context) zono.Response {
        return c.text(.{ @errorName(err), .bad_request });
    }
}.run);

try app.get("/posts/:id", struct {
    fn run(_: *zono.Context) !zono.Response {
        return error.InvalidPostId;     // -> onError -> 400 InvalidPostId
    }
}.run);
```

`HTTPException` can be inspected inside `onError`, matching Hono's
`err instanceof HTTPException` pattern:

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

## App Errors

For the common JSON API case, register application error definitions and use
the built-in error handler:

```zig
try app.errors.register(zono.AppErrorDef{
    .err = error.PermissionDenied,
    .status = .forbidden,
    .code = "PERMISSION_DENIED",
    .message = "Permission denied.",
});

try app.onError(zono.errorHandler(.{}));
```

`app.errors.register(...)` accepts one `zono.AppErrorDef`, a tuple, a slice or
array, or a zero-argument factory returning those. Request helper errors such
as `error.InvalidRequestBody`, `error.MissingQuery`, and `error.InvalidParam`
have built-in definitions, so `zono.errorHandler(.{})` can turn them into JSON
without each project writing the same switch.

The JSON shape is:

```json
{ "code": "PERMISSION_DENIED", "message": "Permission denied." }
```

Unknown errors become `500` JSON responses. Use
`zono.errorHandler(.{ .expose_internal_errors = true })` in local development
when you want the raw Zig error name in the response body.

Error detail sources can also be observed once and picked up by the same
handler. For MySQL pools this means server errno, SQLSTATE, and message are
logged automatically while clients still receive a safe generic response:

```zig
try app.errors.observe(&pool);
try app.onError(zono.errorHandler(.{}));
```

Any observed source needs to provide `errorDetail(err: anyerror)` returning a
format-aware value. If the detail value has `hasDetail()`, false means “ignore
this source for this error”.

Two signatures are accepted:

- `fn(anyerror, *zono.Context) zono.Response` — total. Most common.
- `fn(anyerror, *zono.Context) !zono.Response` — fallible. If your
  error handler itself fails, the framework falls back to a static
  `500 Internal Server Error` body.

### Reentry guard

If your `onError` handler itself errors, zono will **not** call it
again recursively. A flag on the per-request shared state short-circuits
nested errors to the static 500 fallback. This means you can return
`error.Foo` from inside `onError` without worrying about an infinite
loop — but the response the client sees won't be the one you tried to
build.

In practice you almost always want the total signature; reserve the
`!Response` form for cases where the response builder allocates and
allocation failure is meaningful to the caller.

## What counts as an error

- Handlers declared as `fn(...) !zono.Response` returning `error.X`.
- Middleware returning `zono.internalError(...)` will go through
  `onError` only if you wire it that way; the helper itself returns a
  500 response directly.

`onError` is invoked once per request at most. It cannot intercept
errors from streaming bodies after headers have been sent — at that
point the connection is best-effort and the writer's `isAborted()`
becomes true.

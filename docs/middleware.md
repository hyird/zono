# Middleware

Middleware in zono is a function that wraps a request, observes or
mutates the response, and decides whether/when to call the next layer.

## Signature

```zig
fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    next.run();                        // run downstream first
    _ = c.header("x-powered-by", "zono");
    return c.takeResponse();           // hand the (possibly modified) response back
}
```

`next.run()` is mandatory if you want downstream handlers to execute.
After it returns, the downstream `Response` lives on the `Context`;
`c.takeResponse()` transfers ownership back to you. You can mutate
headers/status before returning.

To short-circuit, just don't call `next.run()` and return a response
yourself:

```zig
fn requireApiKey(c: *zono.Context, next: zono.Context.Next) zono.Response {
    if (c.req.header("x-api-key") == null) {
        return c.text(.{ "missing key", .unauthorized });
    }
    next.run();
    return c.takeResponse();
}
```

## Registering

```zig
try app.use(poweredBy);                // applies to every route
try app.useAt("/admin", requireApiKey);// applies to /admin/*
try app.useOn(.POST, "/admin/*", requireApiKey);
```

`useAt` matches the prefix as a path segment boundary, so
`useAt("/admin", ...)` runs for `/admin` and `/admin/users` but not
`/administrator`.

Method helpers also accept middleware-only handlers. This mirrors Hono's
route-level middleware shape:

```zig
try app.post("/admin/*", requireApiKey);
try app.post("/posts", .{ requireApiKey, createPost });
```

If the final value is a route handler, zono registers a route chain. If every
value is middleware, zono registers method-scoped middleware for that path.

`useOn()` accepts single methods, enum literals, method-name strings, or
iterables of those values:

```zig
try app.useOn(.{ .GET, .POST }, .{ "/admin", "/api/*" }, requireApiKey);
```

## Ordering

Middleware runs in registration order. Within a sub-`App` mounted via
`route()` / `mount()`, the parent's middleware runs first, then the
child's, then the route handler. Returning from `next.run()` unwinds
in reverse order — write logging / timing middleware as a normal
"before + after" pair around `next.run()`.

At `finalize()`, zono prebuilds middleware candidate lists in two layers:
method buckets for every registered method name, then route buckets for
routes whose path can be proven against middleware prefixes. Static routes
therefore dispatch only the middleware that can actually match that route,
while dynamic or ambiguous paths fall back to the method bucket. Both paths
preserve the original registration order.

If middleware calls `next.run()` after rewriting the request path or method,
zono detects the change and falls back to the normal middleware lookup for the
new request shape.

## Sharing state with handlers

Use `c.set` / `c.get` to pass typed values along the chain:

```zig
fn injectUser(c: *zono.Context, next: zono.Context.Next) zono.Response {
    const user = lookupUser(c.req) orelse return c.text(.{ "no user", .unauthorized });
    c.set("user", user) catch return zono.internalError("set failed");
    next.run();
    return c.takeResponse();
}

fn me(c: *zono.Context) zono.Response {
    const user = c.get(User, "user") orelse return c.text(.{ "no user", .unauthorized });
    return c.json(user);
}
```

Values stored via `c.set` live in the per-request arena and disappear
once the response is fully sent.

String-like values are stored as slices, not deep copies. Clone unstable
memory to `c.req.allocator` before saving it in `c.set`.

## Built-in helpers

The root API includes only a small helper set:

```zig
try app.use(zono.cors(.{}));
try app.use(zono.serveStatic(.{ .root = "public", .prefix = "/assets" }));
try app.use(zono.session(.{ .cookie_name = "sid" }));
```

See [Core helpers](./helpers.md) for options and behavior. Keep application
policy as ordinary middleware functions so the core stays small.

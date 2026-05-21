# Routing & composition

zono keeps the router deliberately small:

- exact paths (`/users`)
- named params (`/users/:id`)
- final catch-alls (`/assets/*path`)

Regex params, optional params, and middle wildcards are not part of the core
router. Keep those concerns in handlers or split them into explicit routes.
Exact routes are indexed per HTTP method and matched through a hash fast path
before param/catch-all matching.

Routes are registered on an `App`. Apps can be nested with `route()`, mounted
with `mount()`, and prefixed with `basePath()`. Calls become const after
`App.finalize()`, which `Server.serve` does for you.

## Methods

```zig
try app.get("/users", listUsers);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.patch("/users/:id", patchUser);
try app.delete("/users/:id", deleteUser);
try app.head("/users/:id", showUser);
try app.options("/users/:id", showUser);

try app.on(.{ .GET, .POST }, .{ "/a", "/b" }, handler);
try app.all("/raw", rawHandler);
try app.ws("/ws", WsCallbacks);
```

`HEAD` follows normal HTTP semantics. If a `HEAD` route is registered, zono
uses it. Otherwise a matching `GET` route is used as the fallback, while the
transport emits headers without response body bytes. Middleware and handlers
still see the incoming method as `HEAD`.

## Path patterns

```zig
try app.get("/users", listUsers);
try app.get("/users/:id", showUser);
try app.get("/assets/*path", serveAsset);
```

Params are read through the request:

```zig
fn showUser(c: *zono.Context) zono.Response {
    return c.text(c.req.param("id") orelse "missing");
}
```

Use `c.routePath()`, `c.basePath()`, or `c.baseRoutePath()` when a handler
needs the registered route shape rather than the incoming request path.

## `basePath` + `route`

```zig
var api = zono.App.init(allocator);
defer api.deinit();
try api.basePath("/v1");
try api.get("/users", listUsers); // routed at /v1/users

var app = zono.App.init(allocator);
defer app.deinit();
try app.basePath("/api");
try app.route("/", &api); // /api/v1/users
```

`route()` copies the child's routes and middleware into the parent under the
given prefix.

## `mount`

`mount()` accepts either a child `*App` or a bare handler:

```zig
try app.mount("/admin", &admin_app);
try app.mount("/spa/*", spaHandler);
```

## App options

```zig
var app = zono.App.initWithOptions(allocator, .{
    .strict = false,
    .redirect_fixed_path = true,
    .handle_method_not_allowed = true,
    .handle_options = true,
    .router_limits = .{
        .max_path_bytes = 4096,
        .max_segments = 64,
        .max_params = 8,
        .max_param_value_bytes = 1024,
    },
});
```

`strict = true` is the default. It makes `/users` and `/users/` distinct and
issues a 308 redirect to the canonical form.

Router limits are enforced both when routes are registered and when requests
are matched. Requests that exceed lookup limits return `414 URI Too Long`.

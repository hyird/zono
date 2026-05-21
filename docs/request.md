# Request parsing

`zono.Request` follows Hono's request surface where Zig's type system
allows it. The direct helpers are:

```zig
c.req.param("id");
c.req.param(.all);
c.req.query("q");        // zero-copy raw value
c.req.queryDecoded("q"); // owned, form-decoded value
c.req.queryAll();        // decoded aggregate; Zig spelling for Hono's query()
c.req.queries("tag");
c.req.header("User-Agent");
c.req.header(.all);
c.req.cookie("session");
c.req.cookie(.all);

try c.req.paramInt(u64, "id");
try c.req.queryInt(u64, "pageSize", .{ .alias = "page_size", .default = 10 });
```

Zig does not support Hono's no-argument overloads, so aggregate access
uses `queryAll()` (or `query(.all)` for the older spelling). Use
`queryAllWithOptions(.{ .all = true })` when repeated scalar keys should
be collected instead of keeping the last value.

```zig
var query = try c.req.queryAll();
defer query.deinit();

const q = query.value("q") orelse "";
```

`query("name")` is intentionally raw and allocation-free. Use
`queryDecoded("name")` when you want the decoded Hono-style value:

```zig
const maybe_q = try c.req.queryDecoded("q");
defer if (maybe_q) |q| c.req.allocator.free(q);
const q = maybe_q orelse "";
```

Path, header, body, and param slices are only valid for the
request/response lifetime. Clone anything you need after the handler
returns or for background/global storage.

## Body readers

```zig
const text = c.req.text();
const bytes = c.req.arrayBuffer();
const blob = c.req.blob();       // .data + optional .content_type
var form = try c.req.formData(); // urlencoded or multipart
defer form.deinit();
```

These helpers read from the buffered body (`c.req.bodyBytes()`). The built-in
server buffers bodies up to `Server.Options.body_buffer_bytes`, which
defaults to 4 MiB for compatibility.

Use `c.req.bodyBytes()` when you explicitly need the raw buffered body bytes.

For bodies that may be large, set `body_buffer_bytes = 0` or a smaller
threshold and read from the live stream:

```zig
fn upload(c: *zono.Context) zono.Response {
    var reader = c.bodyReader();
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
            else => return c.text(.{ "upload failed", .internal_server_error }),
        };
        if (n == 0) break;
        total += n;
    }

    return c.json(.{ .bytes = total });
}
```

`bodyReader()` also works for buffered requests, so libraries can accept
one code path for both small and large bodies. `textAlloc(allocator,
max_bytes)` and `arrayBufferAlloc(allocator, max_bytes)` are the
allocation-returning forms when you intentionally want to materialize the
stream.

`formData()` is the default `parseBody(.{})` path. Use `parseBody` when
you want Hono-style options:

```zig
var form = try c.req.parseBody(.{
    .all = true,
    .dot = true,
});
defer form.deinit();
```

Repeated scalar names keep the last value by default. `all = true`
collects repeated names. Keys ending in `[]` are always collected as
arrays. `dot = true` lets you group dotted keys:

```zig
var user = try form.group("user");
defer user.deinit();
```

## JSON

```zig
const body = try c.req.json(struct {
    title: []const u8,
});
```

Like Hono's `c.req.json()`, `json(T)` is the high-level JSON body helper. It
returns `T` directly, accepts `application/json`, `text/json`, and
`application/*+json`, allocates through `c.req.allocator`, and maps failures to
the built-in app errors used by `zono.errorHandler(.{})`:

- `error.EmptyRequestBody` for an empty buffered body.
- `error.InvalidRequestBody` for malformed JSON or unavailable live bodies.
- `error.UnsupportedRequestBody` for non-JSON content types.

When you need explicit `std.json.Parsed(T)` ownership and `deinit()`, use
`jsonParsed(T)`. It returns `null` for an empty buffered body and preserves the
lower-level parse errors.

## Typed Params And Query

Use typed helpers when route or query values should become business errors
instead of ad-hoc parse failures:

```zig
const id = try c.req.paramInt(u64, "id");
const active = try c.req.queryBool("active", .{ .default = true });
const sort = try c.req.queryEnum(enum { asc, desc }, "sort", .{});
const page_size = try c.req.queryInt(u64, "pageSize", .{
    .alias = "page_size",
    .default = 10,
});
```

Available helpers:

- `paramInt(T, name)`, `paramBool(name)`, and `paramEnum(T, name)`.
- `queryInt(T, name, options)`, `queryBool(name, options)`, and
  `queryEnum(T, name, options)`.

Query options are a plain struct. `.alias` checks a fallback query name, and
`.default` is returned when neither the main name nor the alias is present.
Missing values return `error.MissingParam` / `error.MissingQuery`; invalid
values return `error.InvalidParam` / `error.InvalidQuery`.

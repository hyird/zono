# zono docs

The top-level [README](../README.md) covers install, quick start, and the
core API at a glance. These pages describe the remaining core subsystems.

## Contents

- [Routing & composition](./routing.md) - `App`, `basePath()`, `route()`,
  `mount()`, `app.ws()`, exact routes, params, final catch-alls, and route
  limits.
- [Context responses](./context.md) - `c.text()`, `c.html()`, `c.json()`,
  raw `c.body()`, redirects, connection info, and body streaming.
- [Request parsing](./request.md) - params, typed query helpers, headers,
  cookies, `text()`, `json(T)`, `jsonParsed(T)`, `bodyBytes()`,
  `arrayBuffer()`, `blob()`, `formData()`, and `parseBody()`.
- [Large uploads](./upload.md) - `bodyReader()`, `saveBodyToFile()`,
  `saveMultipartToDir()`, buffering thresholds, and cancellation checks.
- [Migration notes](./migration.md) - Hono-style response and request
  access in Zig.
- [Middleware](./middleware.md) - `use()` / `useAt()` / `useOn()`,
  ordering, route-level middleware tuples, and the `next.run()` contract.
- [Core helpers](./helpers.md) - `cors()`, `serveStatic()`, and
  in-memory `session()` middleware.
- [MySQL](./mysql.md) - `zono.mysql`, connection pools, escaped `?`
  parameters, prepared statements, transactions, streaming rows, server errors,
  raw results, and typed row mapping.
- [Hooks](./hooks.md) - `notFound()`, `onError()`, app error definitions,
  `zono.errorHandler(.{})`, the reentry guard, and fallible error handlers
  (`!Response`).
- [HTTPException](./http-exception.md) - status/message exceptions,
  custom responses, and `onError` inspection.
- [Streaming & SSE](./streaming.md) - `c.stream()`, `c.streamText()`,
  `c.streamSSE()`, `StreamWriter.isAborted()`, and `Content-Length`.
- [Server](./server.md) - `Server.Options`, request pools, hard request
  limits, connection write nodes, timeouts, graceful stop, and
  `request_timeout_ms`.
- [WebSocket](./websocket.md) - `c.upgradeWebSocket()`, event callbacks,
  frame helpers, and closing.

# WebSocket

zono routes WebSocket upgrades through the same router as HTTP. Use
`app.ws()` for a first-class WebSocket route, or return
`c.upgradeWebSocket(...)` from a normal handler when the upgrade is part
of a larger HTTP flow.

```zig
const WsCallbacks = struct {
    fn onMessage(socket: *zono.WebSocketConnection, message: zono.WebSocketMessage) !void {
        if (message.opcode == .text) try socket.writeText(message.data);
    }
};

try app.ws("/ws", WsCallbacks);
try app.wsWithOptions("/chat", WsCallbacks, .{ .protocol = "chat" });
```

## Handler signatures

`upgradeWebSocket` accepts either:

- `fn(socket: *WebSocketConnection) !void`
- `fn(req: zono.Request, socket: *WebSocketConnection) !void`

For event-style handlers, wrap callbacks with `zono.webSocketHandler`.
Supported callbacks are `onOpen(socket)`, `onMessage(socket, message)`,
`onPing(socket, message)`, `onPong(socket, message)`, and
`onClose(socket, message)`. `onError(socket, err)` is called before a
read error is returned. Ping frames are auto-ponged when `onPing` is not
provided.

Use the second form when you need access to the original request
(headers, cookies, query params).

`app.ws()` accepts either a direct WebSocket handler or a callback type.
The direct handler signatures are the same ones accepted by
`upgradeWebSocket`.

```zig
fn wsHandler(req: zono.Request, socket: *zono.WebSocketConnection) !void {
    _ = req;
    try socket.sendText("connected");
}

try app.ws("/direct", wsHandler);
```

## Connection API

`WebSocketConnection` is a thin wrapper over `std.http.Server.WebSocket`:

```zig
pub fn readSmallMessage(self: *WebSocketConnection) !SmallMessage;
pub fn readMessageAlloc(self: *WebSocketConnection, allocator: std.mem.Allocator, max_bytes: usize) !OwnedMessage;
pub fn writeText(self: *WebSocketConnection, data: []const u8) !void;
pub fn sendText(self: *WebSocketConnection, data: []const u8) !void;
pub fn writeBinary(self: *WebSocketConnection, data: []const u8) !void;
pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void;
pub fn writePing(self: *WebSocketConnection, data: []const u8) !void;
pub fn writePong(self: *WebSocketConnection, data: []const u8) !void;
pub fn close(self: *WebSocketConnection, payload: []const u8) !void;
pub fn closeWithCode(self: *WebSocketConnection, code: u16, reason: []const u8) !void;
pub fn flush(self: *WebSocketConnection) !void;
pub fn isOpen(self: *const WebSocketConnection) bool;
```

`SmallMessage.opcode` is one of `text`, `binary`, `ping`, `pong`,
`connection_close`, `continuation`. `SmallMessage.data` is borrowed
from the connection's read buffer and is valid until the next
`readSmallMessage` call.

Use `readMessageAlloc()` for full-message reads. It reads directly from
the underlying WebSocket stream, reassembles continuation frames,
supports payloads larger than the server read buffer, auto-pongs
interleaved ping frames while assembling a fragmented message, and
returns `WebSocketOwnedMessage`. The payload is capped by the smaller of
`max_bytes` and the route's `max_message_bytes` option.

Outgoing text, binary, ping, and pong payloads are capped by
`max_send_bytes`. Writes after `close()` fail with `ConnectionClosed`, and
oversized reads or writes fail with `MessageTooLarge`. The event-style
handler wrapper closes oversized incoming messages with code `1009`.

The `close` payload is the close-frame body (status code as 2 big-endian
bytes followed by an optional UTF-8 reason). Pass `""` for a bare close
frame without a code. Use `closeWithCode(1000, "bye")` for the common
case, and `zono.parseCloseMessage(message)` to unpack a close payload in
`onClose`.

## Upgrade options

```zig
pub const WebSocketUpgradeOptions = struct {
    /// Optional protocol value passed to the underlying WebSocket runtime.
    protocol: ?[]const u8 = null,

    /// Optional subprotocol to negotiate. When the client offers a
    /// `Sec-WebSocket-Protocol` header containing this value, it is
    /// echoed back; otherwise the upgrade still proceeds without it.
    subprotocol: ?[]const u8 = null,

    /// Allowed Origin values. Empty means allow all; `"*"` also allows all.
    allowed_origins: []const []const u8 = &.{},

    /// Maximum incoming message payload accepted by connection helpers.
    max_message_bytes: usize = 1024 * 1024,

    /// Maximum outgoing payload accepted by text/binary/ping/pong helpers.
    max_send_bytes: usize = 16 * 1024 * 1024,

    /// Close idle reads when no frame arrives before this many milliseconds.
    /// `0` disables idle read deadlines.
    idle_timeout_ms: u64 = 0,

    /// Send a ping after this many milliseconds without a frame. `0`
    /// disables heartbeat pings.
    heartbeat_interval_ms: u64 = 0,

    /// Number of unanswered heartbeat intervals tolerated before close.
    max_missed_heartbeats: usize = 2,

    /// Payload sent with heartbeat ping frames.
    heartbeat_payload: []const u8 = "",
};
```

`allowed_origins` is checked before the upgrade response is emitted. A failed
origin check returns `403 Forbidden`.

When `heartbeat_interval_ms` is set, zono arms the next read deadline for that
interval. On timeout it sends a ping, resets the read deadline, and continues
waiting; after `max_missed_heartbeats` missed intervals it closes the
connection. Any incoming frame resets the missed heartbeat counter. When
heartbeat is disabled but `idle_timeout_ms` is set, a read timeout becomes
`WebSocketIdleTimeout`.

## Server configuration

WebSocket handlers are long-lived and must opt out of the per-request
deadline. Configure your server with `request_timeout_ms = 0`:

```zig
var server = zono.Server.init(.{
    .address = addr,
    .request_timeout_ms = 0,
});
```

If you need to mix short HTTP timeouts with long-lived sockets, run
two server instances on different ports.

WebSocket idle and heartbeat deadlines are enforced through the server's
timed-read path. On a backend that cannot provide timed reads, the options are
still stored on the connection but cannot interrupt a blocking read.

## Testing

`app.request()` only exercises ordinary request/response handlers. Test
WebSocket routes through `Server` with an external or integration WebSocket
client so the handshake and frame loop run for real.

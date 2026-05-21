const std = @import("std");
const Request = @import("../request/request.zig").Request;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");

pub const WebSocketUpgradeOptions = response_mod.WebSocketUpgradeOptions;
pub const WebSocketConnection = response_mod.WebSocketConnection;
pub const WebSocketMessage = response_mod.WebSocketConnection.SmallMessage;
pub const WebSocketOwnedMessage = response_mod.WebSocketConnection.OwnedMessage;

pub const WebSocketCloseInfo = struct {
    code: ?u16 = null,
    reason: []const u8 = "",
    valid: bool = true,
};

pub fn isWebSocketUpgrade(req: Request) bool {
    if (req.method != .GET) return false;
    const upgrade = req.header("upgrade") orelse return false;
    if (!eqIgnoreCase(upgrade, "websocket")) return false;
    if (!headerContainsToken(req.header("connection") orelse return false, "upgrade")) return false;
    if (!validWebSocketKey(req.header("sec-websocket-key") orelse return false)) return false;
    const version = req.header("sec-websocket-version") orelse return false;
    if (!eqIgnoreCase(version, "13")) return false;
    return true;
}

pub fn upgradeWebSocket(req: Request, comptime handler: anytype, websocket_options: WebSocketUpgradeOptions) Response {
    if (!isWebSocketUpgrade(req)) {
        return response_mod.text(.bad_request, "Invalid WebSocket upgrade");
    }
    if (!originAllowed(req, websocket_options.allowed_origins)) {
        return response_mod.text(.forbidden, "WebSocket origin forbidden");
    }

    const Builder = struct {
        const Data = struct {
            req: Request,
        };

        fn run(ctx: *const anyopaque, socket: *response_mod.WebSocketConnection) anyerror!void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            const mode = comptime webSocketHandlerMode(@TypeOf(handler));
            if (comptime mode == .request) {
                try handler(data.req, socket);
            } else {
                try handler(socket);
            }
        }

        /// Type-erased deinit installed via `Response.attachScope`. Owns the
        /// heap-allocated `Data` and frees it after the websocket lifecycle
        /// completes.
        fn scopeDeinit(scope_ptr: *anyopaque) void {
            const data: *Data = @ptrCast(@alignCast(scope_ptr));
            const allocator = data.req.allocator;
            allocator.destroy(data);
        }
    };

    const data = req.allocator.create(Builder.Data) catch return response_mod.internalError("websocket alloc failed");
    data.* = .{
        .req = req,
    };

    var response = response_mod.websocketRuntime(.{
        .ctx = data,
        .run_fn = Builder.run,
        .protocol = negotiatedWebSocketProtocol(req, websocket_options),
        .options = websocket_options,
    });
    // Tie the heap `Data` lifetime to the response via the uniform scope
    // mechanism; on attach failure we free the data and surface an error.
    response.finalizeScope(req.allocator, @ptrCast(data), Builder.scopeDeinit);
    return response;
}

pub fn webSocketHandler(comptime Callbacks: type) fn (*WebSocketConnection) anyerror!void {
    return struct {
        fn run(socket: *WebSocketConnection) anyerror!void {
            if (@hasDecl(Callbacks, "onOpen")) {
                try callMaybeError(Callbacks.onOpen, .{socket});
            }

            while (true) {
                const message = socket.readSmallMessage() catch |err| switch (err) {
                    error.ConnectionClose => {
                        if (@hasDecl(Callbacks, "onClose")) {
                            var empty: [0]u8 = .{};
                            try callMaybeError(Callbacks.onClose, .{ socket, WebSocketMessage{
                                .opcode = .connection_close,
                                .data = &empty,
                            } });
                        }
                        return;
                    },
                    else => {
                        var callback_error: ?anyerror = null;
                        if (@hasDecl(Callbacks, "onError")) {
                            callMaybeError(Callbacks.onError, .{ socket, err }) catch |callback_err| {
                                callback_error = callback_err;
                            };
                        }
                        switch (err) {
                            error.MessageTooLarge => {
                                socket.closeWithCode(1009, "message too large") catch {};
                                if (callback_error) |callback_err| return callback_err;
                                return;
                            },
                            error.WebSocketIdleTimeout, error.WebSocketHeartbeatTimeout => {
                                socket.closeWithCode(1001, "timeout") catch {};
                                if (callback_error) |callback_err| return callback_err;
                                return;
                            },
                            else => {
                                socket.closeWithCode(1011, "unexpected error") catch {};
                                if (callback_error) |callback_err| return callback_err;
                                return err;
                            },
                        }
                    },
                };
                switch (message.opcode) {
                    .text, .binary => {
                        if (@hasDecl(Callbacks, "onMessage")) {
                            try callMaybeError(Callbacks.onMessage, .{ socket, message });
                        }
                    },
                    .ping => {
                        if (@hasDecl(Callbacks, "onPing")) {
                            try callMaybeError(Callbacks.onPing, .{ socket, message });
                        } else {
                            try socket.writePong(message.data);
                        }
                    },
                    .pong => {
                        if (@hasDecl(Callbacks, "onPong")) {
                            try callMaybeError(Callbacks.onPong, .{ socket, message });
                        }
                    },
                    .connection_close => {
                        const close_info = parseCloseMessage(message);
                        if (!close_info.valid) {
                            socket.closeWithCode(1002, "invalid close frame") catch {};
                            return;
                        }
                        defer socket.close(message.data) catch {};
                        if (@hasDecl(Callbacks, "onClose")) {
                            try callMaybeError(Callbacks.onClose, .{ socket, message });
                        }
                        return;
                    },
                    else => {},
                }
            }
        }
    }.run;
}

pub fn parseCloseMessage(message: WebSocketMessage) WebSocketCloseInfo {
    if (message.data.len == 0) return .{};
    if (message.data.len == 1) return .{ .valid = false };
    const code = (@as(u16, message.data[0]) << 8) | @as(u16, message.data[1]);
    const reason = message.data[2..];
    if (!validCloseCode(code)) return .{ .code = code, .reason = reason, .valid = false };
    if (!std.unicode.utf8ValidateSlice(reason)) return .{ .code = code, .reason = reason, .valid = false };
    return .{
        .code = code,
        .reason = reason,
    };
}

fn validCloseCode(code: u16) bool {
    if (code < 1000) return false;
    if (code == 1004 or code == 1005 or code == 1006 or code == 1015) return false;
    if (code >= 1016 and code <= 2999) return false;
    if (code >= 5000) return false;
    return true;
}

const WebSocketHandlerMode = enum {
    socket,
    request,
};

fn webSocketHandlerMode(comptime HandlerType: type) WebSocketHandlerMode {
    const info = switch (@typeInfo(HandlerType)) {
        .@"fn" => |function_info| function_info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |function_info| function_info,
            else => @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void."),
        },
        else => @compileError("zono.upgradeWebSocket handlers must be functions or function pointers."),
    };

    if (info.return_type == null) {
        @compileError("zono.upgradeWebSocket handlers must return !void.");
    }
    switch (@typeInfo(info.return_type.?)) {
        .error_union => |payload| {
            if (payload.payload != void) {
                @compileError("zono.upgradeWebSocket handlers must return !void.");
            }
        },
        else => @compileError("zono.upgradeWebSocket handlers must return !void."),
    }

    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
        if (Param != *response_mod.WebSocketConnection) {
            @compileError("zono.upgradeWebSocket handlers must accept *zono.WebSocketConnection.");
        }
        return .socket;
    }

    if (info.params.len != 2) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }

    const First = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    const Second = info.params[1].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    if (First != Request or Second != *response_mod.WebSocketConnection) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }
    return .request;
}

fn callMaybeError(comptime callback: anytype, args: anytype) anyerror!void {
    const FnType = callbackFnType(@TypeOf(callback));
    const info = @typeInfo(FnType).@"fn";
    const ReturnType = info.return_type orelse @compileError("webSocketHandler callbacks must return void or !void.");
    if (ReturnType == void) {
        @call(.auto, callback, args);
        return;
    }
    switch (@typeInfo(ReturnType)) {
        .error_union => |error_union| {
            if (error_union.payload != void) {
                @compileError("webSocketHandler callbacks must return void or !void.");
            }
            try @call(.auto, callback, args);
        },
        else => @compileError("webSocketHandler callbacks must return void or !void."),
    }
}

fn callbackFnType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"fn" => T,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => pointer.child,
            else => @compileError("webSocketHandler callbacks must be functions."),
        },
        else => @compileError("webSocketHandler callbacks must be functions."),
    };
}

fn headerContainsToken(header_value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (eqIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

fn validWebSocketKey(key: []const u8) bool {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (decoded_size != 16) return false;

    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    return true;
}

fn negotiatedWebSocketProtocol(req: Request, websocket_options: WebSocketUpgradeOptions) ?[]const u8 {
    const configured = websocket_options.protocol orelse websocket_options.subprotocol orelse return null;
    const requested = req.header("sec-websocket-protocol") orelse return null;

    var iter = std.mem.splitScalar(u8, requested, ',');
    while (iter.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, token, configured)) return configured;
    }
    return null;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn originAllowed(req: Request, allowed_origins: []const []const u8) bool {
    if (allowed_origins.len == 0) return true;
    const origin = req.header("origin") orelse return false;
    for (allowed_origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.ascii.eqlIgnoreCase(origin, allowed)) return true;
    }
    return false;
}

test "websocket helper validates upgrade requests" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "sec-websocket-protocol", .value = "superchat, chat" },
    };

    try std.testing.expect(isWebSocketUpgrade(req));

    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{
        .protocol = "chat",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expect(res.runtime == .websocket);
    try std.testing.expectEqualStrings("chat", res.runtime.websocket.protocol.?);
}

test "websocket helper rejects malformed keys" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "not-a-valid-key" },
        .{ .name = "sec-websocket-version", .value = "13" },
    };

    try std.testing.expect(!isWebSocketUpgrade(req));
}

test "websocket helper does not echo unsolicited subprotocols" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "sec-websocket-protocol", .value = "superchat" },
    };

    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{
        .protocol = "chat",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqual(@as(?[]const u8, null), res.runtime.websocket.protocol);
}

test "websocket helper rejects plain requests" {
    const req = Request.init(std.testing.allocator, .GET, "/ws");
    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("Invalid WebSocket upgrade", res.bodyBytes());
}

test "websocket helper enforces origin allowlist" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "origin", .value = "https://evil.example" },
    };

    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{
        .allowed_origins = &.{"https://app.example"},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
}

test "websocket event helper builds a socket handler" {
    const handler = webSocketHandler(struct {
        fn onOpen(_: *response_mod.WebSocketConnection) void {}
        fn onMessage(_: *response_mod.WebSocketConnection, _: WebSocketMessage) !void {}
        fn onClose(_: *response_mod.WebSocketConnection, _: WebSocketMessage) void {}
        fn onError(_: *response_mod.WebSocketConnection, _: anyerror) void {}
    });

    try std.testing.expect(@TypeOf(handler) == fn (*response_mod.WebSocketConnection) anyerror!void);
}

test "websocket close message parser extracts code and reason" {
    const message = WebSocketMessage{
        .data = @constCast("\x03\xe8bye"[0..]),
        .opcode = .connection_close,
    };
    const info = parseCloseMessage(message);
    try std.testing.expectEqual(@as(?u16, 1000), info.code);
    try std.testing.expectEqualStrings("bye", info.reason);
    try std.testing.expect(info.valid);
}

test "websocket close message parser rejects malformed close payloads" {
    const one_byte = WebSocketMessage{
        .data = @constCast("\x03"[0..]),
        .opcode = .connection_close,
    };
    try std.testing.expect(!parseCloseMessage(one_byte).valid);

    const reserved_code = WebSocketMessage{
        .data = @constCast("\x03\xed"[0..]),
        .opcode = .connection_close,
    };
    try std.testing.expect(!parseCloseMessage(reserved_code).valid);

    const tls_failure = WebSocketMessage{
        .data = @constCast("\x03\xf7"[0..]),
        .opcode = .connection_close,
    };
    try std.testing.expect(!parseCloseMessage(tls_failure).valid);

    const invalid_utf8 = WebSocketMessage{
        .data = @constCast("\x03\xe8\xff"[0..]),
        .opcode = .connection_close,
    };
    try std.testing.expect(!parseCloseMessage(invalid_utf8).valid);
}

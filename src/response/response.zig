const std = @import("std");
const EpochSeconds = std.time.epoch.EpochSeconds;
const Request = @import("../request/request.zig").Request;
const HeaderStore = @import("header_store.zig").HeaderStore;
const ScopeList = @import("scope_list.zig").ScopeList;
const http_names = @import("../core/http_names.zig");
const http_method = @import("../core/http_method.zig");
const time = @import("../core/time.zig");

pub const SameSite = enum {
    strict,
    lax,
    none,
};

pub const CookiePriority = enum {
    low,
    medium,
    high,
};

pub const CookiePrefix = enum {
    secure,
    host,
};

pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    expires: ?EpochSeconds = null,
    http_only: bool = false,
    max_age: ?u64 = null,
    path: ?[]const u8 = null,
    secure: bool = false,
    same_site: ?SameSite = null,
    priority: ?CookiePriority = null,
    prefix: ?CookiePrefix = null,
    partitioned: bool = false,
};

pub const DeleteCookieOptions = struct {
    domain: ?[]const u8 = null,
    path: ?[]const u8 = "/",
    secure: bool = false,
    prefix: ?CookiePrefix = null,
};

pub const CookieError = std.mem.Allocator.Error || error{
    InvalidCookieName,
    InvalidCookieValue,
    InvalidCookiePath,
    InvalidCookieDomain,
    SecurePrefixRequiresSecure,
    HostPrefixRequiresSecure,
    HostPrefixRequiresPathRoot,
    HostPrefixDisallowsDomain,
    SameSiteNoneRequiresSecure,
    PartitionedRequiresSecure,
    MaxAgeTooLong,
    ExpiresTooFar,
};

pub const WebSocketConnection = struct {
    socket: *std.http.Server.WebSocket,
    max_message_bytes: usize = 1024 * 1024,
    max_send_bytes: usize = 16 * 1024 * 1024,
    idle_timeout_ms: u64 = 0,
    heartbeat_interval_ms: u64 = 0,
    max_missed_heartbeats: usize = 2,
    heartbeat_payload: []const u8 = "",
    missed_heartbeats: usize = 0,
    open: bool = true,
    arm_read_deadline_ctx: ?*anyopaque = null,
    arm_read_deadline_fn: ?*const fn (ctx: *anyopaque, timeout_ms: u64) void = null,
    read_error_ctx: ?*anyopaque = null,
    read_error_fn: ?*const fn (ctx: *anyopaque) ?anyerror = null,

    pub const SmallMessage = std.http.Server.WebSocket.SmallMessage;
    pub const ReadSmallMessageError = std.http.Server.WebSocket.ReadSmallTextMessageError || std.Io.Writer.Error || error{
        ConnectionClosed,
        MessageTooLarge,
        WebSocketIdleTimeout,
        WebSocketHeartbeatTimeout,
    };
    pub const ReadMessageAllocError = std.Io.Reader.Error || std.Io.Writer.Error || std.mem.Allocator.Error || error{
        ConnectionClosed,
        MessageTooLarge,
        MissingMaskBit,
        UnexpectedOpCode,
        WebSocketIdleTimeout,
        WebSocketHeartbeatTimeout,
    };
    pub const WriteError = std.Io.Writer.Error || error{
        MessageTooLarge,
        ConnectionClosed,
    };

    pub const OwnedMessage = struct {
        allocator: std.mem.Allocator,
        opcode: std.http.Server.WebSocket.Opcode,
        data: []u8,

        pub fn deinit(self: *OwnedMessage) void {
            self.allocator.free(self.data);
            self.* = undefined;
        }
    };

    pub fn readSmallMessage(self: *WebSocketConnection) ReadSmallMessageError!SmallMessage {
        while (true) {
            self.armReadDeadline();
            const message = self.socket.readSmallMessage() catch |err| switch (err) {
                error.ReadFailed => {
                    if (try self.handleReadFailedTimeout()) continue;
                    return err;
                },
                else => return err,
            };
            if (message.data.len > self.max_message_bytes) return error.MessageTooLarge;
            self.markReadActivity();
            return message;
        }
    }

    pub fn readMessageAlloc(self: *WebSocketConnection, allocator: std.mem.Allocator, max_bytes: usize) ReadMessageAllocError!OwnedMessage {
        const Opcode = std.http.Server.WebSocket.Opcode;
        const effective_limit = @min(max_bytes, self.max_message_bytes);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        var message_opcode: ?Opcode = null;
        while (true) {
            const frame = try self.readFrameAlloc(allocator, effective_limit);
            defer allocator.free(frame.data);

            switch (frame.opcode) {
                .text, .binary => {
                    if (message_opcode != null) return error.UnexpectedOpCode;
                    if (frame.data.len > effective_limit) return error.MessageTooLarge;
                    message_opcode = frame.opcode;
                    try out.appendSlice(allocator, frame.data);
                    if (frame.final) return .{
                        .allocator = allocator,
                        .opcode = frame.opcode,
                        .data = try out.toOwnedSlice(allocator),
                    };
                },
                .continuation => {
                    const opcode = message_opcode orelse return error.UnexpectedOpCode;
                    if (out.items.len > effective_limit or frame.data.len > effective_limit - out.items.len) return error.MessageTooLarge;
                    try out.appendSlice(allocator, frame.data);
                    if (frame.final) return .{
                        .allocator = allocator,
                        .opcode = opcode,
                        .data = try out.toOwnedSlice(allocator),
                    };
                },
                .ping => {
                    try self.writePong(frame.data);
                },
                .pong => {},
                .connection_close => return .{
                    .allocator = allocator,
                    .opcode = .connection_close,
                    .data = try allocator.dupe(u8, frame.data),
                },
                else => return error.UnexpectedOpCode,
            }
        }
    }

    const Frame = struct {
        final: bool,
        opcode: std.http.Server.WebSocket.Opcode,
        data: []u8,
    };

    fn readFrameAlloc(self: *WebSocketConnection, allocator: std.mem.Allocator, max_bytes: usize) ReadMessageAllocError!Frame {
        const WebSocket = std.http.Server.WebSocket;
        const in = self.socket.input;
        const header = while (true) {
            self.armReadDeadline();
            break in.takeArray(2) catch |err| switch (err) {
                error.ReadFailed => {
                    if (try self.handleReadFailedTimeout()) continue;
                    return err;
                },
                else => return err,
            };
        };
        const h0: WebSocket.Header0 = @bitCast(header[0]);
        const h1: WebSocket.Header1 = @bitCast(header[1]);

        if (!h1.mask) return error.MissingMaskBit;
        const len: usize = switch (h1.payload_len) {
            .len16 => @intCast(try in.takeInt(u16, .big)),
            .len64 => std.math.cast(usize, try in.takeInt(u64, .big)) orelse return error.MessageTooLarge,
            else => @intFromEnum(h1.payload_len),
        };
        if (len > max_bytes) return error.MessageTooLarge;

        const mask = (try in.takeArray(4)).*;
        const payload = try allocator.alloc(u8, len);
        errdefer allocator.free(payload);
        try in.readSliceAll(payload);
        for (payload, 0..) |*byte, index| {
            byte.* ^= mask[index % 4];
        }
        self.markReadActivity();

        return .{
            .final = h0.fin,
            .opcode = h0.opcode,
            .data = payload,
        };
    }

    pub fn writeText(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.ensureWritable(data.len);
        try self.socket.writeMessage(data, .text);
    }

    pub fn sendText(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.writeText(data);
    }

    pub fn writeBinary(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.ensureWritable(data.len);
        try self.socket.writeMessage(data, .binary);
    }

    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.writeBinary(data);
    }

    pub fn writePing(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.ensureWritable(data.len);
        try self.socket.writeMessage(data, .ping);
    }

    pub fn writePong(self: *WebSocketConnection, data: []const u8) WriteError!void {
        try self.ensureWritable(data.len);
        try self.socket.writeMessage(data, .pong);
    }

    pub fn close(self: *WebSocketConnection, data: []const u8) WriteError!void {
        if (!self.open) return;
        try self.socket.writeMessage(data, .connection_close);
        self.open = false;
    }

    pub fn closeWithCode(self: *WebSocketConnection, code: u16, reason: []const u8) WriteError!void {
        var buffer: [125]u8 = undefined;
        buffer[0] = @intCast(code >> 8);
        buffer[1] = @intCast(code & 0xff);
        const reason_len = @min(reason.len, buffer.len - 2);
        @memcpy(buffer[2 .. 2 + reason_len], reason[0..reason_len]);
        try self.close(buffer[0 .. 2 + reason_len]);
    }

    pub fn flush(self: *WebSocketConnection) std.Io.Writer.Error!void {
        try self.socket.flush();
    }

    pub fn isOpen(self: *const WebSocketConnection) bool {
        return self.open;
    }

    fn ensureWritable(self: *const WebSocketConnection, len: usize) WriteError!void {
        if (!self.open) return error.ConnectionClosed;
        if (len > self.max_send_bytes) return error.MessageTooLarge;
    }

    fn markReadActivity(self: *WebSocketConnection) void {
        self.missed_heartbeats = 0;
    }

    fn armReadDeadline(self: *WebSocketConnection) void {
        const arm = self.arm_read_deadline_fn orelse return;
        const ctx = self.arm_read_deadline_ctx orelse return;
        const timeout_ms = if (self.heartbeat_interval_ms != 0)
            self.heartbeat_interval_ms
        else
            self.idle_timeout_ms;
        arm(ctx, timeout_ms);
    }

    fn readTimedOut(self: *const WebSocketConnection) bool {
        const read_error = self.read_error_fn orelse return false;
        const ctx = self.read_error_ctx orelse return false;
        const err = read_error(ctx) orelse return false;
        return err == error.Timeout;
    }

    fn handleReadFailedTimeout(self: *WebSocketConnection) (WriteError || error{ WebSocketIdleTimeout, WebSocketHeartbeatTimeout })!bool {
        if (!self.readTimedOut()) return false;
        if (self.heartbeat_interval_ms == 0) return error.WebSocketIdleTimeout;

        if (self.missed_heartbeats >= self.max_missed_heartbeats) {
            self.open = false;
            return error.WebSocketHeartbeatTimeout;
        }

        self.missed_heartbeats += 1;
        try self.writePing(self.heartbeat_payload);
        return true;
    }
};

pub const WebSocketUpgradeOptions = struct {
    protocol: ?[]const u8 = null,
    subprotocol: ?[]const u8 = null,
    allowed_origins: []const []const u8 = &.{},
    max_message_bytes: usize = 1024 * 1024,
    max_send_bytes: usize = 16 * 1024 * 1024,
    idle_timeout_ms: u64 = 0,
    heartbeat_interval_ms: u64 = 0,
    max_missed_heartbeats: usize = 2,
    heartbeat_payload: []const u8 = "",
};

pub const WebSocketRunFn = *const fn (ctx: *const anyopaque, socket: *WebSocketConnection) anyerror!void;

pub const WebSocketRuntime = struct {
    ctx: *const anyopaque,
    run_fn: WebSocketRunFn,
    protocol: ?[]const u8 = null,
    options: WebSocketUpgradeOptions = .{},
};

pub const Runtime = union(enum) {
    none,
    websocket: WebSocketRuntime,
};

/// A streaming-aware writer handed to user code.
///
/// `write/writeAll/print/flush` are thin wrappers over the underlying
/// `std.http.BodyWriter`. `isAborted()` becomes true once the peer is gone or
/// the server is shutting down, allowing handlers to stop producing data
/// without surfacing transport errors.
pub const StreamWriter = struct {
    /// Underlying writer. In production this is `&body_writer.writer` from a
    /// `std.http.BodyWriter` returned by `respondStreaming` (so chunked /
    /// content-length framing is handled by the writer's vtable). In tests
    /// `App.request` substitutes an in-memory `std.Io.Writer.Allocating`.
    inner: *std.Io.Writer,
    aborted: *const std.atomic.Value(bool),

    pub const Error = std.Io.Writer.Error;
    pub const PipeError = Error || std.Io.Reader.ShortError || error{StreamTooLong};

    pub fn writer(self: *StreamWriter) *std.Io.Writer {
        return self.inner;
    }

    pub fn writeAll(self: *StreamWriter, bytes: []const u8) Error!void {
        try self.inner.writeAll(bytes);
    }

    pub fn write(self: *StreamWriter, bytes: []const u8) Error!usize {
        return try self.inner.write(bytes);
    }

    pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) Error!void {
        try self.inner.print(fmt, args);
    }

    pub fn pipeFrom(self: *StreamWriter, reader: *std.Io.Reader, max_bytes: ?usize) PipeError!usize {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (!self.isAborted()) {
            const n = try reader.readSliceShort(&buf);
            if (n == 0) return total;
            if (max_bytes) |limit| {
                if (total > limit or n > limit - total) return error.StreamTooLong;
            }
            try self.writeAll(buf[0..n]);
            total += n;
        }
        return total;
    }

    /// Flushes buffered bytes onto the wire so the client receives them now.
    pub fn flush(self: *StreamWriter) Error!void {
        try self.inner.flush();
    }

    /// True once the connection is no longer usable (peer closed, server
    /// shutdown, etc). Stream handlers should poll this between chunks.
    pub fn isAborted(self: *const StreamWriter) bool {
        return self.aborted.load(.acquire);
    }
};

pub const StreamRunFn = *const fn (ctx: *const anyopaque, stream: *StreamWriter) anyerror!void;

pub const StreamRuntime = struct {
    ctx: *const anyopaque,
    run_fn: StreamRunFn,
    /// Optional content length. When null, transfer-encoding: chunked is used.
    content_length: ?u64 = null,
};

/// Server-Sent Events runtime. Specialization of streaming for the
/// `text/event-stream` content type that frames messages for the user.
pub const SseEvent = struct {
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
    data: []const u8 = "",
};

pub const SseWriter = struct {
    stream: *StreamWriter,

    pub const Error = StreamWriter.Error;

    pub fn isAborted(self: *const SseWriter) bool {
        return self.stream.isAborted();
    }

    pub fn flush(self: *SseWriter) Error!void {
        try self.stream.flush();
    }

    /// Sends a comment line. Useful as a keep-alive when no real data is due.
    pub fn comment(self: *SseWriter, text_value: []const u8) Error!void {
        try writeMultiline(self.stream, ": ", text_value);
        try self.stream.writeAll("\n");
    }

    pub fn send(self: *SseWriter, event: SseEvent) Error!void {
        if (event.id) |id| {
            try self.stream.writeAll("id: ");
            try self.stream.writeAll(id);
            try self.stream.writeAll("\n");
        }
        if (event.event) |name| {
            try self.stream.writeAll("event: ");
            try self.stream.writeAll(name);
            try self.stream.writeAll("\n");
        }
        if (event.retry_ms) |retry| {
            try self.stream.print("retry: {d}\n", .{retry});
        }
        if (event.data.len > 0) {
            try writeMultiline(self.stream, "data: ", event.data);
        }
        try self.stream.writeAll("\n");
    }

    pub fn sendText(self: *SseWriter, data: []const u8) Error!void {
        try self.send(.{ .data = data });
    }

    pub fn sendNamed(self: *SseWriter, event_name: []const u8, data: []const u8) Error!void {
        try self.send(.{ .event = event_name, .data = data });
    }

    fn writeMultiline(sw: *StreamWriter, prefix: []const u8, value: []const u8) Error!void {
        var iter = std.mem.splitScalar(u8, value, '\n');
        while (iter.next()) |line| {
            try sw.writeAll(prefix);
            try sw.writeAll(line);
            try sw.writeAll("\n");
        }
    }
};

pub const SseRunFn = *const fn (ctx: *const anyopaque, sse: *SseWriter) anyerror!void;

pub const SseRuntime = struct {
    ctx: *const anyopaque,
    run_fn: SseRunFn,
};

/// Runtime description for a streaming file response. The server opens
/// `path` (relative to `std.Io.Dir.cwd()`), stats it to populate the
/// `Content-Length` header unless `known_size` is supplied, and pumps file
/// bytes into the response body writer without materializing the whole file in
/// memory.
///
/// `head_only` lets handlers emit the same headers without a body. `max_bytes`
/// caps the response when stat reports a larger file (server returns 500 in
/// that case to avoid truncation).
/// `Content-Type` lives on the enclosing `Response` struct and is not
/// duplicated here.
pub const FileRuntime = struct {
    path: []const u8,
    max_bytes: u64 = std.math.maxInt(u64),
    head_only: bool = false,
    /// When set, `Response.deinit` frees `path` via this allocator. Handlers
    /// that dupe the path into the request allocator should set this so the
    /// response owns the string. Constructors that borrow a caller-owned path
    /// should leave it `null`.
    path_owner: ?std.mem.Allocator = null,
    /// Byte offset within the file where delivery starts. Used by Range
    /// (206 Partial Content) responses; 0 for full-body delivery.
    offset: u64 = 0,
    /// Exact number of bytes to stream. `null` means "from `offset` to EOF
    /// subject to `max_bytes`" (i.e. full body). Together with `offset`
    /// this describes the closed byte range to serve.
    length: ?u64 = null,
    /// Optional known total file size. Only set this when the caller can
    /// guarantee the file size remains valid until response delivery; stale
    /// sizes can corrupt HTTP framing.
    known_size: ?u64 = null,
};

/// Discriminates how the response body is delivered. Most code paths produce
/// `.buffered`, but `.stream`/`.sse` allow chunked/streaming output and
/// `.file` hands off to the server for file delivery without buffering the
/// entire body.
pub const Body = union(enum) {
    buffered: []const u8,
    stream: StreamRuntime,
    sse: SseRuntime,
    file: FileRuntime,
};

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body_kind: Body = .{ .buffered = "" },
    /// When true, the server emits the response headers using the selected
    /// body kind's normal length metadata, but does not send body bytes.
    /// `App` sets this for all HEAD requests.
    head_only: bool = false,
    location: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    extra_headers: HeaderStore = .{},
    /// Allocator used only for borrowed-response header overflow storage.
    /// Header name/value slices remain borrowed unless `owned_allocator` is set.
    /// When null, borrowed responses can use only the inline header capacity.
    header_allocator: ?std.mem.Allocator = null,
    owned_allocator: ?std.mem.Allocator = null,
    owned_headers_allocator: ?std.mem.Allocator = null,
    runtime: Runtime = .none,
    /// Optional chain of scopes whose lifetime is tied to this Response.
    /// Used by the framework to keep things like a heap-allocated `Context`
    /// (with its `SharedState` and route params) alive across the boundary
    /// between the outer handler returning and the streaming body actually
    /// being produced. Stored as a linked list so nested wrappers can each
    /// attach their own scope without disturbing inner ones. Freed in
    /// `deinit` in attach order (newest first). This is the single, uniform
    /// ownership-extension slot - works for any body kind (`.buffered`,
    /// `.stream`, `.sse`) and any runtime (`.websocket`, etc.).
    scopes: ScopeList = .{},

    pub fn header(self: *Response, name: []const u8, value: []const u8) bool {
        if (!isAllowedResponseHeader(name)) return false;
        if (!validHeaderName(name) or !validHeaderValue(value)) return false;
        if (http_names.isContentType(name)) {
            self.replaceSlice(&self.content_type, value) catch return false;
            return true;
        }
        if (http_names.isLocation(name)) {
            self.replaceOptionalSlice(&self.location, value) catch return false;
            return true;
        }
        if (http_names.isAllow(name)) {
            self.replaceOptionalSlice(&self.allow, value) catch return false;
            return true;
        }
        if (http_names.isSetCookie(name)) {
            return self.appendHeader(name, value);
        }

        for (self.extra_headers.mutableItems()) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                self.replaceHeader(entry, name, value) catch return false;
                return true;
            }
        }

        return self.appendHeader(name, value);
    }

    pub fn setStatus(self: *Response, status: std.http.Status) void {
        self.status = status;
    }

    pub fn setContentType(self: *Response, content_type: []const u8) bool {
        if (!validHeaderValue(content_type)) return false;
        self.replaceSlice(&self.content_type, content_type) catch return false;
        return true;
    }

    pub fn bodyBytes(self: *const Response) []const u8 {
        return switch (self.body_kind) {
            .buffered => |bytes| bytes,
            else => "",
        };
    }

    pub fn setBody(self: *Response, content: []const u8) bool {
        self.replaceBody(content) catch return false;
        return true;
    }

    pub fn setLocation(self: *Response, location: ?[]const u8) bool {
        if (location) |value| {
            if (!validHeaderValue(value)) return false;
            self.replaceOptionalSlice(&self.location, value) catch return false;
        } else {
            self.clearOptionalSlice(&self.location);
        }
        return true;
    }

    pub fn setAllow(self: *Response, allow: ?[]const u8) bool {
        if (allow) |value| {
            if (!validHeaderValue(value)) return false;
            self.replaceOptionalSlice(&self.allow, value) catch return false;
        } else {
            self.clearOptionalSlice(&self.allow);
        }
        return true;
    }

    pub fn deleteHeader(self: *Response, name: []const u8) bool {
        if (http_names.isContentType(name)) {
            self.clearSlice(&self.content_type);
            return true;
        }
        if (http_names.isLocation(name)) {
            self.clearOptionalSlice(&self.location);
            return true;
        }
        if (http_names.isAllow(name)) {
            self.clearOptionalSlice(&self.allow);
            return true;
        }

        var index: usize = 0;
        var removed = false;
        while (index < self.extra_headers.items().len) {
            const entry = self.extra_headers.items()[index];
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) {
                index += 1;
                continue;
            }

            if (self.extraHeaderOwner()) |allocator| {
                allocator.free(entry.name);
                allocator.free(entry.value);
            }

            _ = self.extra_headers.swapRemove(index);
            removed = true;
        }

        return removed;
    }

    pub fn appendHeader(self: *Response, name: []const u8, value: []const u8) bool {
        if (!isAllowedResponseHeader(name)) return false;
        if (!validHeaderName(name) or !validHeaderValue(value)) return false;
        if (self.extraHeaderOwner()) |allocator| {
            const owned_name = allocator.dupe(u8, name) catch return false;
            errdefer allocator.free(owned_name);
            const owned_value = allocator.dupe(u8, value) catch return false;
            errdefer allocator.free(owned_value);

            self.appendExtraHeader(allocator, .{
                .name = owned_name,
                .value = owned_value,
            }) catch {
                allocator.free(owned_name);
                allocator.free(owned_value);
                return false;
            };
            return true;
        }

        self.extra_headers.appendBorrowed(self.header_allocator, .{
            .name = name,
            .value = value,
        }) catch return false;
        return true;
    }

    pub fn extraHeaders(self: *const Response) []const std.http.Header {
        return self.extra_headers.items();
    }

    pub fn headerValue(self: *const Response, name: []const u8) ?[]const u8 {
        if (http_names.isContentType(name)) {
            return if (self.content_type.len > 0) self.content_type else null;
        }
        if (http_names.isLocation(name)) return self.location;
        if (http_names.isAllow(name)) return self.allow;

        for (self.extraHeaders()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn appendExtraHeader(
        self: *Response,
        allocator: std.mem.Allocator,
        header_entry: std.http.Header,
    ) std.mem.Allocator.Error!void {
        try self.extra_headers.append(allocator, header_entry);
    }

    pub fn cookie(
        self: *Response,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        cookie_options: CookieOptions,
    ) CookieError!void {
        try self.ensureExtraHeadersOwned(allocator);
        const header_allocator = self.extraHeaderOwner() orelse allocator;

        const owned_name = try header_allocator.dupe(u8, "set-cookie");
        errdefer header_allocator.free(owned_name);
        const owned_value = try generateCookie(header_allocator, name, value, cookie_options);
        errdefer header_allocator.free(owned_value);

        try self.appendExtraHeader(header_allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    pub fn deleteCookie(
        self: *Response,
        allocator: std.mem.Allocator,
        name: []const u8,
        delete_options: DeleteCookieOptions,
    ) CookieError!void {
        try self.ensureExtraHeadersOwned(allocator);
        const header_allocator = self.extraHeaderOwner() orelse allocator;

        const owned_name = try header_allocator.dupe(u8, "set-cookie");
        errdefer header_allocator.free(owned_name);
        const owned_value = try generateDeleteCookie(header_allocator, name, delete_options);
        errdefer header_allocator.free(owned_value);

        try self.appendExtraHeader(header_allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    pub fn file(path: []const u8, content_type: []const u8, file_options: FileOptions) Response {
        return @This().bodyFile(path, content_type, file_options);
    }

    fn bodyFile(path: []const u8, content_type: []const u8, file_options: FileOptions) Response {
        return .{
            .status = file_options.status,
            .content_type = content_type,
            .body_kind = .{ .file = .{
                .path = path,
                .max_bytes = file_options.max_bytes,
                .head_only = file_options.head_only,
                .offset = file_options.offset,
                .length = file_options.length,
                .known_size = file_options.known_size,
            } },
        };
    }

    pub fn clone(self: Response, allocator: std.mem.Allocator) !Response {
        if (self.runtime != .none) return error.UnsupportedRuntimeClone;
        switch (self.body_kind) {
            .buffered => {},
            .stream, .sse, .file => return error.UnsupportedRuntimeClone,
        }

        const content_type = try allocator.dupe(u8, self.content_type);
        errdefer allocator.free(content_type);
        const body_bytes = try allocator.dupe(u8, self.bodyBytes());
        errdefer allocator.free(body_bytes);
        const location = if (self.location) |value| try allocator.dupe(u8, value) else null;
        errdefer if (location) |value| allocator.free(value);
        const allow = if (self.allow) |value| try allocator.dupe(u8, value) else null;
        errdefer if (allow) |value| allocator.free(value);

        var cloned: Response = .{
            .status = self.status,
            .content_type = content_type,
            .body_kind = .{ .buffered = body_bytes },
            .head_only = self.head_only,
            .location = location,
            .allow = allow,
            .owned_allocator = allocator,
        };
        errdefer cloned.deinit();

        for (self.extraHeaders()) |extra_header| {
            const owned_name = try allocator.dupe(u8, extra_header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, extra_header.value);
            errdefer allocator.free(owned_value);
            try cloned.appendExtraHeader(allocator, .{
                .name = owned_name,
                .value = owned_value,
            });
        }

        return cloned;
    }

    /// Attaches an opaque "scope" whose lifetime is tied to this Response.
    /// `scope_deinit` is invoked exactly once when the Response is `deinit`ed
    /// (or transferred to a successor Response that itself is deinit'd).
    ///
    /// Multiple scopes may be attached (e.g. nested middleware): they form
    /// a linked list and are freed in reverse-attach order on `deinit`. The
    /// `node_allocator` is used to allocate the bookkeeping scope node and
    /// is also used to free that node on deinit.
    pub fn attachScope(
        self: *Response,
        node_allocator: std.mem.Allocator,
        scope_ptr: *anyopaque,
        scope_deinit: *const fn (scope: *anyopaque) void,
    ) std.mem.Allocator.Error!void {
        try self.scopes.attach(node_allocator, scope_ptr, scope_deinit);
    }

    /// Single, uniform ownership-finalization for scopes whose lifetime
    /// must extend until the Response is fully delivered. The framework
    /// calls this after a user handler returns, for both buffered and
    /// streaming bodies - the scope is either attached to the response
    /// (so it lives until delivery completes) or freed immediately.
    ///
    /// On attach failure for a streaming body the scope is freed and the
    /// response is replaced with an internal-error response, because we
    /// cannot let the streaming callback fire against a dangling scope.
    pub fn finalizeScope(
        self: *Response,
        node_allocator: std.mem.Allocator,
        scope_ptr: *anyopaque,
        scope_deinit: *const fn (scope: *anyopaque) void,
    ) void {
        const needs_extension = switch (self.body_kind) {
            .stream, .sse, .file => true,
            .buffered => self.runtime != .none, // websocket etc. also need extension
        };

        if (!needs_extension) {
            scope_deinit(scope_ptr);
            return;
        }

        self.attachScope(node_allocator, scope_ptr, scope_deinit) catch {
            scope_deinit(scope_ptr);
            self.deinit();
            self.* = internalError("scope attach failed");
        };
    }

    pub fn deinit(self: *Response) void {
        self.scopes.deinit();

        // Free response-owned runtime state BEFORE clearing body_kind below.
        // Currently only `.file` may carry an owned path; other runtimes have
        // their state freed via the scope chain above.
        switch (self.body_kind) {
            .file => |runtime| {
                if (runtime.path_owner) |allocator| allocator.free(runtime.path);
            },
            else => {},
        }

        if (self.owned_allocator) |allocator| {
            allocator.free(self.content_type);
            switch (self.body_kind) {
                .buffered => |bytes| allocator.free(bytes),
                else => {},
            }
            if (self.location) |location| allocator.free(location);
            if (self.allow) |allow| allocator.free(allow);
            self.freeExtraHeaderValues(allocator);
        } else if (self.owned_headers_allocator) |allocator| {
            self.freeExtraHeaderValues(allocator);
        }

        self.extra_headers.deinit();
        self.header_allocator = null;
        self.owned_allocator = null;
        self.owned_headers_allocator = null;
        self.runtime = .none;
        self.body_kind = .{ .buffered = "" };
    }

    /// Renders a streaming (`.stream` / `.sse`) response into an owned buffered
    /// `Response` by running the user handler against an in-memory writer.
    /// Used by `App.request` so tests can inspect streaming handlers without
    /// going through the network. For `.buffered` bodies, behaves like `clone`.
    /// On return, the original `self` retains ownership of its runtime context.
    pub fn renderStreamingToBuffered(
        self: *const Response,
        allocator: std.mem.Allocator,
    ) !Response {
        switch (self.body_kind) {
            .buffered => return try self.clone(allocator),
            .stream => |runtime| {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                errdefer aw.deinit();
                var aborted: std.atomic.Value(bool) = .init(false);
                var sw = StreamWriter{
                    .inner = &aw.writer,
                    .aborted = &aborted,
                };
                try runtime.run_fn(runtime.ctx, &sw);
                try aw.writer.flush();
                const bytes = try aw.toOwnedSlice();
                return try buildBufferedClone(self, allocator, bytes);
            },
            .sse => |runtime| {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                errdefer aw.deinit();
                var aborted: std.atomic.Value(bool) = .init(false);
                var sw = StreamWriter{
                    .inner = &aw.writer,
                    .aborted = &aborted,
                };
                var sse_writer = SseWriter{ .stream = &sw };
                try runtime.run_fn(runtime.ctx, &sse_writer);
                try aw.writer.flush();
                const bytes = try aw.toOwnedSlice();
                return try buildBufferedClone(self, allocator, bytes);
            },
            .file => |runtime| {
                // `App.handle`/`App.request` tests route through here: no live
                // server io exists, so we use a short-lived standard fallback
                // just long enough to read the file. Production delivery never
                // hits this branch because the server has its own `.file` path
                // in `sendBody`.
                var io_impl = std.Io.Threaded.init_single_threaded;
                const io = io_impl.io();

                const bytes = readFileRuntimeAlloc(io, allocator, runtime) catch {
                    const empty = try allocator.dupe(u8, "");
                    return try buildBufferedClone(self, allocator, empty);
                };

                return try buildBufferedClone(self, allocator, bytes);
            },
        }
    }

    /// Builds an owned buffered `Response` carrying `body_bytes` (already
    /// allocator-owned). Headers/content-type/location/allow are duped from
    /// `source`. Takes ownership of `body_bytes` on success; frees on error.
    fn buildBufferedClone(
        source: *const Response,
        allocator: std.mem.Allocator,
        body_bytes: []u8,
    ) !Response {
        errdefer allocator.free(body_bytes);

        var cloned: Response = .{
            .status = source.status,
            .content_type = try allocator.dupe(u8, source.content_type),
            .body_kind = .{ .buffered = body_bytes },
            .head_only = source.head_only,
            .location = if (source.location) |location| try allocator.dupe(u8, location) else null,
            .allow = if (source.allow) |allow| try allocator.dupe(u8, allow) else null,
            .owned_allocator = allocator,
        };
        errdefer cloned.deinit();

        for (source.extraHeaders()) |extra_header| {
            const owned_name = try allocator.dupe(u8, extra_header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, extra_header.value);
            errdefer allocator.free(owned_value);
            try cloned.appendExtraHeader(allocator, .{
                .name = owned_name,
                .value = owned_value,
            });
        }

        return cloned;
    }

    pub fn ensureOwned(self: *Response, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.owned_allocator != null) return;

        const owned_content_type = try allocator.dupe(u8, self.content_type);
        errdefer allocator.free(owned_content_type);
        const owned_body = switch (self.body_kind) {
            .buffered => |bytes| try allocator.dupe(u8, bytes),
            else => "",
        };
        errdefer switch (self.body_kind) {
            .buffered => allocator.free(owned_body),
            else => {},
        };
        const owned_location = if (self.location) |location| try allocator.dupe(u8, location) else null;
        errdefer if (owned_location) |location| allocator.free(location);
        const owned_allow = if (self.allow) |allow| try allocator.dupe(u8, allow) else null;
        errdefer if (owned_allow) |allow| allocator.free(allow);

        var owned_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        errdefer {
            for (owned_headers.items) |owned_header| {
                allocator.free(owned_header.name);
                allocator.free(owned_header.value);
            }
            owned_headers.deinit(allocator);
        }

        for (self.extraHeaders()) |extra_header| {
            const owned_name = try allocator.dupe(u8, extra_header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, extra_header.value);
            errdefer allocator.free(owned_value);
            try owned_headers.append(allocator, .{
                .name = owned_name,
                .value = owned_value,
            });
        }

        if (self.owned_headers_allocator) |header_allocator| {
            self.freeExtraHeaderValues(header_allocator);
        }

        self.content_type = owned_content_type;
        if (self.body_kind == .buffered) self.body_kind = .{ .buffered = owned_body };
        self.location = owned_location;
        self.allow = owned_allow;
        self.extra_headers.replaceWithOwnedOverflow(allocator, owned_headers);
        self.header_allocator = null;
        self.owned_allocator = allocator;
        self.owned_headers_allocator = null;
    }

    pub fn ensureExtraHeadersOwned(self: *Response, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.owned_allocator != null or self.owned_headers_allocator != null) return;

        var owned_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        errdefer {
            for (owned_headers.items) |owned_header| {
                allocator.free(owned_header.name);
                allocator.free(owned_header.value);
            }
            owned_headers.deinit(allocator);
        }

        for (self.extraHeaders()) |extra_header| {
            const owned_name = try allocator.dupe(u8, extra_header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, extra_header.value);
            errdefer allocator.free(owned_value);
            try owned_headers.append(allocator, .{
                .name = owned_name,
                .value = owned_value,
            });
        }

        self.extra_headers.replaceWithOwnedOverflow(allocator, owned_headers);
        self.header_allocator = null;
        self.owned_headers_allocator = allocator;
    }

    fn extraHeaderOwner(self: *const Response) ?std.mem.Allocator {
        return self.owned_allocator orelse self.owned_headers_allocator;
    }

    fn freeExtraHeaderValues(self: *Response, allocator: std.mem.Allocator) void {
        for (self.extraHeaders()) |extra_header| {
            allocator.free(extra_header.name);
            allocator.free(extra_header.value);
        }
    }

    fn replaceBody(self: *Response, value: []const u8) std.mem.Allocator.Error!void {
        const owned_value = if (self.owned_allocator) |allocator|
            try allocator.dupe(u8, value)
        else
            value;
        errdefer if (self.owned_allocator) |allocator| allocator.free(owned_value);

        self.freeBodyRuntime();
        if (self.owned_allocator) |allocator| {
            switch (self.body_kind) {
                .buffered => |bytes| allocator.free(bytes),
                else => {},
            }
        }
        self.body_kind = .{ .buffered = owned_value };
    }

    fn freeBodyRuntime(self: *Response) void {
        switch (self.body_kind) {
            .file => |runtime| {
                if (runtime.path_owner) |allocator| allocator.free(runtime.path);
            },
            else => {},
        }
    }

    fn replaceSlice(self: *Response, field: *[]const u8, value: []const u8) std.mem.Allocator.Error!void {
        if (self.owned_allocator) |allocator| {
            const owned_value = try allocator.dupe(u8, value);
            allocator.free(field.*);
            field.* = owned_value;
            return;
        }
        field.* = value;
    }

    fn replaceOptionalSlice(self: *Response, field: *?[]const u8, value: []const u8) std.mem.Allocator.Error!void {
        if (self.owned_allocator) |allocator| {
            const owned_value = try allocator.dupe(u8, value);
            if (field.*) |existing| allocator.free(existing);
            field.* = owned_value;
            return;
        }
        field.* = value;
    }

    fn clearSlice(self: *Response, field: *[]const u8) void {
        if (self.owned_allocator) |allocator| {
            allocator.free(field.*);
        }
        field.* = "";
    }

    fn clearOptionalSlice(self: *Response, field: *?[]const u8) void {
        if (self.owned_allocator) |allocator| {
            if (field.*) |existing| allocator.free(existing);
        }
        field.* = null;
    }

    fn replaceHeader(
        self: *Response,
        entry: *std.http.Header,
        name: []const u8,
        value: []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.extraHeaderOwner()) |allocator| {
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);

            allocator.free(entry.name);
            allocator.free(entry.value);
            entry.* = .{
                .name = owned_name,
                .value = owned_value,
            };
            return;
        }

        entry.* = .{
            .name = name,
            .value = value,
        };
    }
};

fn readFileRuntimeAlloc(io: std.Io, allocator: std.mem.Allocator, runtime: FileRuntime) ![]u8 {
    if (runtime.head_only) return try allocator.dupe(u8, "");

    var opened_file = try std.Io.Dir.cwd().openFile(io, runtime.path, .{});
    defer opened_file.close(io);

    var read_buf: [8192]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(opened_file, io, &read_buf);
    const file_size = try file_reader.getSize();

    if (runtime.offset > file_size) return try allocator.dupe(u8, "");

    const remaining = file_size - runtime.offset;
    if (runtime.length) |length| {
        if (length > remaining) return try allocator.dupe(u8, "");
    }

    const content_length = runtime.length orelse remaining;
    if (content_length > runtime.max_bytes) return try allocator.dupe(u8, "");
    const len = std.math.cast(usize, content_length) orelse return error.StreamTooLong;

    if (runtime.offset != 0) try file_reader.seekTo(runtime.offset);

    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try file_reader.interface.readSliceAll(bytes);
    return bytes;
}

pub fn isAllowedResponseHeader(name: []const u8) bool {
    return !http_names.isDisallowedResponseHeader(name);
}

pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!isHeaderTokenChar(byte)) return false;
    }
    return true;
}

fn isHeaderTokenChar(byte: u8) bool {
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

pub fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\r' or byte == '\n') return false;
        if (byte < 0x20 and byte != '\t') return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

pub fn generateCookie(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    cookie_options: CookieOptions,
) CookieError![]const u8 {
    try validateCookieName(name);
    try validateCookieValue(value);
    try validateCookieOptions(name, cookie_options);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try appendCookieName(&out, name, cookie_options.prefix);
    try writeByteAllocating(&out, '=');
    try writeAllAllocating(&out, value);

    if (cookie_options.path) |path| {
        try writeAllAllocating(&out, "; Path=");
        try writeAllAllocating(&out, path);
    }
    if (cookie_options.domain) |domain| {
        try writeAllAllocating(&out, "; Domain=");
        try writeAllAllocating(&out, domain);
    }
    if (cookie_options.max_age) |max_age| {
        try printAllocating(&out, "; Max-Age={d}", .{max_age});
    }
    if (cookie_options.expires) |expires| {
        const formatted = try formatCookieExpires(allocator, expires);
        defer allocator.free(formatted);
        try writeAllAllocating(&out, "; Expires=");
        try writeAllAllocating(&out, formatted);
    }
    if (cookie_options.http_only) {
        try writeAllAllocating(&out, "; HttpOnly");
    }
    if (cookie_options.secure) {
        try writeAllAllocating(&out, "; Secure");
    }
    if (cookie_options.same_site) |same_site| {
        try writeAllAllocating(&out, "; SameSite=");
        try writeAllAllocating(&out, sameSiteName(same_site));
    }
    if (cookie_options.priority) |priority| {
        try writeAllAllocating(&out, "; Priority=");
        try writeAllAllocating(&out, priorityName(priority));
    }
    if (cookie_options.partitioned) {
        try writeAllAllocating(&out, "; Partitioned");
    }

    return try out.toOwnedSlice();
}

pub fn generateDeleteCookie(
    allocator: std.mem.Allocator,
    name: []const u8,
    delete_options: DeleteCookieOptions,
) CookieError![]const u8 {
    return try generateCookie(allocator, name, "", .{
        .domain = delete_options.domain,
        .expires = .{ .secs = 0 },
        .max_age = 0,
        .path = delete_options.path,
        .secure = delete_options.secure,
        .prefix = delete_options.prefix,
    });
}

pub fn body(status: std.http.Status, content_type: []const u8, content: []const u8) Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body_kind = .{ .buffered = content },
    };
}

pub fn html(content: []const u8) Response {
    return @This().body(.ok, "text/html; charset=utf-8", content);
}

pub fn json(content: []const u8) Response {
    return @This().body(.ok, "application/json; charset=utf-8", content);
}

pub fn text(status: std.http.Status, content: []const u8) Response {
    return @This().body(status, "text/plain; charset=utf-8", content);
}

pub fn notFound() Response {
    return text(.not_found, "Not Found");
}

pub fn redirect(method: std.http.Method, location: []const u8) Response {
    return redirectWithPermanentStatus(method == .GET or method == .HEAD, location);
}

pub fn redirectForMethodName(method_name: []const u8, location: []const u8) Response {
    return redirectWithPermanentStatus(http_method.isGetOrHead(method_name), location);
}

fn redirectWithPermanentStatus(can_rewrite_to_get: bool, location: []const u8) Response {
    return .{
        .status = if (can_rewrite_to_get) .moved_permanently else .permanent_redirect,
        .content_type = "",
        .location = location,
    };
}

pub fn options(allow: []const u8) Response {
    return .{
        .status = .no_content,
        .content_type = "",
        .allow = allow,
    };
}

pub fn methodNotAllowed(allow: []const u8) Response {
    return .{
        .status = .method_not_allowed,
        .content_type = "text/plain; charset=utf-8",
        .body_kind = .{ .buffered = "Method Not Allowed" },
        .allow = allow,
    };
}

pub fn internalError(message: []const u8) Response {
    return text(.internal_server_error, message);
}

pub fn websocketRuntime(runtime: WebSocketRuntime) Response {
    return .{
        .status = .switching_protocols,
        .content_type = "",
        .runtime = .{ .websocket = runtime },
    };
}

/// Build a streaming response. Pass an explicit `content_length` if you know
/// the body size up front; otherwise the server will use chunked encoding.
pub fn stream(content_type: []const u8, runtime: StreamRuntime) Response {
    return .{
        .status = .ok,
        .content_type = content_type,
        .body_kind = .{ .stream = runtime },
    };
}

/// Build a Server-Sent Events response. Sets `text/event-stream` and arranges
/// for chunked delivery of framed events.
pub fn sse(runtime: SseRuntime) Response {
    return .{
        .status = .ok,
        .content_type = "text/event-stream; charset=utf-8",
        .body_kind = .{ .sse = runtime },
    };
}

/// Build a streaming file response. The server opens `path` (relative to
/// `std.Io.Dir.cwd()`), stats it for `Content-Length` unless `known_size` is
/// supplied, and pumps bytes from the file into the body writer - no full read
/// into memory. `content_type` sets the response's `Content-Type`; pass
/// `"application/octet-stream"` as a safe default when you don't know.
///
/// `max_bytes` caps the streamed byte window. Set `head_only = true` to emit
/// the same headers for `HEAD` with no body. `offset`/`length` can describe a
/// bounded byte window for range-style responses.
pub fn file(path: []const u8, content_type: []const u8, file_options: FileOptions) Response {
    return Response.file(path, content_type, file_options);
}

pub const FileOptions = struct {
    status: std.http.Status = .ok,
    max_bytes: u64 = std.math.maxInt(u64),
    head_only: bool = false,
    /// Byte offset within the file where delivery starts.
    offset: u64 = 0,
    /// Exact number of bytes to stream. `null` streams from `offset` to EOF.
    length: ?u64 = null,
    /// Optional known total file size. Only set this when the file size is
    /// stable until response delivery; otherwise the server should stat the
    /// opened file to keep framing correct.
    known_size: ?u64 = null,
};

pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    return typedJsonAlloc(allocator, value) catch internalError("json write failed");
}

fn typedJsonAlloc(allocator: std.mem.Allocator, value: anytype) !Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(value);
    try out.writer.flush();
    const body_bytes = try out.toOwnedSlice();
    errdefer allocator.free(body_bytes);
    const content_type = try allocator.dupe(u8, "application/json; charset=utf-8");
    return .{
        .status = .ok,
        .content_type = content_type,
        .body_kind = .{ .buffered = body_bytes },
        .owned_allocator = allocator,
    };
}

pub fn parseJson(comptime T: type, req: Request) !?std.json.Parsed(T) {
    return try req.jsonParsed(T);
}

fn validateCookieOptions(name: []const u8, cookie_options: CookieOptions) CookieError!void {
    const secure_prefixed = std.mem.startsWith(u8, name, "__Secure-") or cookie_options.prefix == .secure;
    const host_prefixed = std.mem.startsWith(u8, name, "__Host-") or cookie_options.prefix == .host;

    if (secure_prefixed and !cookie_options.secure) return error.SecurePrefixRequiresSecure;
    if (host_prefixed) {
        if (!cookie_options.secure) return error.HostPrefixRequiresSecure;
        if (cookie_options.domain != null) return error.HostPrefixDisallowsDomain;
        if (!std.mem.eql(u8, cookie_options.path orelse "", "/")) return error.HostPrefixRequiresPathRoot;
    }
    if (cookie_options.path) |path| try validateCookiePath(path);
    if (cookie_options.domain) |domain| try validateCookieDomain(domain);
    if (cookie_options.same_site == .none and !cookie_options.secure) return error.SameSiteNoneRequiresSecure;
    if (cookie_options.partitioned and !cookie_options.secure) return error.PartitionedRequiresSecure;

    if (cookie_options.max_age) |max_age| {
        if (max_age > 34_560_000) return error.MaxAgeTooLong;
    }

    if (cookie_options.expires) |expires| {
        const now = time.nowSeconds();
        if (expires.secs > now and expires.secs - now > 34_560_000) return error.ExpiresTooFar;
    }
}

fn validateCookiePath(path: []const u8) CookieError!void {
    for (path) |byte| {
        switch (byte) {
            0...31, 127, ';' => return error.InvalidCookiePath,
            else => {},
        }
    }
}

fn validateCookieDomain(domain_value: []const u8) CookieError!void {
    if (domain_value.len == 0 or domain_value.len > 253) return error.InvalidCookieDomain;

    var domain = domain_value;
    if (domain[0] == '.') {
        if (domain.len == 1) return error.InvalidCookieDomain;
        domain = domain[1..];
    }
    if (domain[domain.len - 1] == '.') return error.InvalidCookieDomain;

    var label_start: usize = 0;
    for (domain, 0..) |byte, index| {
        if (byte == '.') {
            try validateCookieDomainLabel(domain[label_start..index]);
            label_start = index + 1;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return error.InvalidCookieDomain;
    }
    try validateCookieDomainLabel(domain[label_start..]);
}

fn validateCookieDomainLabel(label: []const u8) CookieError!void {
    if (label.len == 0 or label.len > 63) return error.InvalidCookieDomain;
    if (!std.ascii.isAlphanumeric(label[0])) return error.InvalidCookieDomain;
    if (!std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidCookieDomain;
}

fn validateCookieName(name: []const u8) CookieError!void {
    if (name.len == 0) return error.InvalidCookieName;

    for (name) |byte| {
        switch (byte) {
            0...32, 127 => return error.InvalidCookieName,
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return error.InvalidCookieName,
            else => {},
        }
    }
}

fn validateCookieValue(value: []const u8) CookieError!void {
    for (value) |byte| {
        switch (byte) {
            0...32, 127, ';', ',', '"', '\\' => return error.InvalidCookieValue,
            else => {},
        }
    }
}

fn appendCookieName(
    out: *std.Io.Writer.Allocating,
    name: []const u8,
    prefix: ?CookiePrefix,
) std.mem.Allocator.Error!void {
    switch (prefix orelse {
        try writeAllAllocating(out, name);
        return;
    }) {
        .secure => try writeAllAllocating(out, "__Secure-"),
        .host => try writeAllAllocating(out, "__Host-"),
    }
    try writeAllAllocating(out, name);
}

fn writeAllAllocating(out: *std.Io.Writer.Allocating, bytes: []const u8) std.mem.Allocator.Error!void {
    out.writer.writeAll(bytes) catch unreachable;
}

fn writeByteAllocating(out: *std.Io.Writer.Allocating, byte: u8) std.mem.Allocator.Error!void {
    out.writer.writeByte(byte) catch unreachable;
}

fn printAllocating(
    out: *std.Io.Writer.Allocating,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    out.writer.print(fmt, args) catch unreachable;
}

fn formatCookieExpires(allocator: std.mem.Allocator, expires: EpochSeconds) std.mem.Allocator.Error![]const u8 {
    const weekday_names = [_][]const u8{
        "Sun",
        "Mon",
        "Tue",
        "Wed",
        "Thu",
        "Fri",
        "Sat",
    };
    const month_names = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };

    const epoch_day = expires.getEpochDay();
    const day_seconds = expires.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekday_index: usize = @intCast((epoch_day.day + 4) % 7);

    return try std.fmt.allocPrint(
        allocator,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekday_names[weekday_index],
            month_day.day_index + 1,
            month_names[@intFromEnum(month_day.month) - 1],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn sameSiteName(same_site: SameSite) []const u8 {
    return switch (same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
    };
}

fn priorityName(priority: CookiePriority) []const u8 {
    return switch (priority) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
    };
}

test "typedJson serializes into response body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = typedJson(arena.allocator(), .{ .ok = true });

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.bodyBytes());
}

test "redirect chooses 301 for GET and HEAD and 308 otherwise" {
    const get_res = redirect(.GET, "/users");
    const head_res = redirect(.HEAD, "/users");
    const post_res = redirect(.POST, "/users");
    const purge_res = redirectForMethodName("PURGE", "/users");

    try std.testing.expectEqual(std.http.Status.moved_permanently, get_res.status);
    try std.testing.expectEqual(std.http.Status.moved_permanently, head_res.status);
    try std.testing.expectEqual(std.http.Status.permanent_redirect, post_res.status);
    try std.testing.expectEqual(std.http.Status.permanent_redirect, purge_res.status);
    try std.testing.expectEqualStrings("/users", get_res.location.?);
}

test "response inline headers support overwrite and append" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("cache-control", "max-age=60"));
    try std.testing.expect(res.header("Cache-Control", "no-store"));
    try std.testing.expect(res.header("content-type", "application/problem+json"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));
    try std.testing.expect(res.appendHeader("set-cookie", "b=2"));

    const headers = res.extraHeaders();
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("no-store", headers[0].value);
    try std.testing.expectEqualStrings("a=1", headers[1].value);
    try std.testing.expectEqualStrings("b=2", headers[2].value);
}

test "response rejects unsafe and framing headers" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(!res.header("x-bad\r\nname", "ok"));
    try std.testing.expect(!res.header("x-test", "ok\r\nx-evil: 1"));
    try std.testing.expect(!res.header("content-length", "999"));
    try std.testing.expect(!res.header("transfer-encoding", "chunked"));
    try std.testing.expect(!res.header("connection", "keep-alive"));
    try std.testing.expect(!res.header("content-type", "text/plain\r\nx-evil: 1"));
    try std.testing.expectEqual(@as(usize, 0), res.extraHeaders().len);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type);
}

test "response deleteHeader removes special and extra headers" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.header("content-type", "application/problem+json"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));
    try std.testing.expect(res.appendHeader("set-cookie", "b=2"));

    try std.testing.expect(res.deleteHeader("cache-control"));
    try std.testing.expect(res.deleteHeader("content-type"));
    try std.testing.expect(res.deleteHeader("set-cookie"));
    try std.testing.expect(!res.deleteHeader("missing"));

    try std.testing.expectEqualStrings("", res.content_type);
    try std.testing.expectEqual(@as(usize, 0), res.extraHeaders().len);
}

test "response body helper builds arbitrary content types" {
    const res = body(.created, "application/problem+json", "{\"ok\":false}");

    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":false}", res.bodyBytes());
}

test "response file render buffers only the selected byte window" {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file_path = ".zig-cache/zono-response-window-test.txt";

    var test_file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    var file_buffer: [64]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(test_file, io, &file_buffer);
    try file_writer.interface.writeAll("abcdefghijklmnopqrstuvwxyz");
    try file_writer.end();
    test_file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var res = file(file_path, "text/plain", .{
        .offset = 20,
        .length = 3,
        .max_bytes = 3,
    });
    defer res.deinit();

    var buffered = try res.renderStreamingToBuffered(std.testing.allocator);
    defer buffered.deinit();

    try std.testing.expectEqualStrings("uvw", buffered.bodyBytes());
}

test "websocket readMessageAlloc reassembles fragmented masked messages" {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendMaskedWsFrame(std.testing.allocator, &bytes, 0x01, "hel");
    try appendMaskedWsFrame(std.testing.allocator, &bytes, 0x80, "lo");

    var reader = std.Io.Reader.fixed(bytes.items);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var raw_socket = std.http.Server.WebSocket{
        .key = "",
        .input = &reader,
        .output = &output.writer,
    };
    var socket = WebSocketConnection{ .socket = &raw_socket };

    var message = try socket.readMessageAlloc(std.testing.allocator, 1024);
    defer message.deinit();

    try std.testing.expectEqual(std.http.Server.WebSocket.Opcode.text, message.opcode);
    try std.testing.expectEqualStrings("hello", message.data);
}

test "websocket readMessageAlloc handles larger masked messages" {
    const payload = try std.testing.allocator.alloc(u8, 512);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendMaskedWsFrame(std.testing.allocator, &bytes, 0x82, payload);

    var reader = std.Io.Reader.fixed(bytes.items);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var raw_socket = std.http.Server.WebSocket{
        .key = "",
        .input = &reader,
        .output = &output.writer,
    };
    var socket = WebSocketConnection{ .socket = &raw_socket };

    var message = try socket.readMessageAlloc(std.testing.allocator, 1024);
    defer message.deinit();

    try std.testing.expectEqual(std.http.Server.WebSocket.Opcode.binary, message.opcode);
    try std.testing.expectEqualStrings(payload, message.data);
}

test "websocket readMessageAlloc enforces max_message_bytes across fragments" {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendMaskedWsFrame(std.testing.allocator, &bytes, 0x01, "1234");
    try appendMaskedWsFrame(std.testing.allocator, &bytes, 0x80, "5678");

    var reader = std.Io.Reader.fixed(bytes.items);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var raw_socket = std.http.Server.WebSocket{
        .key = "",
        .input = &reader,
        .output = &output.writer,
    };
    var socket = WebSocketConnection{
        .socket = &raw_socket,
        .max_message_bytes = 6,
    };

    try std.testing.expectError(error.MessageTooLarge, socket.readMessageAlloc(std.testing.allocator, 1024));
}

fn appendMaskedWsFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first_byte: u8,
    payload: []const u8,
) !void {
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try out.append(allocator, first_byte);
    if (payload.len <= 125) {
        try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try out.append(allocator, 0x80 | 126);
        try out.append(allocator, @intCast(payload.len >> 8));
        try out.append(allocator, @intCast(payload.len & 0xff));
    } else {
        return error.TestPayloadTooLarge;
    }
    try out.appendSlice(allocator, &mask);
    for (payload, 0..) |byte, index| {
        try out.append(allocator, byte ^ mask[index % 4]);
    }
}

test "generateCookie formats common attributes" {
    const cookie = try generateCookie(std.testing.allocator, "session", "abc123", .{
        .domain = "example.com",
        .http_only = true,
        .max_age = 3600,
        .path = "/",
        .priority = .high,
        .same_site = .strict,
        .secure = true,
        .partitioned = true,
    });
    defer std.testing.allocator.free(cookie);

    try std.testing.expectEqualStrings(
        "session=abc123; Path=/; Domain=example.com; Max-Age=3600; HttpOnly; Secure; SameSite=Strict; Priority=High; Partitioned",
        cookie,
    );
}

test "generateDeleteCookie emits an expired cookie header value" {
    const cookie = try generateDeleteCookie(std.testing.allocator, "session", .{});
    defer std.testing.allocator.free(cookie);

    try std.testing.expectEqualStrings(
        "session=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
        cookie,
    );
}

test "generateCookie validates host prefix requirements" {
    try std.testing.expectError(
        error.HostPrefixRequiresSecure,
        generateCookie(std.testing.allocator, "session", "abc123", .{
            .prefix = .host,
        }),
    );

    try std.testing.expectError(
        error.SecurePrefixRequiresSecure,
        generateCookie(std.testing.allocator, "__Secure-session", "abc123", .{}),
    );
    try std.testing.expectError(
        error.MaxAgeTooLong,
        generateCookie(std.testing.allocator, "session", "abc123", .{
            .max_age = 34_560_001,
        }),
    );
}

test "generateCookie rejects unsafe cookie attributes" {
    try std.testing.expectError(error.InvalidCookiePath, generateCookie(std.testing.allocator, "session", "abc", .{
        .path = "/app; HttpOnly",
    }));
    try std.testing.expectError(error.InvalidCookieDomain, generateCookie(std.testing.allocator, "session", "abc", .{
        .domain = "bad/domain.example",
    }));
    try std.testing.expectError(error.SameSiteNoneRequiresSecure, generateCookie(std.testing.allocator, "session", "abc", .{
        .same_site = .none,
    }));
    try std.testing.expectError(error.PartitionedRequiresSecure, generateCookie(std.testing.allocator, "session", "abc", .{
        .partitioned = true,
    }));
}

test "response cookie helpers append set-cookie headers" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try res.cookie(std.testing.allocator, "session", "abc123", .{
        .http_only = true,
        .secure = true,
    });
    try res.deleteCookie(std.testing.allocator, "theme", .{});

    const headers = res.extraHeaders();
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("set-cookie", headers[0].name);
    try std.testing.expectEqualStrings(
        "session=abc123; HttpOnly; Secure",
        headers[0].value,
    );
    try std.testing.expectEqualStrings(
        "theme=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
        headers[1].value,
    );
}

test "response cookie helpers own headers without copying borrowed body" {
    const body_bytes = "borrowed response body";
    var res = text(.ok, body_bytes);
    defer res.deinit();

    const body_ptr = res.bodyBytes().ptr;
    try res.cookie(std.testing.allocator, "session", "abc123", .{});

    try std.testing.expectEqual(@as(?std.mem.Allocator, null), res.owned_allocator);
    try std.testing.expect(res.owned_headers_allocator != null);
    try std.testing.expectEqual(body_ptr, res.bodyBytes().ptr);
    try std.testing.expectEqualStrings(body_bytes, res.bodyBytes());
    try std.testing.expectEqualStrings("session=abc123", res.headerValue("set-cookie").?);
}

test "response keeps small extra header sets inline" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("x-a", "1"));
    try std.testing.expect(res.header("x-b", "2"));
    try std.testing.expect(res.header("x-c", "3"));
    try std.testing.expect(res.header("x-d", "4"));
    try std.testing.expect(res.header("x-e", "5"));
    try std.testing.expect(res.header("x-f", "6"));

    try std.testing.expectEqual(@as(usize, 6), res.extraHeaders().len);
    try std.testing.expect(!res.extra_headers.usesOverflow());

    try std.testing.expect(!res.header("x-g", "7"));
    try std.testing.expectEqual(@as(usize, 6), res.extraHeaders().len);
    try std.testing.expect(!res.extra_headers.usesOverflow());

    res.header_allocator = std.testing.allocator;
    try std.testing.expect(res.header("x-g", "7"));
    try std.testing.expectEqual(@as(usize, 7), res.extraHeaders().len);
    try std.testing.expect(res.extra_headers.usesOverflow());
}

test "response clone owns duplicated data" {
    var res = text(.accepted, "ok");
    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.accepted, cloned.status);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", cloned.content_type);
    try std.testing.expectEqualStrings("ok", cloned.bodyBytes());
    try std.testing.expectEqual(@as(usize, 2), cloned.extraHeaders().len);
    try std.testing.expectEqualStrings("no-store", cloned.extraHeaders()[0].value);
    try std.testing.expectEqualStrings("a=1", cloned.extraHeaders()[1].value);
}

test "response clone stays safe to mutate after cloning" {
    var res = text(.ok, "ok");
    defer res.deinit();

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expect(cloned.header("content-type", "application/problem+json"));
    try std.testing.expect(cloned.header("cache-control", "no-store"));
    try cloned.cookie(std.testing.allocator, "session", "abc123", .{
        .http_only = true,
    });

    try std.testing.expectEqualStrings("application/problem+json", cloned.content_type);
    try std.testing.expectEqual(@as(usize, 2), cloned.extraHeaders().len);
    try std.testing.expectEqualStrings("no-store", cloned.extraHeaders()[0].value);
    try std.testing.expectEqualStrings(
        "session=abc123; HttpOnly",
        cloned.extraHeaders()[1].value,
    );
}

test "response clone stays safe to delete headers after cloning" {
    var res = text(.ok, "ok");
    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.header("location", "/next"));

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();
    defer res.deinit();

    cloned.setStatus(.created);
    try std.testing.expect(cloned.deleteHeader("cache-control"));
    try std.testing.expect(cloned.deleteHeader("location"));

    try std.testing.expectEqual(std.http.Status.created, cloned.status);
    try std.testing.expectEqual(@as(usize, 0), cloned.extraHeaders().len);
    try std.testing.expect(cloned.location == null);
}

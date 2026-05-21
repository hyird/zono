const builtin = @import("builtin");
const std = @import("std");
const zio = @import("zio");
const Io = std.Io;
const Atomic = std.atomic.Value;
const App = @import("../app/app.zig").App;
const request_mod = @import("../request/request.zig");
const Request = request_mod.Request;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const RequestPool = @import("request_pool.zig").RequestPool;
const path_mod = @import("../core/path.zig");
const http_names = @import("../core/http_names.zig");
const request_target = @import("../core/request_target.zig");
const time = @import("../core/time.zig");

pub const ZioRuntime = zio.Runtime;

const IoBackend = enum {
    generic,
    zio,
};

const ReadDeadlineMode = enum {
    none,
    socket,
    select,
    watchdog,
    zio_auto_cancel,
};

pub const Options = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    address: std.Io.net.IpAddress,
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 64 * 1024,
    /// Maximum bytes accepted in a single request body. Requests exceeding
    /// this limit receive `413 Payload Too Large` and the connection is
    /// closed (no follow-up keep-alive request is processed).
    max_body_bytes: usize = 4 * 1024 * 1024,
    /// Maximum body bytes to materialize into `Request.bodyBytes()` before handler
    /// dispatch. Bodies larger than this threshold are exposed through
    /// `Request.bodyReader()` and drained after the handler if needed.
    /// Set to `0` to stream every request body. The default matches the
    /// default `max_body_bytes` to preserve the traditional buffered behavior.
    body_buffer_bytes: usize = 4 * 1024 * 1024,
    /// Buffer handed to streaming/SSE writers. Larger values reduce syscalls;
    /// smaller values lower latency for chatty event streams.
    stream_buffer_size: usize = 8 * 1024,
    /// Maximum concurrently accepted connections. `0` means unlimited.
    max_connections: usize = 0,
    /// Maximum in-memory bytes queued for one response before the connection
    /// applies backpressure and closes with 503. `0` disables this check.
    max_write_queue_bytes: usize = 16 * 1024 * 1024,
    /// Idle keep-alive read deadline between completed requests. `0`
    /// disables the idle deadline while still honoring per-request deadlines.
    idle_timeout_ms: u64 = 75_000,
    /// Maximum requests served on one keep-alive connection. `0` is unlimited.
    max_keep_alive_requests: usize = 0,
    /// Maximum header fields accepted before dispatch. `0` disables this
    /// count check, but the parser's read buffer limit still applies.
    max_request_headers: usize = 64,
    /// Maximum summed header name/value bytes accepted before dispatch.
    /// `0` disables this byte check, but `read_buffer_size` still caps the
    /// parsed header block.
    max_request_header_bytes: usize = 16 * 1024,
    /// Maximum request-target bytes (`path?query`) accepted before dispatch.
    max_request_target_bytes: usize = 8 * 1024,
    /// Maximum query string bytes accepted before dispatch.
    max_query_bytes: usize = 16 * 1024,
    /// Maximum slash-delimited path segments accepted before dispatch.
    max_path_segments: usize = 64,
    /// Request-level arena capacity retained between keep-alive requests.
    /// Set to `0` to free all request-pool memory after every request.
    request_pool_retain_bytes: usize = 64 * 1024,
    /// Per-request deadline (milliseconds). Enforced for header/body reads,
    /// propagated to `Request.isAborted()` / `Context.isAborted()` during
    /// handler execution, and checked before response write. `0` disables.
    request_timeout_ms: u64 = 30_000,
    /// On `Server.stop`, wait this long for in-flight connections to finish
    /// before forcibly canceling them. `0` cancels immediately.
    shutdown_drain_ms: u64 = 5_000,
};

pub const Server = struct {
    options: Options,
    /// Pointer to the live listener while `serve` is executing.
    listener: ?*std.Io.net.Server = null,
    stopping: Atomic(bool) = .init(false),
    /// Resolved bound port (0 until `serve` has bound the socket). Useful
    /// for tests that bind to port 0 and need to learn the ephemeral port.
    bound_port: Atomic(u16) = .init(0),
    active_connections: Atomic(usize) = .init(0),

    pub fn init(options: Options) Server {
        return .{ .options = options };
    }

    /// Runs until either an unrecoverable error occurs or `stop`/`requestStop`
    /// requests shutdown. `stop` performs a best-effort loopback connection so
    /// a blocked `accept` wakes and observes the stopping flag.
    pub fn serve(self: *Server, io: Io, app: *App) !void {
        return self.serveWithBackend(io, app, .generic);
    }

    fn serveWithBackend(self: *Server, io: Io, app: *App, backend: IoBackend) !void {
        try app.finalize();

        var listener = try self.options.address.listen(io, .{ .reuse_address = true });
        self.listener = &listener;
        self.bound_port.store(listener.socket.address.getPort(), .release);
        defer {
            self.listener = null;
            self.bound_port.store(0, .release);
            listener.deinit(io);
        }

        var group: Io.Group = .init;
        // Drain semantics: try to await in-flight handlers up to the drain
        // budget. If they do not finish in time, fall back to cancel.
        defer self.drainGroup(io, &group);

        while (true) {
            if (self.stopping.load(.acquire)) break;
            const stream = listener.accept(io) catch |err| switch (err) {
                error.Canceled => break,
                error.SocketNotListening => break,
                error.ConnectionAborted => continue,
                else => return err,
            };
            // Re-check after accept: a self-pipe wakeup (one extra connection
            // delivered after `stop` was called) lets the loop exit without
            // dispatching the dummy connection to a handler.
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                break;
            }
            if (!self.tryReserveConnection()) {
                rejectAcceptedConnection(io, stream, .service_unavailable);
                continue;
            }

            group.concurrent(io, handleConn, .{ io, stream, app, self, self.options, readDeadlineMode(backend) }) catch {
                self.releaseConnection();
                stream.close(io);
            };
        }
    }

    /// Convenience wrapper for the default zono runtime path. `serve` remains
    /// generic over `std.Io`; this just makes the zio-backed path explicit.
    pub fn serveZio(self: *Server, runtime: *zio.Runtime, app: *App) !void {
        return self.serveWithBackend(runtime.io(), app, .zio);
    }

    /// Threadsafe and best-effort. Sets the `stopping` flag, wakes a blocked
    /// `accept` via a loopback connection when a bound port is known, then lets
    /// the serve loop drain or cancel in-flight handlers according to options.
    /// Not signal-handler-safe; use `requestStop` from signal handlers.
    pub fn stop(self: *Server, io: Io) void {
        self.requestStop();
        self.wakeAccept(io);
    }

    /// Signal-handler-friendly stop request. Only flips an atomic flag; it
    /// does not wake a blocked `accept` by itself.
    pub fn requestStop(self: *Server) void {
        _ = self.stopping.swap(true, .acq_rel);
    }

    fn wakeAccept(self: *Server, io: Io) void {
        const port = self.bound_port.load(.acquire);
        if (port == 0) return;

        var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch return;
        addr.setPort(port);
        if (addr.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |_| {}
    }

    pub fn connectionCount(self: *const Server) usize {
        return self.active_connections.load(.acquire);
    }

    fn tryReserveConnection(self: *Server) bool {
        const previous = self.active_connections.fetchAdd(1, .acq_rel);
        if (self.options.max_connections != 0 and previous >= self.options.max_connections) {
            _ = self.active_connections.fetchSub(1, .acq_rel);
            return false;
        }
        return true;
    }

    fn releaseConnection(self: *Server) void {
        _ = self.active_connections.fetchSub(1, .acq_rel);
    }

    fn drainGroup(self: *Server, io: Io, group: *Io.Group) void {
        if (self.options.shutdown_drain_ms == 0) {
            group.cancel(io);
            return;
        }

        // Race: await(group) vs sleep(drain_ms). Whichever wins, cancel the
        // loser. If await wins we exit cleanly; if sleep wins we forcibly
        // cancel any handlers still running.
        const Drain = struct {
            fn awaitGroup(g: *Io.Group, inner_io: Io) Io.Cancelable!void {
                return g.await(inner_io);
            }
            fn sleepFor(inner_io: Io, ms: u64) Io.Cancelable!void {
                return Io.sleep(inner_io, .fromMilliseconds(@intCast(ms)), .awake);
            }
        };

        const DrainSelect = union(enum) {
            await_group: Io.Cancelable!void,
            timer: Io.Cancelable!void,
        };

        var select_buffer: [2]DrainSelect = undefined;
        var select = Io.Select(DrainSelect).init(io, &select_buffer);

        select.concurrent(.await_group, Drain.awaitGroup, .{ group, io }) catch {
            // Could not spawn race task; fall back to cancel.
            group.cancel(io);
            return;
        };
        errdefer select.cancelDiscard();

        select.concurrent(.timer, Drain.sleepFor, .{ io, self.options.shutdown_drain_ms }) catch {
            select.cancelDiscard();
            group.cancel(io);
            return;
        };
        defer select.cancelDiscard();

        switch (select.await() catch {
            group.cancel(io);
            return;
        }) {
            .await_group => |result| {
                result catch {
                    group.cancel(io);
                    return;
                };
            },
            .timer => |result| {
                result catch {};
                group.cancel(io);
            },
        }
    }
};

fn readDeadlineMode(self: IoBackend) ReadDeadlineMode {
    return switch (self) {
        .generic => if (use_socket_read_timeout) .socket else .select,
        // zio keeps request/idle deadlines off the read hot path. A per-connection
        // watchdog closes timed-out sockets while reads use the normal netRead path.
        .zio => .watchdog,
    };
}

// Linux/macOS std.Io backends can enforce a read deadline directly on the
// socket. Windows currently has backend-dependent timed socket read support,
// so it uses the select-based per-read deadline path.
const use_socket_read_timeout = builtin.os.tag != .windows;

const DeadlineWatchdog = struct {
    deadline_ns: Atomic(u64) = .init(0),
    sleeping_until_ns: Atomic(u64) = .init(0),
    epoch: Atomic(u32) = .init(0),
    stopped: Atomic(bool) = .init(false),
    timed_out: Atomic(bool) = .init(false),

    fn arm(self: *DeadlineWatchdog, io: Io, deadline_ns: ?u64, timeout_ms: u64) void {
        const next = deadline_ns orelse 0;
        const current = self.deadline_ns.load(.acquire);
        if (next != 0 and current != 0 and next > current and !self.timed_out.load(.monotonic)) {
            const slack_ns = deadlineCoalesceNs(timeout_ms);
            if (next - current <= slack_ns) return;
        }

        self.timed_out.store(false, .monotonic);
        self.deadline_ns.store(next, .release);

        const sleeping_until = self.sleeping_until_ns.load(.acquire);
        if ((sleeping_until == 0 and next != 0) or
            (sleeping_until != 0 and (next == 0 or next < sleeping_until)))
        {
            self.wake(io);
        }
    }

    fn stop(self: *DeadlineWatchdog, io: Io) void {
        self.stopped.store(true, .release);
        self.wake(io);
    }

    fn timedOut(self: *const DeadlineWatchdog) bool {
        return self.timed_out.load(.acquire);
    }

    fn wake(self: *DeadlineWatchdog, io: Io) void {
        _ = self.epoch.fetchAdd(1, .acq_rel);
        io.futexWake(u32, &self.epoch.raw, 1);
    }
};

fn deadlineCoalesceNs(timeout_ms: u64) u64 {
    if (timeout_ms == 0) return 0;
    const timeout_ns = std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch return 100 * std.time.ns_per_ms;
    return @min(timeout_ns / 16, 100 * std.time.ns_per_ms);
}

fn runDeadlineWatchdog(io: Io, stream: Io.net.Stream, watchdog: *DeadlineWatchdog) Io.Cancelable!void {
    while (!watchdog.stopped.load(.acquire)) {
        const epoch = watchdog.epoch.load(.acquire);
        const deadline_ns = watchdog.deadline_ns.load(.acquire);
        if (deadline_ns == 0) {
            watchdog.sleeping_until_ns.store(0, .release);
            io.futexWait(u32, &watchdog.epoch.raw, epoch) catch |err| switch (err) {
                error.Canceled => return,
            };
            continue;
        }

        const now_ns = time.nowNanoseconds();
        if (now_ns >= deadline_ns) {
            if (!watchdog.stopped.load(.acquire) and watchdog.deadline_ns.load(.acquire) == deadline_ns) {
                watchdog.timed_out.store(true, .release);
                stream.shutdown(io, .both) catch {};
                return;
            }
            continue;
        }

        watchdog.sleeping_until_ns.store(deadline_ns, .release);
        io.futexWaitTimeout(u32, &watchdog.epoch.raw, epoch, watchdogTimeout(deadline_ns - now_ns)) catch |err| switch (err) {
            error.Canceled => return,
        };
    }
}

fn watchdogTimeout(remaining_ns: u64) Io.Timeout {
    return .{ .duration = .{
        .raw = .fromNanoseconds(@intCast(remaining_ns)),
        .clock = .awake,
    } };
}

const ServerStreamReader = struct {
    io: Io,
    interface: Io.Reader,
    stream: Io.net.Stream,
    timeout_ms: u64,
    deadline_mode: ReadDeadlineMode,
    deadline: ?Io.Clock.Timestamp = null,
    watchdog: ?*DeadlineWatchdog = null,
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    fn init(stream: Io.net.Stream, io: Io, buffer: []u8, timeout_ms: u64, deadline_mode: ReadDeadlineMode) ServerStreamReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
            .deadline_mode = deadline_mode,
        };
    }

    fn armReadDeadline(self: *ServerStreamReader, timeout_ms: u64) void {
        self.err = null;
        if (self.deadline_mode == .watchdog) {
            self.deadline = null;
            if (self.watchdog) |watchdog| watchdog.arm(self.io, time.deadlineFromNowMs(timeout_ms), timeout_ms);
            return;
        }
        if (self.deadline_mode == .none or timeout_ms == 0) {
            self.deadline = null;
            return;
        }
        self.deadline = Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        });
    }

    fn armReadDeadlineNs(self: *ServerStreamReader, deadline_ns: ?u64) void {
        self.err = null;
        if (self.deadline_mode == .watchdog) {
            self.deadline = null;
            if (self.watchdog) |watchdog| watchdog.arm(self.io, deadline_ns, self.timeout_ms);
            return;
        }
        self.armReadDeadline(time.remainingDeadlineMs(deadline_ns));
    }

    fn deadlineExceeded(self: *const ServerStreamReader) bool {
        if (self.deadline_mode == .watchdog) {
            return if (self.watchdog) |watchdog| watchdog.timedOut() else false;
        }
        if (self.deadline) |deadline| {
            return Io.Clock.Timestamp.compare(
                deadline,
                .lte,
                deadline.clock.now(self.io).withClock(deadline.clock),
            );
        }
        return false;
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *ServerStreamReader = @alignCast(@fieldParentPtr("interface", io_r));
        if (r.deadline != null) {
            return switch (r.deadline_mode) {
                .none => readVecUntimed(r, io_r, data),
                .socket => readVecTimedSocket(r, io_r, data),
                .select => readVecTimedSelect(r, io_r, data),
                .watchdog => readVecUntimed(r, io_r, data),
                .zio_auto_cancel => readVecTimedZioAutoCancel(r, io_r, data),
            };
        }
        return readVecUntimed(r, io_r, data);
    }

    fn readVecUntimed(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const n = r.io.vtable.netRead(r.io.userdata, r.stream.socket.handle, dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn readVecTimedZioAutoCancel(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const deadline = r.deadline orelse return readVecUntimed(r, io_r, data);

        var auto_cancel: zio.AutoCancel = .init;
        auto_cancel.set(zio.Timeout.fromStd(.{ .deadline = deadline }));
        defer auto_cancel.clear();

        return readVecUntimed(r, io_r, data) catch |err| {
            if (r.err) |read_err| {
                if (read_err == error.Canceled and auto_cancel.check(error.Canceled)) {
                    r.err = error.Timeout;
                    return error.ReadFailed;
                }
            }
            return err;
        };
    }

    fn readVecTimedSocket(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const deadline = r.deadline orelse return readVecUntimed(r, io_r, data);

        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const message = r.stream.socket.receiveTimeout(r.io, dest[0], .{ .deadline = deadline }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return readVecUntimed(r, io_r, data),
            else => {
                r.err = err;
                return error.ReadFailed;
            },
        };
        const n = message.data.len;
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn readVecTimedSelect(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const deadline = r.deadline orelse return readVecUntimed(r, io_r, data);

        const ReadCtx = struct {
            reader: *ServerStreamReader,
            io_reader: *Io.Reader,
            buffers: [][]u8,
            result: usize = 0,
            err: ?Io.Reader.Error = null,

            fn read(ctx: *@This()) Io.Cancelable!void {
                ctx.result = readVecUntimed(ctx.reader, ctx.io_reader, ctx.buffers) catch |err| {
                    ctx.err = err;
                    return;
                };
            }

            fn timer(io: Io, until: Io.Clock.Timestamp) Io.Cancelable!void {
                return until.wait(io);
            }
        };

        const Race = union(enum) {
            read: Io.Cancelable!void,
            timer: Io.Cancelable!void,
        };

        var ctx = ReadCtx{
            .reader = r,
            .io_reader = io_r,
            .buffers = data,
        };
        var select_buffer: [2]Race = undefined;
        var select = Io.Select(Race).init(r.io, &select_buffer);

        select.concurrent(.read, ReadCtx.read, .{&ctx}) catch {
            return readVecUntimed(r, io_r, data);
        };
        errdefer select.cancelDiscard();

        select.concurrent(.timer, ReadCtx.timer, .{ r.io, deadline }) catch {
            defer select.cancelDiscard();
            const completed = select.await() catch |err| {
                r.err = err;
                return error.ReadFailed;
            };
            return switch (completed) {
                .read => |result| {
                    result catch |err| {
                        r.err = err;
                        return error.ReadFailed;
                    };
                    if (ctx.err) |err| return err;
                    return ctx.result;
                },
                .timer => unreachable,
            };
        };
        defer select.cancelDiscard();

        const completed = select.await() catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        return switch (completed) {
            .read => |result| {
                result catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                if (ctx.err) |err| return err;
                return ctx.result;
            },
            .timer => |result| {
                result catch {};
                r.err = error.Timeout;
                return error.ReadFailed;
            },
        };
    }
};

fn handleConn(io: Io, stream: Io.net.Stream, app: *App, server: *Server, options: Options, deadline_mode: ReadDeadlineMode) Io.Cancelable!void {
    defer server.releaseConnection();
    return runConn(io, stream, app, options, deadline_mode);
}

fn runConn(io: Io, stream: Io.net.Stream, app: *App, options: Options, deadline_mode: ReadDeadlineMode) Io.Cancelable!void {
    defer stream.close(io);

    const allocator = options.allocator;

    var request_pool = RequestPool.init(allocator, options.request_pool_retain_bytes);
    defer request_pool.deinit();

    const read_buffer = allocator.alloc(u8, options.read_buffer_size) catch return;
    defer allocator.free(read_buffer);
    const write_buffer = allocator.alloc(u8, options.write_buffer_size) catch return;
    defer allocator.free(write_buffer);
    var stream_buffer: ?[]u8 = null;
    defer if (stream_buffer) |buffer| allocator.free(buffer);

    var reader = ServerStreamReader.init(stream, io, read_buffer, options.request_timeout_ms, deadline_mode);
    var deadline_watchdog: DeadlineWatchdog = .{};
    var watchdog_future: ?Io.Future(Io.Cancelable!void) = null;
    if (deadline_mode == .watchdog) {
        reader.watchdog = &deadline_watchdog;
        watchdog_future = Io.concurrent(io, runDeadlineWatchdog, .{ io, stream, &deadline_watchdog }) catch null;
        if (watchdog_future == null) reader.deadline_mode = .zio_auto_cancel;
    }
    defer {
        if (watchdog_future) |*future| {
            deadline_watchdog.stop(io);
            _ = future.await(io) catch {};
        }
    }

    var writer = Io.net.Stream.Writer.init(stream, io, write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request_count: usize = 0;

    while (true) {
        if (options.max_keep_alive_requests != 0 and request_count >= options.max_keep_alive_requests) break;

        const initial_request_deadline_ns = if (request_count == 0)
            time.deadlineFromNowMs(options.request_timeout_ms)
        else
            null;
        const head_timeout_ms = if (request_count == 0)
            options.request_timeout_ms
        else
            options.idle_timeout_ms;
        if (initial_request_deadline_ns) |deadline_ns|
            reader.armReadDeadlineNs(deadline_ns)
        else
            reader.armReadDeadline(head_timeout_ms);
        const alloc = request_pool.begin();

        var raw_req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.ReadFailed, error.HttpRequestTruncated => break,
            // Header oversize / malformed → 431/400 if we still can, then close.
            error.HttpHeadersOversize => {
                writeStatusLineAndClose(&writer.interface, .request_header_fields_too_large) catch {};
                drainRejectedHead(&reader.interface, options.max_request_header_bytes) catch {};
                break;
            },
            error.HttpHeadersInvalid => {
                writeStatusLineAndClose(&writer.interface, .bad_request) catch {};
                break;
            },
        };
        const close_after_response = !raw_req.head.keep_alive;
        const request_deadline_ns = initial_request_deadline_ns orelse time.deadlineFromNowMs(options.request_timeout_ms);
        reader.armReadDeadlineNs(request_deadline_ns);

        if (validateRequestHeaders(&raw_req, options)) |_| {
            if (raw_req.head.expect != null) {
                writeStatusLineAndClose(&writer.interface, .request_header_fields_too_large) catch {};
            } else {
                raw_req.respond("Request Header Fields Too Large", .{
                    .status = .request_header_fields_too_large,
                    .keep_alive = false,
                }) catch {};
            }
            break;
        }

        if ((raw_req.head.content_length orelse 0) > options.max_body_bytes) {
            // The size is known from headers, so reject before inviting the
            // peer to upload the payload. This also avoids allocating or
            // draining arbitrarily large bodies just to return 413.
            if (raw_req.head.expect != null) {
                writeStatusLineAndClose(&writer.interface, .payload_too_large) catch {};
            } else {
                raw_req.respond("Payload Too Large", .{
                    .status = .payload_too_large,
                    .keep_alive = false,
                }) catch {};
            }
            break;
        }

        const has_body = raw_req.head.transfer_encoding == .chunked or
            (raw_req.head.content_length orelse 0) > 0;
        const owned_headers = if (has_body)
            collectOwnedHeaders(&raw_req, alloc) catch break
        else
            &[_]std.http.Header{};

        const target = raw_req.head.target;
        if (target.len > options.max_request_target_bytes) {
            const status = requestTargetRejectStatus(.target_too_long);
            if (raw_req.head.expect != null) {
                writeStatusLineAndClose(&writer.interface, status) catch {};
            } else {
                raw_req.respond(status.phrase() orelse "Invalid request target", .{
                    .status = status,
                    .keep_alive = false,
                }) catch {};
            }
            break;
        }

        const split_target = request_target.split(target);
        if (validateSplitRequestTarget(split_target, options)) |reject| {
            const status = requestTargetRejectStatus(reject);
            if (raw_req.head.expect != null) {
                writeStatusLineAndClose(&writer.interface, status) catch {};
            } else {
                raw_req.respond(status.phrase() orelse "Invalid request target", .{
                    .status = status,
                    .keep_alive = false,
                }) catch {};
            }
            break;
        }

        // --- Expect: 100-continue handling ---
        // RFC 7231 §5.1.1: a server MUST respond with either 100 Continue
        // (so the client sends the body) or a final status (typically 417).
        // We accept only the literal "100-continue" token; anything else
        // gets 417 Expectation Failed and the connection is closed.
        if (raw_req.head.expect) |expect_value| {
            if (std.ascii.eqlIgnoreCase(expect_value, "100-continue")) {
                raw_req.server.out.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch break;
                raw_req.server.out.flush() catch break;
                raw_req.head.expect = null;
            } else {
                // std.http.Server.Request.respond asserts head.expect == null
                // and otherwise refuses to write a final status. Bypass it by
                // emitting a minimal 417 directly on the underlying writer.
                writeStatusLineAndClose(&writer.interface, .expectation_failed) catch {};
                break;
            }
        }

        const should_buffer_body = has_body and shouldBufferBody(raw_req.head.transfer_encoding, raw_req.head.content_length, options);
        const stable_target = if (should_buffer_body)
            ownSplitRequestTarget(alloc, split_target) catch break
        else
            split_target;
        const path = stable_target.path;
        const query_string = stable_target.query_string;

        // --- Body read with explicit 413 path ---
        // Small bodies are buffered to keep the existing zero-copy request
        // body helper path.
        // path fast. Large or unknown-length bodies can be exposed as a live
        // reader; after the handler returns we drain any unread tail with the
        // same max_body_bytes budget so keep-alive framing stays correct.
        var request_aborted: Atomic(bool) = .init(false);
        if (reader.deadlineExceeded()) {
            request_aborted.store(true, .release);
            break;
        }
        var body: []const u8 = "";
        var body_too_large = false;
        var transfer_buffer: [4096]u8 = undefined;
        var body_reader: *std.Io.Reader = undefined;
        var body_state_storage: ?request_mod.BodyState = null;
        if (has_body) {
            body_reader = raw_req.server.reader.bodyReader(
                &transfer_buffer,
                raw_req.head.transfer_encoding,
                raw_req.head.content_length,
            );

            if (should_buffer_body) {
                if (body_reader.allocRemaining(alloc, .limited(options.max_body_bytes))) |bytes| {
                    body = bytes;
                } else |err| switch (err) {
                    error.StreamTooLong => body_too_large = true,
                    else => {
                        request_aborted.store(true, .release);
                        break;
                    },
                }
            } else {
                body_state_storage = request_mod.BodyState.init(body_reader, options.max_body_bytes, &request_aborted);
            }
        }

        if (body_too_large) {
            // Send 413 directly; do not invoke user handler. After 413 the
            // body framing may be unreliable so we close the connection.
            raw_req.respond("Payload Too Large", .{
                .status = .payload_too_large,
                .keep_alive = false,
            }) catch {};
            break;
        }

        var req = Request.init(alloc, raw_req.head.method, path);
        req.query_string = query_string;
        if (has_body) {
            req.header_list = owned_headers;
        } else {
            req.header_lookup_ctx = @ptrCast(&raw_req);
            req.header_lookup_fn = lookupHeader;
            req.headers_collect_fn = collectHeaders;
        }
        req.body_bytes = body;
        req.raw_ctx = @ptrCast(&raw_req);
        req.conn_info = .{
            .remote = stream.socket.address,
            .local = options.address,
        };
        req.server_io = io;
        req.body_state = if (body_state_storage) |*state| state else null;
        req.abort_flag = &request_aborted;
        req.deadline_ns = request_deadline_ns;

        if (reader.deadlineExceeded()) {
            request_aborted.store(true, .release);
            break;
        }
        var response = app.handle(req);
        // Always release scopes/runtimes attached during dispatch, even on
        // an early error from `sendResponse`.
        defer response.deinit();
        if (body_state_storage) |*state| {
            switch (finishLiveRequestBody(state)) {
                .complete => {},
                .too_large => {
                    request_aborted.store(true, .release);
                    raw_req.respond("Payload Too Large", .{
                        .status = .payload_too_large,
                        .keep_alive = false,
                    }) catch {};
                    break;
                },
                .aborted => {
                    request_aborted.store(true, .release);
                    break;
                },
            }
        }
        if (reader.deadlineExceeded()) {
            request_aborted.store(true, .release);
            break;
        }
        const outcome = sendResponse(allocator, io, &raw_req, &response, &stream_buffer, &reader, options, close_after_response) catch {
            request_aborted.store(true, .release);
            break;
        };
        request_count += 1;
        if (outcome != .keep_alive) {
            request_aborted.store(true, .release);
            break;
        }
    }
}

fn rejectAcceptedConnection(io: Io, stream: Io.net.Stream, status: std.http.Status) void {
    var write_buffer: [256]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
    writeStatusLineAndClose(&writer.interface, status) catch {};
    stream.close(io);
}

fn shouldBufferBody(transfer_encoding: std.http.TransferEncoding, content_length: ?u64, options: Options) bool {
    if (options.body_buffer_bytes == 0) return false;
    const capped_buffer_bytes = @min(options.body_buffer_bytes, options.max_body_bytes);
    if (transfer_encoding == .chunked and content_length == null) {
        return capped_buffer_bytes >= options.max_body_bytes;
    }
    const len = content_length orelse 0;
    return len <= capped_buffer_bytes;
}

fn ownSplitRequestTarget(allocator: std.mem.Allocator, split_target: request_target.Split) std.mem.Allocator.Error!request_target.Split {
    const path_len = split_target.path.len;
    const query_len = split_target.query_string.len;
    const storage = try allocator.alloc(u8, path_len + query_len);
    @memcpy(storage[0..path_len], split_target.path);
    @memcpy(storage[path_len..][0..query_len], split_target.query_string);
    return .{
        .path = storage[0..path_len],
        .query_string = storage[path_len..][0..query_len],
    };
}

const RequestHeaderReject = enum {
    too_many_headers,
    header_bytes_too_large,
};

fn validateRequestHeaders(raw_req: *std.http.Server.Request, options: Options) ?RequestHeaderReject {
    var count: usize = 0;
    var bytes: usize = 0;
    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        count += 1;
        if (options.max_request_headers != 0 and count > options.max_request_headers) {
            return .too_many_headers;
        }

        bytes += header.name.len + header.value.len;
        if (options.max_request_header_bytes != 0 and bytes > options.max_request_header_bytes) {
            return .header_bytes_too_large;
        }
    }
    return null;
}

const RequestTargetReject = enum {
    target_too_long,
    query_too_long,
    too_many_segments,
};

fn validateRequestTarget(target: []const u8, options: Options) ?RequestTargetReject {
    if (target.len > options.max_request_target_bytes) return .target_too_long;
    return validateSplitRequestTarget(request_target.split(target), options);
}

fn validateSplitRequestTarget(split_target: request_target.Split, options: Options) ?RequestTargetReject {
    const path = split_target.path;
    const query = split_target.query_string;

    if (query.len > options.max_query_bytes) return .query_too_long;
    if (path_mod.exceedsSegmentLimit(path, options.max_path_segments)) return .too_many_segments;
    return null;
}

fn requestTargetRejectStatus(reject: RequestTargetReject) std.http.Status {
    return switch (reject) {
        .target_too_long, .query_too_long, .too_many_segments => .uri_too_long,
    };
}

test "server request target splitter accepts absolute-form targets" {
    const split = request_target.split("http://example.com/hello/world?x=1&y=2");
    try std.testing.expectEqualStrings("/hello/world", split.path);
    try std.testing.expectEqualStrings("x=1&y=2", split.query_string);

    const root = request_target.split("http://example.com?x=1");
    try std.testing.expectEqualStrings("/", root.path);
    try std.testing.expectEqualStrings("x=1", root.query_string);

    const origin = request_target.split("/proxy/http://example.com/file?x=1");
    try std.testing.expectEqualStrings("/proxy/http://example.com/file", origin.path);
    try std.testing.expectEqualStrings("x=1", origin.query_string);
}

test "server validates absolute-form path and query after splitting authority" {
    var options: Options = .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
    };
    options.max_path_segments = 1;
    options.max_query_bytes = 3;

    try std.testing.expectEqual(RequestTargetReject.too_many_segments, validateRequestTarget("http://example.com/a/b", options).?);
    try std.testing.expectEqual(RequestTargetReject.query_too_long, validateRequestTarget("http://example.com/a?toolong", options).?);
}

const DrainBodyOutcome = enum {
    complete,
    too_large,
    aborted,
};

fn finishLiveRequestBody(state: *request_mod.BodyState) DrainBodyOutcome {
    if (state.limit_exceeded) return .too_large;
    _ = state.discardRemaining() catch |err| switch (err) {
        error.BodyTooLarge => return .too_large,
        error.ReadFailed => return .aborted,
    };
    return .complete;
}

const SendOutcome = enum {
    keep_alive,
    close,
};

/// Writes a minimal HTTP/1.1 status line + Connection: close + empty body.
/// Used when receiveHead fails before we have a Request struct to call
/// .respond on. The caller is expected to break out of the keep-alive loop
/// after this returns.
fn writeStatusLineAndClose(out: *std.Io.Writer, status: std.http.Status) !void {
    const phrase = status.phrase() orelse "Error";
    try out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{
        @intFromEnum(status), phrase,
    });
    try out.flush();
}

fn drainRejectedHead(in: *std.Io.Reader, max_bytes: usize) !void {
    const limit = if (max_bytes == 0) 64 * 1024 else @max(max_bytes, 4096);
    var seen: usize = 0;
    var window: u32 = 0;
    while (seen < limit) {
        const chunk = try in.peekGreedy(1);
        if (chunk.len == 0) return;
        const byte = chunk[0];
        in.toss(1);
        seen += 1;
        window = (window << 8) | byte;
        if (window == 0x0d0a0d0a) return;
    }
}

const MemoryWriteNode = struct {
    response: *const Response,
    headers: []const std.http.Header,
    close_after_response: bool,
};

const StreamWriteNode = struct {
    response: *const Response,
    headers: []const std.http.Header,
    stream_buffer: []u8,
    runtime: response_mod.StreamRuntime,
    close_after_response: bool,
};

const SseWriteNode = struct {
    response: *const Response,
    headers: []const std.http.Header,
    stream_buffer: []u8,
    runtime: response_mod.SseRuntime,
    close_after_response: bool,
};

const FileWriteNode = struct {
    response: *const Response,
    headers: []const std.http.Header,
    stream_buffer: []u8,
    runtime: response_mod.FileRuntime,
    close_after_response: bool,
};

const WebSocketWriteNode = struct {
    runtime: response_mod.WebSocketRuntime,
    deadline_reader: *ServerStreamReader,
};

const WriteNode = union(enum) {
    memory: MemoryWriteNode,
    stream: StreamWriteNode,
    sse: SseWriteNode,
    file: FileWriteNode,
    websocket: WebSocketWriteNode,
};

fn drainWriteNode(io: Io, raw_req: *std.http.Server.Request, node: WriteNode) !SendOutcome {
    return switch (node) {
        .memory => |memory| sendMemoryNode(raw_req, memory),
        .stream => |stream| sendStreamNode(raw_req, stream),
        .sse => |sse_node| sendSseNode(raw_req, sse_node),
        .file => |file| sendFileNode(io, raw_req, file),
        .websocket => |websocket| sendWebSocketNode(raw_req, websocket),
    };
}

fn sendResponse(
    allocator: std.mem.Allocator,
    io: Io,
    raw_req: *std.http.Server.Request,
    response: *const Response,
    stream_buffer: *?[]u8,
    deadline_reader: *ServerStreamReader,
    options: Options,
    close_after_response: bool,
) !SendOutcome {
    var extra_headers: [3]std.http.Header = undefined;
    var header_count: usize = 0;

    if (response.content_type.len > 0) {
        extra_headers[header_count] = .{ .name = "content-type", .value = response.content_type };
        header_count += 1;
    }
    if (response.location) |location| {
        extra_headers[header_count] = .{ .name = "location", .value = location };
        header_count += 1;
    }
    if (response.allow) |allow| {
        extra_headers[header_count] = .{ .name = "allow", .value = allow };
        header_count += 1;
    }
    try validateSpecialResponseHeaderValues(response);

    const response_headers = response.extraHeaders();
    const combined_header_count = header_count + response_headers.len;
    var inline_headers: [8]std.http.Header = undefined;
    var allocated_headers: ?[]std.http.Header = null;
    const combined_headers = if (combined_header_count == 0)
        &.{}
    else if (header_count == 0)
        response_headers
    else if (response_headers.len == 0)
        extra_headers[0..header_count]
    else blk: {
        const headers = if (combined_header_count <= inline_headers.len)
            inline_headers[0..combined_header_count]
        else owned: {
            const owned_headers = try allocator.alloc(std.http.Header, combined_header_count);
            allocated_headers = owned_headers;
            break :owned owned_headers;
        };
        @memcpy(headers[0..header_count], extra_headers[0..header_count]);
        @memcpy(headers[header_count..combined_header_count], response_headers);
        break :blk headers;
    };
    defer if (allocated_headers) |headers| allocator.free(headers);
    try validateResponseHeaders(response_headers);

    var empty_stream_buffer: [0]u8 = .{};
    const response_stream_buffer = if (responseNeedsStreamBuffer(response))
        try ensureStreamBuffer(allocator, stream_buffer, options.stream_buffer_size)
    else
        empty_stream_buffer[0..];

    const node = responseWriteNode(response, combined_headers, response_stream_buffer, deadline_reader, close_after_response);
    if (options.max_write_queue_bytes != 0 and estimateQueuedBytes(node) > options.max_write_queue_bytes) {
        raw_req.respond("Write queue overloaded", .{
            .status = .service_unavailable,
            .keep_alive = false,
        }) catch {};
        return .close;
    }

    return try drainWriteNode(io, raw_req, node);
}

fn responseWriteNode(
    response: *const Response,
    headers: []const std.http.Header,
    stream_buffer: []u8,
    deadline_reader: *ServerStreamReader,
    close_after_response: bool,
) WriteNode {
    switch (response.runtime) {
        .websocket => |runtime| return .{ .websocket = .{
            .runtime = runtime,
            .deadline_reader = deadline_reader,
        } },
        .none => {},
    }

    return switch (response.body_kind) {
        .buffered => .{ .memory = .{
            .response = response,
            .headers = headers,
            .close_after_response = close_after_response,
        } },
        .stream => |runtime| .{ .stream = .{
            .response = response,
            .headers = headers,
            .stream_buffer = stream_buffer,
            .runtime = runtime,
            .close_after_response = close_after_response,
        } },
        .sse => |runtime| .{ .sse = .{
            .response = response,
            .headers = headers,
            .stream_buffer = stream_buffer,
            .runtime = runtime,
            .close_after_response = close_after_response,
        } },
        .file => |runtime| .{ .file = .{
            .response = response,
            .headers = headers,
            .stream_buffer = stream_buffer,
            .runtime = runtime,
            .close_after_response = close_after_response,
        } },
    };
}

fn responseNeedsStreamBuffer(response: *const Response) bool {
    return switch (response.body_kind) {
        .stream => !response.head_only,
        .sse => !response.head_only,
        .file => |runtime| !response.head_only and !runtime.head_only,
        .buffered => false,
    };
}

fn ensureStreamBuffer(allocator: std.mem.Allocator, stream_buffer: *?[]u8, requested_size: usize) std.mem.Allocator.Error![]u8 {
    if (stream_buffer.*) |buffer| return buffer;
    const buffer = try allocator.alloc(u8, @max(requested_size, 1));
    stream_buffer.* = buffer;
    return buffer;
}

fn validateSpecialResponseHeaderValues(response: *const Response) !void {
    if (response.content_type.len > 0 and !response_mod.validHeaderValue(response.content_type)) {
        return error.InvalidResponseHeader;
    }
    if (response.location) |location| {
        if (!response_mod.validHeaderValue(location)) return error.InvalidResponseHeader;
    }
    if (response.allow) |allow| {
        if (!response_mod.validHeaderValue(allow)) return error.InvalidResponseHeader;
    }
}

fn validateResponseHeaders(headers: []const std.http.Header) !void {
    for (headers) |header| {
        if (!response_mod.isAllowedResponseHeader(header.name)) return error.InvalidResponseHeader;
        if (!response_mod.validHeaderName(header.name) or !response_mod.validHeaderValue(header.value)) return error.InvalidResponseHeader;
    }
}

fn estimateQueuedBytes(node: WriteNode) usize {
    return switch (node) {
        .memory => |memory| memory.response.bodyBytes().len,
        .stream, .sse, .file, .websocket => 0,
    };
}

fn collectHeaders(
    ctx: *const anyopaque,
    allocator: std.mem.Allocator,
) ![]const std.http.Header {
    const raw_req: *std.http.Server.Request = @ptrCast(@alignCast(@constCast(ctx)));
    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        try headers.append(allocator, header);
    }

    if (headers.items.len == 0) return &.{};
    return try headers.toOwnedSlice(allocator);
}

fn collectOwnedHeaders(
    raw_req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
) ![]const std.http.Header {
    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try headers.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    if (headers.items.len == 0) return &.{};
    return try headers.toOwnedSlice(allocator);
}

fn lookupHeader(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
    const raw_req: *std.http.Server.Request = @ptrCast(@alignCast(@constCast(ctx)));
    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn sendMemoryNode(raw_req: *std.http.Server.Request, node: MemoryWriteNode) !SendOutcome {
    const payload = node.response.bodyBytes();

    try raw_req.respond(payload, .{
        .status = node.response.status,
        .extra_headers = node.headers,
        .keep_alive = !node.close_after_response,
    });
    return if (node.close_after_response) .close else .keep_alive;
}

fn sendStreamNode(raw_req: *std.http.Server.Request, node: StreamWriteNode) !SendOutcome {
    if (node.response.head_only) {
        if (node.runtime.content_length) |content_length| {
            try sendHeadOnlyHeaders(raw_req, node.response.status, node.headers, content_length, !node.close_after_response);
        } else {
            try raw_req.respond("", .{
                .status = node.response.status,
                .extra_headers = node.headers,
                .keep_alive = !node.close_after_response,
            });
        }
        return if (node.close_after_response) .close else .keep_alive;
    }

    var aborted: Atomic(bool) = .init(false);
    var body_writer = try raw_req.respondStreaming(node.stream_buffer, .{
        .content_length = node.runtime.content_length,
        .respond_options = .{
            .status = node.response.status,
            .extra_headers = node.headers,
            .keep_alive = !node.close_after_response,
        },
    });
    var stream_writer = response_mod.StreamWriter{
        .inner = &body_writer.writer,
        .aborted = &aborted,
    };
    node.runtime.run_fn(node.runtime.ctx, &stream_writer) catch {
        aborted.store(true, .release);
    };
    body_writer.end() catch {
        aborted.store(true, .release);
    };
    return if (aborted.load(.acquire) or node.close_after_response) .close else .keep_alive;
}

fn sendSseNode(raw_req: *std.http.Server.Request, node: SseWriteNode) !SendOutcome {
    if (node.response.head_only) {
        try raw_req.respond("", .{
            .status = node.response.status,
            .extra_headers = node.headers,
            .keep_alive = !node.close_after_response,
        });
        return if (node.close_after_response) .close else .keep_alive;
    }

    var aborted: Atomic(bool) = .init(false);
    var body_writer = try raw_req.respondStreaming(node.stream_buffer, .{
        .content_length = null,
        .respond_options = .{
            .status = node.response.status,
            .extra_headers = node.headers,
            .keep_alive = !node.close_after_response,
        },
    });
    var stream_writer = response_mod.StreamWriter{
        .inner = &body_writer.writer,
        .aborted = &aborted,
    };
    var sse_writer = response_mod.SseWriter{ .stream = &stream_writer };
    node.runtime.run_fn(node.runtime.ctx, &sse_writer) catch {
        aborted.store(true, .release);
    };
    body_writer.end() catch {
        aborted.store(true, .release);
    };
    return if (aborted.load(.acquire) or node.close_after_response) .close else .keep_alive;
}

fn sendHeadOnlyHeaders(
    raw_req: *std.http.Server.Request,
    status: std.http.Status,
    headers: []const std.http.Header,
    content_length: ?u64,
    keep_alive: bool,
) !void {
    const phrase = status.phrase() orelse "";
    const out = raw_req.server.out;
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), phrase });
    if (!keep_alive) try out.writeAll("connection: close\r\n");
    if (content_length) |len| {
        try out.print("content-length: {d}\r\n", .{len});
    }
    for (headers) |header| {
        if (!response_mod.validHeaderName(header.name) or !response_mod.validHeaderValue(header.value)) {
            return error.InvalidResponseHeader;
        }
        var vecs: [4][]const u8 = .{ header.name, ": ", header.value, "\r\n" };
        try out.writeVecAll(&vecs);
    }
    try out.writeAll("\r\n");
    try out.flush();
}

fn sendWebSocketNode(raw_req: *std.http.Server.Request, node: WebSocketWriteNode) !SendOutcome {
    const requested = raw_req.upgradeRequested();
    const key = switch (requested) {
        .websocket => |maybe_key| maybe_key orelse return error.InvalidWebSocketUpgrade,
        else => return error.InvalidWebSocketUpgrade,
    };

    var websocket_headers: [1]std.http.Header = undefined;
    const extra_ws_headers = if (node.runtime.protocol) |protocol| blk: {
        if (!response_mod.validHeaderName(protocol) or !response_mod.validHeaderValue(protocol)) {
            return error.InvalidResponseHeader;
        }
        websocket_headers[0] = .{
            .name = "sec-websocket-protocol",
            .value = protocol,
        };
        break :blk websocket_headers[0..1];
    } else &.{};
    try validateResponseHeaders(extra_ws_headers);

    var socket = try raw_req.respondWebSocket(.{
        .key = key,
        .extra_headers = extra_ws_headers,
    });
    var websocket: response_mod.WebSocketConnection = .{
        .socket = &socket,
        .max_message_bytes = node.runtime.options.max_message_bytes,
        .max_send_bytes = node.runtime.options.max_send_bytes,
        .idle_timeout_ms = node.runtime.options.idle_timeout_ms,
        .heartbeat_interval_ms = node.runtime.options.heartbeat_interval_ms,
        .max_missed_heartbeats = node.runtime.options.max_missed_heartbeats,
        .heartbeat_payload = node.runtime.options.heartbeat_payload,
        .arm_read_deadline_ctx = @ptrCast(node.deadline_reader),
        .arm_read_deadline_fn = armWebSocketReadDeadline,
        .read_error_ctx = @ptrCast(node.deadline_reader),
        .read_error_fn = webSocketReadError,
    };
    node.runtime.run_fn(node.runtime.ctx, &websocket) catch |err| {
        socket.flush() catch {};
        return err;
    };
    try socket.flush();
    return .close;
}

fn armWebSocketReadDeadline(ctx: *anyopaque, timeout_ms: u64) void {
    const reader: *ServerStreamReader = @ptrCast(@alignCast(ctx));
    reader.armReadDeadline(timeout_ms);
}

fn webSocketReadError(ctx: *anyopaque) ?anyerror {
    const reader: *ServerStreamReader = @ptrCast(@alignCast(ctx));
    return reader.err;
}

/// Streams `runtime.path` into the response without buffering it all in
/// memory. Flow:
///   1. open the file at `cwd + runtime.path`
///   2. stat it via `File.Reader.getSize` only when the caller did not provide
///      a stable `known_size`
///   3. reject with 500 if the selected byte window exceeds `runtime.max_bytes`
///   4. `respondStreaming` with `Content-Length = size` (no chunked encoding)
///   5. pump the selected byte window into the body writer
///
/// On `HEAD` (`runtime.head_only`), emits identical headers with an empty
/// body and skips the pump. On open/stat failure returns a 500; callers that
/// want fallthrough-if-missing must pre-check existence themselves (see
/// `serve_static.zig`).
fn sendFileNode(
    io: Io,
    raw_req: *std.http.Server.Request,
    node: FileWriteNode,
) !SendOutcome {
    const response = node.response;
    const runtime = node.runtime;
    const keep_alive = !node.close_after_response;
    const error_outcome: SendOutcome = if (node.close_after_response) .close else .keep_alive;
    var file = std.Io.Dir.cwd().openFile(io, runtime.path, .{}) catch {
        try raw_req.respond("", .{
            .status = .internal_server_error,
            .extra_headers = node.headers,
            .keep_alive = keep_alive,
        });
        return error_outcome;
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);

    const file_size = if (runtime.known_size) |known_size|
        known_size
    else blk: {
        const actual_file_size = file_reader.getSize() catch {
            try raw_req.respond("", .{
                .status = .internal_server_error,
                .extra_headers = node.headers,
                .keep_alive = keep_alive,
            });
            return error_outcome;
        };
        break :blk actual_file_size;
    };

    if (runtime.offset > file_size) {
        try raw_req.respond("", .{
            .status = .range_not_satisfiable,
            .extra_headers = node.headers,
            .keep_alive = keep_alive,
        });
        return error_outcome;
    }

    const remaining = file_size - runtime.offset;
    if (runtime.length) |length| {
        if (length > remaining) {
            try raw_req.respond("", .{
                .status = .range_not_satisfiable,
                .extra_headers = node.headers,
                .keep_alive = keep_alive,
            });
            return error_outcome;
        }
    }

    // Derive the actual byte window to serve. For non-range responses,
    // `length` is null and we stream [0, file_size).
    const content_length: u64 = runtime.length orelse (file_size - runtime.offset);

    if (content_length > runtime.max_bytes) {
        try raw_req.respond("", .{
            .status = .internal_server_error,
            .extra_headers = node.headers,
            .keep_alive = keep_alive,
        });
        return error_outcome;
    }

    if (runtime.head_only or response.head_only) {
        try sendHeadOnlyHeaders(raw_req, response.status, node.headers, content_length, !node.close_after_response);
        return if (node.close_after_response) .close else .keep_alive;
    }

    if (runtime.offset != 0) {
        file_reader.seekTo(runtime.offset) catch {
            try raw_req.respond("", .{
                .status = .internal_server_error,
                .extra_headers = node.headers,
                .keep_alive = keep_alive,
            });
            return error_outcome;
        };
    }

    var body_writer = try raw_req.respondStreaming(node.stream_buffer, .{
        .content_length = content_length,
        .respond_options = .{
            .status = response.status,
            .extra_headers = node.headers,
            .keep_alive = !node.close_after_response,
        },
    });

    var aborted = false;
    if (runtime.length != null or runtime.known_size != null) {
        file_reader.interface.streamExact64(&body_writer.writer, content_length) catch {
            aborted = true;
        };
    } else {
        _ = file_reader.interface.streamRemaining(&body_writer.writer) catch {
            aborted = true;
        };
    }
    body_writer.end() catch {
        aborted = true;
    };
    return if (aborted or node.close_after_response) .close else .keep_alive;
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------
//
// These tests boot a real `Server` against `127.0.0.1:0`, learn the bound
// port via `Server.bound_port`, and drive it with an HTTP client built on
// `std.Io.net.Stream`. They exercise the new PR2 behaviors end-to-end.

const testing = std.testing;
const Context = @import("../core/context.zig").Context;

fn runServeZio(server: *Server, runtime: *zio.Runtime, app: *App) anyerror!void {
    return server.serveZio(runtime, app);
}

fn waitForBind(server: *Server, io: Io) !u16 {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const p = server.bound_port.load(.acquire);
        if (p != 0) return p;
        Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.ServerNeverBound;
}

fn sendRaw(io: Io, port: u16, request_bytes: []const u8) ![]u8 {
    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    addr.setPort(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buf);
    try writer.interface.writeAll(request_bytes);
    try writer.interface.flush();

    var read_buf: [16 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buf);
    return try reader.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
}

fn helloHandler(c: *Context) Response {
    return c.text("hello");
}

fn echoHandler(c: *Context) Response {
    return c.text(c.req.bodyBytes());
}

const JsonBody = struct {
    ok: bool = false,
    name: []const u8 = "",
};

fn jsonBodyHandler(c: *Context) Response {
    const payload = c.req.json(JsonBody) catch return c.text(.{ "bad json", .bad_request });
    return c.json(.{
        .ok = payload.ok,
        .name = payload.name,
    });
}

fn echoReaderHandler(c: *Context) Response {
    var reader = c.bodyReader();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [3]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch {
            return c.text(.{ "read failed", .internal_server_error });
        };
        if (n == 0) break;
        out.appendSlice(c.req.allocator, buf[0..n]) catch {
            return c.text(.{ "alloc failed", .internal_server_error });
        };
    }
    return c.text(out.items);
}

fn streamingBodyStateHandler(c: *Context) Response {
    var reader = c.bodyReader();
    var total: usize = 0;
    var buf: [5]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch {
            return c.text(.{ "read failed", .internal_server_error });
        };
        if (n == 0) break;
        total += n;
    }
    const body = std.fmt.allocPrint(c.req.allocator, "{d}:{s}:{s}", .{
        total,
        if (c.hasStreamingBody()) "stream" else "buffer",
        if (c.isAborted()) "aborted" else "open",
    }) catch {
        return c.text(.{ "alloc failed", .internal_server_error });
    };
    return c.text(body);
}

const upload_test_path = ".zig-cache/zono-upload-test.bin";

fn saveUploadHandler(c: *Context) Response {
    const written = c.saveBodyToFile(upload_test_path, .{
        .max_bytes = 1024,
        .buffer_size = 8,
    }) catch |err| switch (err) {
        error.BodyTooLarge => return c.text(.{ "too large", .payload_too_large }),
        else => {
            const body = std.fmt.allocPrint(c.req.allocator, "save failed: {s}", .{@errorName(err)}) catch "save failed";
            return c.text(.{ body, .internal_server_error });
        },
    };

    const body = std.fmt.allocPrint(c.req.allocator, "{d}", .{written}) catch {
        return c.text(.{ "alloc failed", .internal_server_error });
    };
    return c.text(body);
}

/// Cleanly stops a serve() that is parked in accept().
fn stopAndJoin(server: *Server, io: Io, future: anytype) void {
    server.stop(io);
    _ = future.await(io) catch {};
}

test "PR2: 413 returned when body exceeds max_body_bytes" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 16,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    // 32 bytes of body; limit is 16 → must get 413.
    const req_bytes =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 32\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "413") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Payload Too Large") != null);
}

test "server sends HEAD headers without buffered body" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    var server = Server.init(.{
        .allocator = testing.allocator,
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0),
        .shutdown_drain_ms = 200,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);
    const resp = try sendRaw(io, port, "HEAD / HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Connection: close\r\n" ++
        "\r\n");
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
    try testing.expect(std.ascii.indexOfIgnoreCase(resp, "content-length: 5") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\r\n\r\nhello") == null);
}

test "server validates final response headers" {
    try testing.expectError(error.InvalidResponseHeader, validateResponseHeaders(&.{.{
        .name = "content-type",
        .value = "text/plain\r\nx-evil: 1",
    }}));
    try testing.expectError(error.InvalidResponseHeader, validateResponseHeaders(&.{.{
        .name = "content-length",
        .value = "999",
    }}));
    try validateResponseHeaders(&.{.{
        .name = "x-safe",
        .value = "ok",
    }});
}

test "PR2: under-limit body is delivered to handler" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const req_bytes =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 5\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "hello";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\r\n\r\nhello") != null);
}

test "server keeps headers available after reading request body" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/json", jsonBodyHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const req_bytes =
        "POST /json HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 25\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{\"ok\":true,\"name\":\"zono\"}";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"zono\"") != null);
}

test "PR2: Server.stop + dummy connection drains serve" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });

    _ = try waitForBind(&server, io);

    // stopAndJoin: set flag, deliver one wakeup connection, await.
    stopAndJoin(&server, io, &serve_future);
    try testing.expectEqual(@as(u16, 0), server.bound_port.load(.acquire));
}

test "PR2: per-request timeout config does not break fast handlers" {
    // The full negative test (slow handler getting canceled) requires a
    // way to yield from the handler at a cancellation point; Context does
    // not currently expose Io. We instead verify that enabling the timer
    // does not regress the happy path.
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 2_000,
        .shutdown_drain_ms = 200,
    });

    var serve_future = try Io.concurrent(io, runServeZio, .{ &server, runtime, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const req_bytes =
        "GET / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}

test "server uses low-overhead zio read deadlines" {
    try testing.expectEqual(ReadDeadlineMode.watchdog, readDeadlineMode(.zio));
}

test "PR2: StreamWriter.isAborted reflects atomic flag" {
    var aborted: Atomic(bool) = .init(false);
    var dummy_buf: [16]u8 = undefined;
    var aw: std.Io.Writer = .{
        .vtable = &.{ .drain = std.Io.Writer.failingDrain },
        .buffer = &dummy_buf,
        .end = 0,
    };
    var sw = response_mod.StreamWriter{
        .inner = &aw,
        .aborted = &aborted,
    };
    try testing.expect(!sw.isAborted());
    aborted.store(true, .release);
    try testing.expect(sw.isAborted());
}

// ---------------------------------------------------------------------------
// PR3: HTTP/1.1 protocol correctness
// ---------------------------------------------------------------------------

/// Sends `request_bytes` on a persistent connection and reads the next
/// response (parsed via std.http.Server.Response framing rules: headers up
/// to CRLFCRLF + Content-Length body). Leaves the stream open so callers
/// can pipeline more requests.
const PersistentClient = struct {
    stream: Io.net.Stream,
    io: Io,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    fn connect(io: Io, port: u16) !*PersistentClient {
        const c = try testing.allocator.create(PersistentClient);
        errdefer testing.allocator.destroy(c);
        c.* = .{ .stream = undefined, .io = io };
        var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        addr.setPort(port);
        c.stream = try addr.connect(io, .{ .mode = .stream });
        c.reader = Io.net.Stream.Reader.init(c.stream, io, &c.read_buf);
        c.writer = Io.net.Stream.Writer.init(c.stream, io, &c.write_buf);
        return c;
    }

    fn close(c: *PersistentClient) void {
        c.stream.close(c.io);
        testing.allocator.destroy(c);
    }

    fn send(c: *PersistentClient, bytes: []const u8) !void {
        try c.writer.interface.writeAll(bytes);
        try c.writer.interface.flush();
    }

    /// Reads a complete HTTP response (status line + headers + body sized by
    /// Content-Length or chunked terminator). Returns owned bytes.
    fn recvResponse(c: *PersistentClient) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        const r = &c.reader.interface;

        // Read header block.
        while (std.mem.indexOf(u8, out.items, "\r\n\r\n") == null) {
            const chunk = r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => if (out.items.len > 0)
                    return out.toOwnedSlice(testing.allocator)
                else
                    return error.ResponseTruncated,
                else => return err,
            };
            if (chunk.len == 0) return error.ResponseTruncated;
            try out.append(testing.allocator, chunk[0]);
            r.toss(1);
            if (out.items.len > 32 * 1024) return error.ResponseTooLarge;
        }

        const header_end = std.mem.indexOf(u8, out.items, "\r\n\r\n").? + 4;
        const headers_view = out.items[0..header_end];

        // Parse Content-Length.
        var body_remaining: ?usize = null;
        var is_chunked = false;
        var line_iter = std.mem.splitSequence(u8, headers_view, "\r\n");
        _ = line_iter.next(); // status line
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            var value = line[colon + 1 ..];
            value = std.mem.trim(u8, value, " \t");
            if (http_names.isContentLength(name)) {
                body_remaining = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (http_names.isTransferEncoding(name)) {
                if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) is_chunked = true;
            }
        }

        const already_body = out.items.len - header_end;

        if (is_chunked) {
            // Read until we see the terminating "0\r\n\r\n".
            while (std.mem.indexOf(u8, out.items[header_end..], "0\r\n\r\n") == null) {
                const chunk = r.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return out.toOwnedSlice(testing.allocator),
                    else => return err,
                };
                if (chunk.len == 0) break;
                try out.appendSlice(testing.allocator, chunk);
                r.toss(chunk.len);
                if (out.items.len > 256 * 1024) return error.ResponseTooLarge;
            }
        } else if (body_remaining) |total| {
            var have = already_body;
            while (have < total) {
                const chunk = r.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return out.toOwnedSlice(testing.allocator),
                    else => return err,
                };
                if (chunk.len == 0) break;
                const want = @min(total - have, chunk.len);
                try out.appendSlice(testing.allocator, chunk[0..want]);
                r.toss(want);
                have += want;
            }
        }

        return out.toOwnedSlice(testing.allocator);
    }
};

fn boot(runtime: *zio.Runtime, app: *App, opts: Options) !struct {
    server: *Server,
    future: Io.Future(anyerror!void),
} {
    const io = runtime.io();
    const server = try testing.allocator.create(Server);
    server.* = Server.init(opts);
    var future = try Io.concurrent(io, runServeZio, .{ server, runtime, app });
    _ = waitForBind(server, io) catch |err| {
        _ = future.await(io) catch {};
        testing.allocator.destroy(server);
        return err;
    };
    return .{ .server = server, .future = future };
}

fn shutdown(handle: anytype, io: Io) void {
    var f = handle.future;
    stopAndJoin(handle.server, io, &f);
    testing.allocator.destroy(handle.server);
}

test "PR3: client Connection: close closes after one response" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const client = try PersistentClient.connect(io, port);
    defer client.close();

    try client.send(
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    const resp = try client.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: close") != null);
}

test "PR3: HTTP/1.0 closes by default, keeps alive when requested" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);

    // 1.0 default: server should not say "keep-alive".
    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();
        try c.send("GET / HTTP/1.0\r\nHost: x\r\n\r\n");
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: keep-alive") == null);
    }

    // 1.0 with explicit keep-alive: server should NOT close the connection.
    // (std promotes the response to HTTP/1.1 and relies on the absence of a
    // `connection: close` header to signal persistence; it does not echo
    // `connection: keep-alive` back.)
    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();
        try c.send("GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: close") == null);
    }
}

test "PR3: chunked request body is read and delivered to handler" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // "Hello, " + "World!" sent as two chunks.
    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "7\r\nHello, \r\n" ++
            "6\r\nWorld!\r\n" ++
            "0\r\n\r\n",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Hello, World!") != null);
}

test "buffered request body does not corrupt route target slices" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/api/menus/:id", struct {
        fn h(c: *Context) Response {
            const payload = std.fmt.allocPrint(c.req.allocator, "{s}|{s}|{s}|{s}", .{
                c.req.path,
                c.req.param("id") orelse "missing",
                c.req.query_string,
                c.req.bodyBytes(),
            }) catch return c.text(.{ "alloc failed", .internal_server_error });
            return c.text(payload);
        }
    }.h);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    const body = "{\"type\":\"menu\"}";
    try c.send(
        "POST /api/menus/38?draft=1 HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 15\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    try c.send(body);

    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "/api/menus/38|38|draft=1|{\"type\":\"menu\"}") != null);
}

test "request body can stream to the handler without prebuffering" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoReaderHandler);
    try app.post("/state", streamingBodyStateHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .body_buffer_bytes = 0,
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);

    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();

        try c.send(
            "POST /echo HTTP/1.1\r\n" ++
                "Host: x\r\n" ++
                "Content-Length: 11\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "hello world",
        );
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);

        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "hello world") != null);
    }

    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();

        try c.send(
            "POST /state HTTP/1.1\r\n" ++
                "Host: x\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "5\r\nhello\r\n" ++
                "6\r\n world\r\n" ++
                "0\r\n\r\n",
        );
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);

        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "11:stream:open") != null);
    }
}

test "request body can stream directly to a file" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    std.Io.Dir.cwd().deleteFile(io, upload_test_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, upload_test_path) catch {};

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/upload", saveUploadHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .body_buffer_bytes = 0,
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /upload HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 11\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "hello world",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "11") != null);

    const saved = try std.Io.Dir.cwd().readFileAlloc(io, upload_test_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("hello world", saved);
}

test "streaming body drain preserves keep-alive when handler ignores body" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/drop", struct {
        fn h(c: *Context) Response {
            return c.text(if (c.hasStreamingBody()) "stream" else "buffer");
        }
    }.h);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .body_buffer_bytes = 0,
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
            "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nworld",
    );

    const r1 = try c.recvResponse();
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "200") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "stream") != null);

    const r2 = try c.recvResponse();
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "200") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "stream") != null);
}

test "streaming body drain returns 413 when chunked payload exceeds max" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/drop", struct {
        fn h(c: *Context) Response {
            return c.text("handler should not win");
        }
    }.h);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .body_buffer_bytes = 0,
        .max_body_bytes = 4,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /drop HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n" ++
            "0\r\n\r\n",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "413") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Payload Too Large") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "handler should not win") == null);
}

test "PR3: Expect: 100-continue gets 100 then final response" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Send headers first; expect server to respond with 100 Continue.
    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 5\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const continue_resp = try c.recvResponse();
    defer testing.allocator.free(continue_resp);
    try testing.expect(std.mem.startsWith(u8, continue_resp, "HTTP/1.1 100"));

    // Now send the body; expect 200 with echo.
    try c.send("hello");
    const final_resp = try c.recvResponse();
    defer testing.allocator.free(final_resp);
    try testing.expect(std.mem.indexOf(u8, final_resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, final_resp, "\r\n\r\nhello") != null);
}

test "oversize Expect request returns 413 without 100 Continue" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 4,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 5\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 413"));
    try testing.expect(std.mem.indexOf(u8, resp, "100 Continue") == null);
}

test "PR3: unknown Expect value returns 417" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 5\r\n" ++
            "Expect: i-want-magic\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "417") != null);
}

test "PR3: handler that ignores body still keeps connection alive" {
    // Verifies std.http.Server.discardBody runs inside respond() and drains
    // the unread body so a second pipelined request frames correctly.
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    // POST handler returns "ok" without ever touching request body helpers.
    try app.post("/drop", struct {
        fn h(c: *Context) Response {
            return c.text("ok");
        }
    }.h);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
        // Force the body read path to actually pull bytes off the wire by
        // making the body real (server reads then discards via respond).
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Two pipelined requests on the same connection. The second must succeed.
    try c.send(
        "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
            "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nworld",
    );

    const r1 = try c.recvResponse();
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "200") != null);

    const r2 = try c.recvResponse();
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "200") != null);
}

test "PR3: oversize headers return 431" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .read_buffer_size = 1024, // small head buffer to trigger oversize
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Build a request with a single header value larger than the head buffer.
    var big: [4096]u8 = undefined;
    @memset(&big, 'A');
    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(testing.allocator);
    try req_buf.appendSlice(testing.allocator, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: ");
    try req_buf.appendSlice(testing.allocator, &big);
    try req_buf.appendSlice(testing.allocator, "\r\nConnection: close\r\n\r\n");

    try c.send(req_buf.items);
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "431") != null);
}

test "server rejects requests beyond header count hard limit" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_request_headers = 2,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "GET / HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "X-One: 1\r\n" ++
            "X-Two: 2\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "431") != null);
}

test "server applies response write queue byte high water" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/big", struct {
        fn run(c: *Context) Response {
            return c.text("0123456789abcdef");
        }
    }.run);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_write_queue_bytes = 4,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send("GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "503") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Write queue overloaded") != null);
}

test "server enforces max keep-alive requests per connection" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_keep_alive_requests = 1,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );

    const r1 = try c.recvResponse();
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "200") != null);
    try testing.expectError(error.ResponseTruncated, c.recvResponse());
}

test "server rejects accepted connections over max_connections" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_connections = 1,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const held = try PersistentClient.connect(io, port);
    defer held.close();
    Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    try testing.expect(handle.server.connectionCount() >= 1);

    const rejected = try PersistentClient.connect(io, port);
    defer rejected.close();

    const resp = try rejected.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "503") != null);
}

test "PR3: 405 returned for wrong method on existing route" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/only-get", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /only-get HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "405") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(resp, "allow:") != null);
}

test "server rejects request targets beyond hard limits before dispatch" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/this-route-would-match", helloHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_request_target_bytes = 8,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send("GET /this-route-would-match HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "414") != null);
}

const file_node_test_path = ".zig-cache/zono-file-node-test.txt";

fn fileNodeHandler(_: *Context) Response {
    return response_mod.file(file_node_test_path, "text/plain", .{});
}

test "server drains file responses through the connection write queue" {
    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var file = try std.Io.Dir.cwd().createFile(io, file_node_test_path, .{});
    var file_buf: [64]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &file_buf);
    try file_writer.interface.writeAll("file-node");
    try file_writer.end();
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_node_test_path) catch {};

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/file", fileNodeHandler);

    const handle = try boot(runtime, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send("GET /file HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "file-node") != null);
}

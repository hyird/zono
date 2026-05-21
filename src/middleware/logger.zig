const std = @import("std");
const Context = @import("../core/context.zig").Context;
const Response = @import("../response/response.zig").Response;
const request_id = @import("request_id.zig");
const time = @import("../core/time.zig");

pub const Entry = struct {
    method: []const u8,
    path: []const u8,
    route_path: ?[]const u8 = null,
    status: std.http.Status,
    elapsed_ns: u64,
    request_id: ?[]const u8 = null,
    request_body: ?[]const u8 = null,
    request_body_truncated: bool = false,
};

pub const PrintFn = *const fn (entry: Entry) void;

pub const Options = struct {
    print: PrintFn = defaultPrint,
    include_request_id: bool = true,
    request_id_key: []const u8 = request_id.context_key,
    include_request_body: bool = false,
    request_body_max_bytes: usize = 4096,
};

const MiddlewareFn = fn (c: *Context, next: Context.Next) Response;

pub fn logger(comptime options: Options) MiddlewareFn {
    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            const start_ns = time.nowNanoseconds();
            next.run();
            const response = c.takeResponse();
            const elapsed_ns = time.nowNanoseconds() -| start_ns;
            const body_bytes = c.req.bodyBytes();
            const body_len = @min(body_bytes.len, options.request_body_max_bytes);
            options.print(.{
                .method = c.req.methodName(),
                .path = c.req.path,
                .route_path = c.routePath(),
                .status = response.status,
                .elapsed_ns = elapsed_ns,
                .request_id = if (options.include_request_id)
                    c.get([]const u8, options.request_id_key)
                else
                    null,
                .request_body = if (options.include_request_body and
                    !c.req.hasStreamingBody() and
                    body_bytes.len > 0)
                    body_bytes[0..body_len]
                else
                    null,
                .request_body_truncated = options.include_request_body and
                    !c.req.hasStreamingBody() and
                    body_bytes.len > options.request_body_max_bytes,
            });
            return response;
        }
    }.run;
}

fn defaultPrint(entry: Entry) void {
    const elapsed_us = (entry.elapsed_ns + std.time.ns_per_us / 2) / std.time.ns_per_us;
    const elapsed_ms = elapsed_us / 1000;
    const elapsed_ms_fraction = elapsed_us % 1000;

    if (entry.request_id) |id| {
        if (entry.request_body) |body| {
            std.log.info("{s} {d} {d}.{d:0>3}ms requestId={s} path={s} body={f}{s}", .{
                entry.method,
                @intFromEnum(entry.status),
                elapsed_ms,
                elapsed_ms_fraction,
                id,
                entry.path,
                oneLineBody(body),
                if (entry.request_body_truncated) "..." else "",
            });
        } else {
            std.log.info("{s} {d} {d}.{d:0>3}ms requestId={s} path={s}", .{
                entry.method,
                @intFromEnum(entry.status),
                elapsed_ms,
                elapsed_ms_fraction,
                id,
                entry.path,
            });
        }
    } else {
        if (entry.request_body) |body| {
            std.log.info("{s} {d} {d}.{d:0>3}ms path={s} body={f}{s}", .{
                entry.method,
                @intFromEnum(entry.status),
                elapsed_ms,
                elapsed_ms_fraction,
                entry.path,
                oneLineBody(body),
                if (entry.request_body_truncated) "..." else "",
            });
        } else {
            std.log.info("{s} {d} {d}.{d:0>3}ms path={s}", .{
                entry.method,
                @intFromEnum(entry.status),
                elapsed_ms,
                elapsed_ms_fraction,
                entry.path,
            });
        }
    }
}

const OneLineBody = struct {
    bytes: []const u8,

    pub fn format(self: OneLineBody, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.bytes) |byte| {
            try writer.writeByte(switch (byte) {
                '\n', '\r', '\t' => ' ',
                else => if (byte < 0x20 or byte == 0x7f) ' ' else byte,
            });
        }
    }
};

fn oneLineBody(bytes: []const u8) OneLineBody {
    return .{ .bytes = bytes };
}

test "logger calls custom print after downstream response" {
    const app_mod = @import("../app/app.zig");

    const Recorder = struct {
        var seen_status: std.http.Status = .ok;
        var seen_path: []const u8 = "";

        fn print(entry: Entry) void {
            seen_status = entry.status;
            seen_path = entry.path;
        }
    };

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(logger(.{ .print = Recorder.print }));
    try app.get("/ping", struct {
        fn run(c: *Context) Response {
            return c.text("pong");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/ping", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, Recorder.seen_status);
    try std.testing.expectEqualStrings("/ping", Recorder.seen_path);
}

test "logger omits request body by default" {
    const app_mod = @import("../app/app.zig");

    const Recorder = struct {
        var saw_body = true;

        fn print(entry: Entry) void {
            saw_body = entry.request_body != null;
        }
    };

    Recorder.saw_body = true;

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(logger(.{ .print = Recorder.print }));
    try app.post("/echo", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.text());
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/echo", .{
        .method = .POST,
        .body = "hello",
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("hello", res.bodyBytes());
    try std.testing.expect(!Recorder.saw_body);
}

test "logger body formatter preserves quotes and folds control characters" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print("{f}", .{oneLineBody("{\"name\":\"Ada\"}\nnext\tok")});

    try std.testing.expectEqualStrings("{\"name\":\"Ada\"} next ok", writer.buffered());
}

test "logger can include buffered request body without consuming it" {
    const app_mod = @import("../app/app.zig");

    const Recorder = struct {
        var saw_body = false;
        var saw_truncated = true;

        fn print(entry: Entry) void {
            if (entry.request_body) |body| {
                saw_body = std.mem.eql(u8, body, "hello");
            }
            saw_truncated = entry.request_body_truncated;
        }
    };

    Recorder.saw_body = false;
    Recorder.saw_truncated = true;

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(logger(.{
        .print = Recorder.print,
        .include_request_body = true,
    }));
    try app.post("/echo", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.text());
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/echo", .{
        .method = .POST,
        .body = "hello",
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("hello", res.bodyBytes());
    try std.testing.expect(Recorder.saw_body);
    try std.testing.expect(!Recorder.saw_truncated);
}

test "logger truncates buffered request body when configured" {
    const app_mod = @import("../app/app.zig");

    const Recorder = struct {
        var saw_body = false;
        var saw_truncated = false;

        fn print(entry: Entry) void {
            if (entry.request_body) |body| {
                saw_body = std.mem.eql(u8, body, "hel");
            }
            saw_truncated = entry.request_body_truncated;
        }
    };

    Recorder.saw_body = false;
    Recorder.saw_truncated = false;

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(logger(.{
        .print = Recorder.print,
        .include_request_body = true,
        .request_body_max_bytes = 3,
    }));
    try app.post("/echo", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.text());
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/echo", .{
        .method = .POST,
        .body = "hello",
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("hello", res.bodyBytes());
    try std.testing.expect(Recorder.saw_body);
    try std.testing.expect(Recorder.saw_truncated);
}

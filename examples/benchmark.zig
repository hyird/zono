const std = @import("std");
const zono = @import("zono");

pub const std_options: std.Options = .{ .log_level = .info };

const static_file_path = ".zig-cache/zono-benchmark-file.txt";

pub fn main(init: std.process.Init) !void {
    const runtime = try zono.ZioRuntime.init(init.gpa, .{});
    defer runtime.deinit();
    const io = runtime.io();

    try prepareBenchmarkFile(io);

    var app = zono.App.init(init.gpa);
    defer app.deinit();

    try app.get("/api/text", textResponse);
    try app.get("/api/json", jsonResponse);
    try app.get("/api/html", htmlResponse);
    try app.get("/api/body", bodyResponse);
    try app.get("/api/params/:id", paramsResponse);
    try app.get("/api/query", queryResponse);
    try app.get("/api/header", headerResponse);
    try app.get("/api/cookie", cookieResponse);
    try app.get("/api/redirect", redirectResponse);
    try app.get("/api/middleware", .{ benchmarkMiddleware, middlewareResponse });
    try app.get("/api/stream", streamResponse);
    try app.get("/api/file", fileResponse);
    try app.post("/api/post-json", postJsonResponse);
    try app.useAt("/api/cors", zono.cors(.{ .origin = &.{"*"} }));
    try app.options("/api/cors", corsResponse);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3003"),
        .shutdown_drain_ms = 0,
    });
    try server.serveZio(runtime, &app);
}

fn prepareBenchmarkFile(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, ".zig-cache");
    var file = try std.Io.Dir.cwd().createFile(io, static_file_path, .{});
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &buffer);
    try writer.interface.writeAll("zono benchmark file response\n");
    try writer.end();
}

fn textResponse(c: *zono.Context) zono.Response {
    return c.text("hello zono");
}

fn jsonResponse(c: *zono.Context) zono.Response {
    return c.json(.{
        .ok = true,
        .framework = "zono",
    });
}

fn htmlResponse(c: *zono.Context) zono.Response {
    return c.html("<!doctype html><title>zono</title><main>benchmark</main>");
}

fn bodyResponse(c: *zono.Context) zono.Response {
    return c.body(.{
        .content = "raw body",
        .content_type = "application/octet-stream",
    });
}

fn paramsResponse(c: *zono.Context) zono.Response {
    const id = c.req.param("id") orelse "missing";
    return c.text(id);
}

fn queryResponse(c: *zono.Context) zono.Response {
    const name = c.req.query("name") orelse "missing";
    const mode = c.req.query("mode") orelse "default";
    return c.json(.{
        .name = name,
        .mode = mode,
    });
}

fn headerResponse(c: *zono.Context) zono.Response {
    const value = c.req.header("x-bench") orelse "missing";
    _ = c.header("x-bench-seen", value);
    return c.text(value);
}

fn cookieResponse(c: *zono.Context) zono.Response {
    const value = c.req.cookie("bench") orelse "missing";
    c.cookie("bench_seen", value, .{ .path = "/" }) catch return zono.internalError("cookie failed");
    return c.text(value);
}

fn redirectResponse(c: *zono.Context) zono.Response {
    return c.redirect("/api/text");
}

fn benchmarkMiddleware(c: *zono.Context, next: zono.Context.Next) zono.Response {
    _ = c.header("x-powered-by", "zono");
    next.run();
    return c.takeResponse();
}

fn middlewareResponse(c: *zono.Context) zono.Response {
    return c.text("middleware");
}

fn streamResponse(c: *zono.Context) zono.Response {
    return c.streamText(writeStream, .{ .content_length = 22 });
}

fn writeStream(writer: *zono.StreamWriter) !void {
    try writer.writeAll("streamed zono payload\n");
}

fn fileResponse(_: *zono.Context) zono.Response {
    return zono.response.file(static_file_path, "text/plain; charset=utf-8", .{});
}

const JsonPayload = struct {
    ok: bool = false,
    name: []const u8 = "",
};

fn postJsonResponse(c: *zono.Context) zono.Response {
    const payload = c.req.json(JsonPayload) catch return c.text(.{ "bad json", .bad_request });
    return c.json(.{
        .ok = payload.ok,
        .name = payload.name,
    });
}

fn corsResponse(c: *zono.Context) zono.Response {
    return c.text("cors");
}

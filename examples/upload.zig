const std = @import("std");
const zono = @import("zono");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const runtime = try zono.ZioRuntime.init(init.gpa, .{});
    defer runtime.deinit();

    var app = zono.App.init(init.gpa);
    defer app.deinit();
    try app.post("/upload/raw", uploadRaw);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3004"),
        .max_body_bytes = 512 * 1024 * 1024,
        .body_buffer_bytes = 0,
        .request_timeout_ms = 0,
    });
    try server.serveZio(runtime, &app);
}

fn uploadRaw(c: *zono.Context) zono.Response {
    const written = c.saveBodyToFile("upload.bin", .{
        .max_bytes = 512 * 1024 * 1024,
        .buffer_size = 128 * 1024,
    }) catch |err| switch (err) {
        error.BodyTooLarge => return c.text(.{ "payload too large", .payload_too_large }),
        else => return c.text(.{ "upload failed", .internal_server_error }),
    };

    return c.json(.{
        .ok = true,
        .bytes = written,
    });
}

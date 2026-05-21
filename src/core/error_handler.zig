const std = @import("std");
const app_error = @import("app_error.zig");
const context_mod = @import("context.zig");
const response_mod = @import("../response/response.zig");

const Context = context_mod.Context;
const Response = response_mod.Response;

pub const Options = struct {
    expose_internal_errors: bool = false,
    log_internal_errors: bool = true,
    database_error_code: []const u8 = "DATABASE_ERROR",
    database_error_message: []const u8 = "Database error.",
};

pub fn errorHandler(comptime options: Options) fn (err: anyerror, c: *Context) Response {
    return struct {
        fn run(err: anyerror, c: *Context) Response {
            if (err == error.HTTPException) {
                if (c.httpException()) |exception| {
                    return exception.getResponse(c.req.allocator);
                }
            }

            const detail = c.errorDetail(err);
            if (detail) |value| {
                if (options.log_internal_errors) {
                    std.log.err("{f}", .{value});
                }
            }

            if (c.appError(err)) |def| {
                return jsonError(c, def);
            }

            if (detail != null) {
                return jsonError(c, .{
                    .err = err,
                    .status = .internal_server_error,
                    .code = options.database_error_code,
                    .message = options.database_error_message,
                });
            }

            if (options.log_internal_errors) {
                std.log.err("unhandled error: {s}", .{@errorName(err)});
            }

            const message = if (options.expose_internal_errors)
                @errorName(err)
            else
                "Internal Server Error";

            return jsonError(c, .{
                .err = err,
                .status = .internal_server_error,
                .code = "INTERNAL_SERVER_ERROR",
                .message = message,
            });
        }
    }.run;
}

fn jsonError(c: *Context, def: app_error.Def) Response {
    const Payload = struct {
        code: []const u8,
        message: []const u8,
    };

    return c.json(.{
        Payload{
            .code = def.codeValue(),
            .message = def.messageValue(),
        },
        def.status,
    });
}

test "error handler maps registered app errors to json" {
    const app_mod = @import("../app/app.zig");

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.errors.register(app_error.Def{
        .err = error.NotAllowedHere,
        .status = .forbidden,
        .code = "NOT_ALLOWED",
        .message = "Not allowed.",
    });
    try app.onError(errorHandler(.{}));
    try app.get("/boom", struct {
        fn run(_: *Context) !Response {
            return error.NotAllowedHere;
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/boom", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"code\":\"NOT_ALLOWED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"message\":\"Not allowed.\"") != null);
}

test "error handler maps request helper defaults" {
    const app_mod = @import("../app/app.zig");

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.onError(errorHandler(.{ .log_internal_errors = false }));
    try app.get("/boom", struct {
        fn run(_: *Context) !Response {
            return error.InvalidQuery;
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/boom", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"code\":\"INVALID_QUERY\"") != null);
}

test "routed apps carry nested app error definitions" {
    const app_mod = @import("../app/app.zig");

    var api = app_mod.App.init(std.testing.allocator);
    defer api.deinit();
    try api.errors.register(.{
        .err = error.EmailTaken,
        .status = .conflict,
        .code = "EMAIL_TAKEN",
        .message = "Email is already taken.",
    });
    try api.onError(errorHandler(.{}));
    try api.get("/users", struct {
        fn run(_: *Context) !Response {
            return error.EmailTaken;
        }
    }.run);

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();
    try app.route("/api", &api);

    var res = try app.request(std.testing.allocator, "/api/users", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.conflict, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"code\":\"EMAIL_TAKEN\"") != null);
}

test "error handler turns observed details into safe database errors" {
    const app_mod = @import("../app/app.zig");

    const FakeDetail = struct {
        err: anyerror,

        fn hasDetail(_: @This()) bool {
            return true;
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("db detail {s}", .{@errorName(self.err)});
        }
    };

    const Source = struct {
        pub fn errorDetail(_: *const @This(), err: anyerror) FakeDetail {
            return .{ .err = err };
        }
    };

    var source = Source{};
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.errors.observe(&source);
    try app.onError(errorHandler(.{ .log_internal_errors = false }));
    try app.get("/db", struct {
        fn run(_: *Context) !Response {
            return error.ServerError;
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/db", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"code\":\"DATABASE_ERROR\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "db detail") == null);
}

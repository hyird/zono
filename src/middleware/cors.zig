const std = @import("std");
const app_mod = @import("../app/app.zig");
const Context = @import("../core/context.zig").Context;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const http_method = @import("../core/http_method.zig");

pub const Options = struct {
    origin: []const []const u8 = &.{"*"},
    allow_methods: []const []const u8 = &.{ "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    allow_headers: []const []const u8 = &.{},
    expose_headers: []const []const u8 = &.{},
    credentials: bool = false,
    max_age: ?u32 = 86_400,
};

const MiddlewareFn = fn (c: *Context, next: Context.Next) Response;

pub fn cors(comptime cors_options: Options) MiddlewareFn {
    const allow_methods_value = comptime joinHeaderValuesComptime(cors_options.allow_methods);
    const allow_headers_value = comptime joinHeaderValuesComptime(cors_options.allow_headers);
    const expose_headers_value = comptime joinHeaderValuesComptime(cors_options.expose_headers);
    const max_age_value = comptime maxAgeHeaderValue(cors_options.max_age);

    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            const origin = c.req.header("origin") orelse {
                next.run();
                return c.takeResponse();
            };

            const allow_origin = allowedOrigin(origin, cors_options) orelse {
                next.run();
                return c.takeResponse();
            };

            if (http_method.isOptions(c.req.methodName()) and
                c.req.header("access-control-request-method") != null)
            {
                c.status(.no_content);
                if (!applyPreflightHeaders(c, origin, allow_origin, cors_options, allow_methods_value, allow_headers_value, expose_headers_value, max_age_value)) {
                    return response_mod.internalError("cors header allocation failed");
                }
                return c.takeResponse();
            }

            next.run();
            if (!applySimpleHeaders(c, origin, allow_origin, cors_options, expose_headers_value)) {
                return response_mod.internalError("cors header allocation failed");
            }
            return c.takeResponse();
        }
    }.run;
}

fn allowedOrigin(origin: []const u8, comptime cors_options: Options) ?[]const u8 {
    for (cors_options.origin) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) {
            return if (cors_options.credentials) origin else "*";
        }
        if (std.mem.eql(u8, allowed, origin)) return origin;
    }
    return null;
}

fn applySimpleHeaders(
    c: *Context,
    origin: []const u8,
    allow_origin: []const u8,
    comptime cors_options: Options,
    comptime expose_headers_value: []const u8,
) bool {
    if (!setHeader(c, "Access-Control-Allow-Origin", allow_origin)) return false;
    if (cors_options.credentials) {
        if (!setHeader(c, "Access-Control-Allow-Credentials", "true")) return false;
    }
    if (!std.mem.eql(u8, allow_origin, "*")) {
        if (!appendVary(c, "Origin")) return false;
    }
    if (cors_options.expose_headers.len != 0) {
        if (!setHeader(c, "Access-Control-Expose-Headers", expose_headers_value)) return false;
    }
    _ = origin;
    return true;
}

fn applyPreflightHeaders(
    c: *Context,
    origin: []const u8,
    allow_origin: []const u8,
    comptime cors_options: Options,
    comptime allow_methods_value: []const u8,
    comptime allow_headers_value: []const u8,
    comptime expose_headers_value: []const u8,
    comptime max_age_value: []const u8,
) bool {
    if (!applySimpleHeaders(c, origin, allow_origin, cors_options, expose_headers_value)) return false;
    if (!appendVaryMany(c, &.{ "Access-Control-Request-Method", "Access-Control-Request-Headers" })) return false;

    if (!setHeader(c, "Access-Control-Allow-Methods", allow_methods_value)) return false;

    if (cors_options.allow_headers.len != 0) {
        if (!setHeader(c, "Access-Control-Allow-Headers", allow_headers_value)) return false;
    } else if (c.req.header("access-control-request-headers")) |requested| {
        if (!setHeader(c, "Access-Control-Allow-Headers", requested)) return false;
    }

    if (cors_options.max_age != null) {
        if (!setHeader(c, "Access-Control-Max-Age", max_age_value)) return false;
    }

    return true;
}

fn setHeader(c: *Context, name: []const u8, value: []const u8) bool {
    c.res.ensureOwned(c.req.allocator) catch return false;
    return c.header(name, value);
}

fn appendVary(c: *Context, token: []const u8) bool {
    if (c.res.headerValue("vary")) |existing| {
        if (headerContainsToken(existing, token)) return true;
        const joined = std.fmt.allocPrint(c.req.allocator, "{s}, {s}", .{ existing, token }) catch return false;
        defer c.req.allocator.free(joined);
        return setHeader(c, "Vary", joined);
    }
    return setHeader(c, "Vary", token);
}

fn appendVaryMany(c: *Context, tokens: []const []const u8) bool {
    if (c.res.headerValue("vary")) |existing| {
        var missing_count: usize = 0;
        var missing_len: usize = 0;
        for (tokens) |token| {
            if (!headerContainsToken(existing, token)) {
                missing_count += 1;
                missing_len += token.len;
            }
        }
        if (missing_count == 0) return true;

        const extra_len = missing_len + (missing_count * 2);
        const joined = c.req.allocator.alloc(u8, existing.len + extra_len) catch return false;
        defer c.req.allocator.free(joined);
        @memcpy(joined[0..existing.len], existing);
        var pos = existing.len;
        for (tokens) |token| {
            if (headerContainsToken(existing, token)) continue;
            joined[pos..][0..2].* = ", ".*;
            pos += 2;
            @memcpy(joined[pos..][0..token.len], token);
            pos += token.len;
        }
        return setHeader(c, "Vary", joined[0..pos]);
    }
    return setHeader(c, "Vary", "Access-Control-Request-Method, Access-Control-Request-Headers");
}

fn headerContainsToken(header_value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

fn joinHeaderValuesComptime(comptime values: []const []const u8) []const u8 {
    comptime {
        var len: usize = 0;
        for (values, 0..) |value, index| {
            if (index != 0) len += 2;
            len += value.len;
        }

        var buffer: [len]u8 = undefined;
        var pos: usize = 0;
        for (values, 0..) |value, index| {
            if (index != 0) {
                buffer[pos] = ',';
                buffer[pos + 1] = ' ';
                pos += 2;
            }
            @memcpy(buffer[pos..][0..value.len], value);
            pos += value.len;
        }
        const final = buffer;
        return final[0..];
    }
}

fn maxAgeHeaderValue(comptime max_age: ?u32) []const u8 {
    return if (max_age) |value| std.fmt.comptimePrint("{d}", .{value}) else "";
}

test "cors handles preflight without calling downstream" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(cors(.{
        .origin = &.{"https://app.example"},
        .allow_methods = &.{ "GET", "POST" },
        .allow_headers = &.{"X-Token"},
        .credentials = true,
    }));
    try app.options("/api", struct {
        fn run(c: *Context) Response {
            return c.text("should not run");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/api", .{
        .method = .OPTIONS,
        .headers = &.{
            .{ .name = "origin", .value = "https://app.example" },
            .{ .name = "access-control-request-method", .value = "POST" },
        },
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.no_content, res.status);
    try std.testing.expectEqualStrings("https://app.example", res.headerValue("access-control-allow-origin").?);
    try std.testing.expectEqualStrings("true", res.headerValue("access-control-allow-credentials").?);
    try std.testing.expectEqualStrings("GET, POST", res.headerValue("access-control-allow-methods").?);
    try std.testing.expectEqualStrings("X-Token", res.headerValue("access-control-allow-headers").?);
    const vary = res.headerValue("vary").?;
    try std.testing.expect(headerContainsToken(vary, "Origin"));
    try std.testing.expect(headerContainsToken(vary, "Access-Control-Request-Method"));
    try std.testing.expect(headerContainsToken(vary, "Access-Control-Request-Headers"));
}

test "cors appends simple response headers" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(cors(.{ .origin = &.{"*"} }));
    try app.get("/api", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/api", .{
        .headers = &.{.{ .name = "origin", .value = "https://app.example" }},
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("*", res.headerValue("access-control-allow-origin").?);
    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "cors reflects preflight request headers by default" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(cors(.{}));

    var res = try app.request(std.testing.allocator, "/api", .{
        .method = .OPTIONS,
        .headers = &.{
            .{ .name = "origin", .value = "https://app.example" },
            .{ .name = "access-control-request-method", .value = "POST" },
            .{ .name = "access-control-request-headers", .value = "X-Token, X-Trace" },
        },
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.no_content, res.status);
    try std.testing.expectEqualStrings("X-Token, X-Trace", res.headerValue("access-control-allow-headers").?);
}

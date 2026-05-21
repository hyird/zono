const std = @import("std");
const Context = @import("../core/context.zig").Context;
const Response = @import("../response/response.zig").Response;
const time = @import("../core/time.zig");

pub const context_key = "requestId";

pub const Generator = *const fn (c: *Context) anyerror![]const u8;

pub const Options = struct {
    header_name: []const u8 = "X-Request-Id",
    limit_length: usize = 255,
    generator: Generator = defaultGenerator,
};

const MiddlewareFn = fn (c: *Context, next: Context.Next) Response;

pub fn requestId(comptime options: Options) MiddlewareFn {
    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            const incoming = incomingRequestId(c, options);
            const id = incoming orelse options.generator(c) catch "";
            if (id.len > 0) {
                c.set(context_key, id) catch {};
            }

            next.run();
            if (id.len > 0 and options.header_name.len > 0) {
                _ = c.header(options.header_name, id);
            }
            return c.takeResponse();
        }
    }.run;
}

fn incomingRequestId(c: *Context, comptime options: Options) ?[]const u8 {
    if (options.header_name.len == 0) return null;
    const value = c.req.header(options.header_name) orelse return null;
    if (value.len == 0 or value.len > options.limit_length) return null;
    return value;
}

fn defaultGenerator(c: *Context) anyerror![]const u8 {
    var bytes: [16]u8 = undefined;
    if (c.io()) |io| {
        std.Io.random(io, &bytes);
    } else {
        var prng = std.Random.DefaultPrng.init(time.nowNanoseconds() ^ @as(u64, @intCast(@intFromPtr(c))));
        prng.random().bytes(&bytes);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const out = try c.req.allocator.alloc(u8, 36);
    encodeHex(out[0..8], bytes[0..4]);
    out[8] = '-';
    encodeHex(out[9..13], bytes[4..6]);
    out[13] = '-';
    encodeHex(out[14..18], bytes[6..8]);
    out[18] = '-';
    encodeHex(out[19..23], bytes[8..10]);
    out[23] = '-';
    encodeHex(out[24..36], bytes[10..16]);
    return out;
}

fn encodeHex(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

test "requestId reuses incoming header and exposes context value" {
    const app_mod = @import("../app/app.zig");

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(requestId(.{}));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.get([]const u8, context_key) orelse "missing");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/", .{
        .headers = &.{.{ .name = "X-Request-Id", .value = "req-1" }},
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("req-1", res.bodyBytes());
    try std.testing.expectEqualStrings("req-1", res.headerValue("X-Request-Id").?);
}

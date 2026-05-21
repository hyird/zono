const std = @import("std");
const response_mod = @import("../response/response.zig");
const Response = response_mod.Response;

pub const HTTPException = struct {
    status: std.http.Status,
    message: ?[]const u8 = null,
    res: ?Response = null,
    cause: ?anyerror = null,

    pub const Options = struct {
        message: ?[]const u8 = null,
        res: ?Response = null,
        cause: ?anyerror = null,
    };

    pub fn init(status: std.http.Status, options: Options) HTTPException {
        return .{
            .status = status,
            .message = options.message,
            .res = options.res,
            .cause = options.cause,
        };
    }

    pub fn raise(self: HTTPException, c: anytype) anyerror!Response {
        c.setHTTPException(self);
        return error.HTTPException;
    }

    pub fn getResponse(self: *const HTTPException, allocator: std.mem.Allocator) Response {
        if (self.res) |custom_response| {
            var response = custom_response.clone(allocator) catch
                return response_mod.internalError("http exception response clone failed");
            response.setStatus(self.status);
            return response;
        }

        return response_mod.text(self.status, self.message orelse defaultMessage(self.status));
    }

    pub fn deinit(self: *HTTPException) void {
        if (self.res) |*custom_response| custom_response.deinit();
        self.res = null;
    }
};

fn defaultMessage(status: std.http.Status) []const u8 {
    return status.phrase() orelse "Error";
}

test "HTTPException returns a text response from status and message" {
    const exception = HTTPException.init(.unauthorized, .{ .message = "Unauthorized" });
    var response = exception.getResponse(std.testing.allocator);
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
    try std.testing.expectEqualStrings("Unauthorized", response.bodyBytes());
}

test "HTTPException applies constructor status to custom responses" {
    var custom = response_mod.text(.ok, "denied");
    _ = custom.header("www-authenticate", "Bearer");
    var exception = HTTPException.init(.unauthorized, .{ .res = custom });
    defer exception.deinit();

    var response = exception.getResponse(std.testing.allocator);
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
    try std.testing.expectEqualStrings("denied", response.bodyBytes());
    try std.testing.expectEqualStrings("Bearer", response.headerValue("www-authenticate").?);
}

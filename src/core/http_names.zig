const std = @import("std");

pub fn isContentType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type");
}

pub fn isLocation(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "location");
}

pub fn isAllow(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "allow");
}

pub fn isSetCookie(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "set-cookie");
}

pub fn isContentLength(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length");
}

pub fn isTransferEncoding(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

pub fn isDisallowedResponseHeader(name: []const u8) bool {
    if (isContentLength(name)) return true;
    if (isTransferEncoding(name)) return true;
    if (std.ascii.eqlIgnoreCase(name, "connection")) return true;
    if (std.ascii.eqlIgnoreCase(name, "upgrade")) return true;
    if (std.ascii.eqlIgnoreCase(name, "keep-alive")) return true;
    if (std.ascii.eqlIgnoreCase(name, "proxy-connection")) return true;
    if (std.ascii.eqlIgnoreCase(name, "te")) return true;
    if (std.ascii.eqlIgnoreCase(name, "trailer")) return true;
    return false;
}

test "common HTTP header names are case-insensitive" {
    try std.testing.expect(isContentType("Content-Type"));
    try std.testing.expect(isSetCookie("set-cookie"));
    try std.testing.expect(isDisallowedResponseHeader("Transfer-Encoding"));
    try std.testing.expect(isDisallowedResponseHeader("Content-Length"));
    try std.testing.expect(!isDisallowedResponseHeader("x-custom"));
}

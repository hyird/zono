const std = @import("std");

pub fn isGet(method_name: []const u8) bool {
    return eqlIgnoreCaseLiteral(method_name, "GET");
}

pub fn isHead(method_name: []const u8) bool {
    return eqlIgnoreCaseLiteral(method_name, "HEAD");
}

pub fn isOptions(method_name: []const u8) bool {
    return eqlIgnoreCaseLiteral(method_name, "OPTIONS");
}

pub fn isGetOrHead(method_name: []const u8) bool {
    return isGet(method_name) or isHead(method_name);
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (std.mem.eql(u8, a, b)) return true;
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn optionalMatches(expected: ?[]const u8, actual: []const u8) bool {
    const method_name = expected orelse return true;
    return eqlIgnoreCase(method_name, actual);
}

fn eqlIgnoreCaseLiteral(value: []const u8, comptime literal: []const u8) bool {
    if (value.len != literal.len) return false;
    inline for (literal, 0..) |expected, index| {
        const actual = value[index];
        if (actual != expected and actual != expected + ('a' - 'A')) return false;
    }
    return true;
}

test "method helpers are case-insensitive" {
    try std.testing.expect(isGet("get"));
    try std.testing.expect(isHead("HEAD"));
    try std.testing.expect(isOptions("Options"));
    try std.testing.expect(isGetOrHead("head"));
    try std.testing.expect(eqlIgnoreCase("REPORT", "report"));
    try std.testing.expect(optionalMatches(null, "PATCH"));
    try std.testing.expect(optionalMatches("patch", "PATCH"));
}

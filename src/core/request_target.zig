const std = @import("std");

pub const Split = struct {
    path: []const u8,
    query_string: []const u8,
};

pub fn split(target: []const u8) Split {
    var path_and_query = stripAbsoluteFormAuthority(target);

    const query_index = std.mem.indexOfScalar(u8, path_and_query, '?');
    const path = if (query_index) |index|
        if (index == 0) "/" else path_and_query[0..index]
    else if (path_and_query.len == 0)
        "/"
    else
        path_and_query;

    return .{
        .path = path,
        .query_string = if (query_index) |index|
            if (index + 1 < path_and_query.len) path_and_query[index + 1 ..] else ""
        else
            "",
    };
}

pub fn splitAlloc(allocator: std.mem.Allocator, target: []const u8) !Split {
    const parsed = split(target);
    if (parsed.path.len == 0 or parsed.path[0] == '/') return parsed;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '/');
    try out.appendSlice(allocator, parsed.path);

    return .{
        .path = try out.toOwnedSlice(allocator),
        .query_string = parsed.query_string,
    };
}

fn stripAbsoluteFormAuthority(target: []const u8) []const u8 {
    if (absoluteFormSchemeEnd(target)) |scheme_index| {
        const authority_start = scheme_index + 3;
        const path_index = std.mem.indexOfScalarPos(u8, target, authority_start, '/') orelse target.len;
        const query_index = std.mem.indexOfScalarPos(u8, target, authority_start, '?') orelse target.len;
        const first_index = @min(path_index, query_index);
        return if (first_index == target.len) "/" else target[first_index..];
    }
    return target;
}

fn absoluteFormSchemeEnd(target: []const u8) ?usize {
    if (target.len == 0 or target[0] == '/') return null;
    if (!std.ascii.isAlphabetic(target[0])) return null;

    var index: usize = 1;
    while (index < target.len) : (index += 1) {
        const c = target[index];
        if (c == ':' and index + 2 < target.len and target[index + 1] == '/' and target[index + 2] == '/') {
            return index;
        }
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return null;
}

test "split accepts absolute-form targets" {
    const parsed = split("http://example.com/hello/world?x=1&y=2");
    try std.testing.expectEqualStrings("/hello/world", parsed.path);
    try std.testing.expectEqualStrings("x=1&y=2", parsed.query_string);

    const root = split("http://example.com?x=1");
    try std.testing.expectEqualStrings("/", root.path);
    try std.testing.expectEqualStrings("x=1", root.query_string);
}

test "split keeps embedded scheme in origin-form paths" {
    const origin = split("/proxy/http://example.com/file?x=1");
    try std.testing.expectEqualStrings("/proxy/http://example.com/file", origin.path);
    try std.testing.expectEqualStrings("x=1", origin.query_string);
}

test "splitAlloc prefixes relative request targets" {
    const allocator = std.testing.allocator;
    const parsed = try splitAlloc(allocator, "users?active=1");
    defer allocator.free(parsed.path);

    try std.testing.expectEqualStrings("/users", parsed.path);
    try std.testing.expectEqualStrings("active=1", parsed.query_string);
}

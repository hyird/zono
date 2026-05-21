const std = @import("std");

pub fn cleanPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return "/";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '/');

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(allocator);

    const rooted = input[0] == '/';
    var index: usize = if (rooted) 1 else 0;
    const trailing = input.len > 1 and input[input.len - 1] == '/';

    while (index <= input.len) {
        const end = std.mem.indexOfScalarPos(u8, input, index, '/') orelse input.len;
        const segment = input[index..end];

        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            // Skip empty and current-dir segments.
        } else if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
        } else {
            try segments.append(allocator, segment);
        }

        if (end == input.len) break;
        index = end + 1;
    }

    for (segments.items, 0..) |segment, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }

    if (trailing and out.items.len > 1) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

pub fn needsCleaning(input: []const u8) bool {
    if (input.len == 0) return true;
    if (input[0] != '/') return true;

    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (input[index] != '/') continue;

        if (index > 0 and input[index - 1] == '/') return true;
        if (isDotSegment(input[segment_start..index])) return true;
        segment_start = index + 1;
    }

    return isDotSegment(input[segment_start..]);
}

pub fn countSegments(path: []const u8) usize {
    var count: usize = 0;
    var in_segment = false;
    for (path) |c| {
        if (c == '/') {
            in_segment = false;
            continue;
        }
        if (!in_segment) {
            count += 1;
            in_segment = true;
        }
    }
    return count;
}

pub fn exceedsSegmentLimit(path: []const u8, max_segments: usize) bool {
    var count: usize = 0;
    var in_segment = false;
    for (path) |c| {
        if (c == '/') {
            in_segment = false;
            continue;
        }
        if (!in_segment) {
            count += 1;
            if (count > max_segments) return true;
            in_segment = true;
        }
    }
    return false;
}

fn isDotSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..");
}

test "cleanPath normalizes slash, dot, and dot-dot segments" {
    const allocator = std.testing.allocator;

    const cleaned = try cleanPath(allocator, "/..//Users/./42/");
    defer allocator.free(cleaned);

    try std.testing.expectEqualStrings("/Users/42/", cleaned);
}

test "countSegments ignores repeated and surrounding slashes" {
    try std.testing.expectEqual(@as(usize, 0), countSegments(""));
    try std.testing.expectEqual(@as(usize, 0), countSegments("///"));
    try std.testing.expectEqual(@as(usize, 2), countSegments("/users/42/"));
    try std.testing.expectEqual(@as(usize, 2), countSegments("users//42"));
}

test "exceedsSegmentLimit stops at the limit boundary" {
    try std.testing.expect(!exceedsSegmentLimit("/users/42", 2));
    try std.testing.expect(exceedsSegmentLimit("/users/42/posts", 2));
    try std.testing.expect(exceedsSegmentLimit("/users", 0));
    try std.testing.expect(!exceedsSegmentLimit("///", 0));
}

test "needsCleaning detects only paths that cleanPath would rewrite" {
    try std.testing.expect(!needsCleaning("/users/42"));
    try std.testing.expect(!needsCleaning("/users/42/"));
    try std.testing.expect(needsCleaning(""));
    try std.testing.expect(needsCleaning("users/42"));
    try std.testing.expect(needsCleaning("/users//42"));
    try std.testing.expect(needsCleaning("/users/./42"));
    try std.testing.expect(needsCleaning("/users/../42"));
}

const std = @import("std");

pub fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}

pub fn isStringSliceLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

test "string-like type helpers preserve API coercion rules" {
    try std.testing.expect(isStringLike([]const u8));
    try std.testing.expect(isStringLike(*const [2]u8));
    try std.testing.expect(isStringLike([2]u8));
    try std.testing.expect(!isStringLike([]const i8));

    try std.testing.expect(isStringSliceLike([]const u8));
    try std.testing.expect(isStringSliceLike(*const [2]u8));
    try std.testing.expect(!isStringSliceLike([2]u8));
}

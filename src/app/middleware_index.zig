const std = @import("std");
const http_method = @import("../core/http_method.zig");

pub const MiddlewareIndex = struct {
    all: []usize = &.{},
    buckets: []Bucket = &.{},

    const Bucket = struct {
        method_name: []const u8,
        candidates: []usize,
    };

    pub fn build(allocator: std.mem.Allocator, entries: anytype) !MiddlewareIndex {
        var all_builder: std.ArrayListUnmanaged(usize) = .empty;
        errdefer all_builder.deinit(allocator);

        var method_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer method_names.deinit(allocator);

        for (entries, 0..) |entry, index| {
            if (entry.method_name) |method_name| {
                if (!containsMethod(method_names.items, method_name)) {
                    try method_names.append(allocator, method_name);
                }
            } else {
                try all_builder.append(allocator, index);
            }
        }

        var bucket_builder: std.ArrayListUnmanaged(Bucket) = .empty;
        errdefer {
            for (bucket_builder.items) |bucket| freeSlice(allocator, bucket.candidates);
            bucket_builder.deinit(allocator);
        }

        for (method_names.items) |method_name| {
            var candidates: std.ArrayListUnmanaged(usize) = .empty;
            errdefer candidates.deinit(allocator);

            for (entries, 0..) |entry, index| {
                if (http_method.optionalMatches(entry.method_name, method_name)) {
                    try candidates.append(allocator, index);
                }
            }

            try bucket_builder.append(allocator, .{
                .method_name = method_name,
                .candidates = try candidates.toOwnedSlice(allocator),
            });
        }

        var result: MiddlewareIndex = .{
            .all = try all_builder.toOwnedSlice(allocator),
            .buckets = try bucket_builder.toOwnedSlice(allocator),
        };
        errdefer result.deinit(allocator);
        return result;
    }

    pub fn deinit(self: *MiddlewareIndex, allocator: std.mem.Allocator) void {
        freeSlice(allocator, self.all);
        for (self.buckets) |bucket| {
            freeSlice(allocator, bucket.candidates);
        }
        freeSlice(allocator, self.buckets);
        self.* = .{};
    }

    pub fn candidatesFor(self: *const MiddlewareIndex, method_name: []const u8) []const usize {
        for (self.buckets) |bucket| {
            if (std.ascii.eqlIgnoreCase(bucket.method_name, method_name)) return bucket.candidates;
        }
        return self.all;
    }

    fn containsMethod(method_names: []const []const u8, candidate: []const u8) bool {
        for (method_names) |method_name| {
            if (std.ascii.eqlIgnoreCase(method_name, candidate)) return true;
        }
        return false;
    }
};

pub const RouteMiddlewareIndex = struct {
    routes: []RouteBucket = &.{},

    const RouteBucket = struct {
        candidates: []usize = &.{},
        complete: bool = false,
    };

    const PrefixDecision = enum {
        match,
        no_match,
        unknown,
    };

    pub fn build(allocator: std.mem.Allocator, entries: anytype, routes: anytype) !RouteMiddlewareIndex {
        var buckets: std.ArrayListUnmanaged(RouteBucket) = .empty;
        errdefer {
            for (buckets.items) |bucket| freeSlice(allocator, bucket.candidates);
            buckets.deinit(allocator);
        }

        for (routes) |route| {
            var candidates: std.ArrayListUnmanaged(usize) = .empty;
            errdefer candidates.deinit(allocator);

            var complete = true;
            for (entries, 0..) |entry, index| {
                if (!http_method.optionalMatches(entry.method_name, routeMethodName(route))) continue;

                switch (prefixDecision(entry.prefix, route.path)) {
                    .match => try candidates.append(allocator, index),
                    .no_match => {},
                    .unknown => {
                        complete = false;
                        break;
                    },
                }
            }

            if (!complete) {
                candidates.deinit(allocator);
                try buckets.append(allocator, .{
                    .candidates = &.{},
                    .complete = false,
                });
                continue;
            }

            try buckets.append(allocator, .{
                .candidates = try candidates.toOwnedSlice(allocator),
                .complete = true,
            });
        }

        return .{
            .routes = try buckets.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *RouteMiddlewareIndex, allocator: std.mem.Allocator) void {
        for (self.routes) |bucket| freeSlice(allocator, bucket.candidates);
        freeSlice(allocator, self.routes);
        self.* = .{};
    }

    pub fn candidatesFor(self: *const RouteMiddlewareIndex, route_index: usize) ?[]const usize {
        if (route_index >= self.routes.len) return null;
        const bucket = self.routes[route_index];
        if (!bucket.complete) return null;
        return bucket.candidates;
    }

    fn routeMethodName(route: anytype) []const u8 {
        return if (route.method_name.len > 0) route.method_name else @tagName(route.method);
    }

    fn prefixDecision(prefix: []const u8, route_path: []const u8) PrefixDecision {
        if (prefix.len == 0) return .match;
        if (pathPrefixMatches(prefix, route_path)) return .match;
        if (routeMayMatchPrefix(route_path, prefix)) return .unknown;
        return .no_match;
    }

    fn pathPrefixMatches(prefix: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, path, prefix)) return true;
        return path.len > prefix.len and
            std.mem.startsWith(u8, path, prefix) and
            path[prefix.len] == '/';
    }

    fn routeMayMatchPrefix(route_path: []const u8, prefix: []const u8) bool {
        const wildcard_index = firstWildcardIndex(route_path) orelse return false;
        const static_prefix = staticSegmentPrefix(route_path, wildcard_index);
        if (static_prefix.len == 0) return true;
        return std.mem.startsWith(u8, prefix, static_prefix);
    }

    fn firstWildcardIndex(path: []const u8) ?usize {
        for (path, 0..) |byte, index| {
            if (byte == ':' or byte == '*') return index;
        }
        return null;
    }

    fn staticSegmentPrefix(path: []const u8, wildcard_index: usize) []const u8 {
        if (wildcard_index == 0) return "";
        var end = wildcard_index;
        while (end > 0 and path[end - 1] != '/') : (end -= 1) {}
        if (end > 0 and path[end - 1] == '/') end -= 1;
        return path[0..end];
    }
};

fn freeSlice(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}

test "middleware index keeps custom method candidates in registration order" {
    const Entry = struct {
        method_name: ?[]const u8 = null,
    };

    const entries = [_]Entry{
        .{},
        .{ .method_name = "REPORT" },
        .{ .method_name = "GET" },
        .{ .method_name = "report" },
    };

    var index = try MiddlewareIndex.build(std.testing.allocator, &entries);
    defer index.deinit(std.testing.allocator);

    const report = index.candidatesFor("REPORT");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, report);

    const get = index.candidatesFor("GET");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, get);

    const unknown = index.candidatesFor("POST");
    try std.testing.expectEqualSlices(usize, &.{0}, unknown);
}

test "route middleware index precomputes static route candidates" {
    const Entry = struct {
        prefix: []const u8,
        method_name: ?[]const u8 = null,
    };
    const Route = struct {
        method: std.http.Method,
        method_name: []const u8 = "",
        path: []const u8,
    };

    const entries = [_]Entry{
        .{ .prefix = "" },
        .{ .prefix = "/api" },
        .{ .prefix = "/admin" },
        .{ .prefix = "/api", .method_name = "POST" },
        .{ .prefix = "/users/123" },
    };
    const routes = [_]Route{
        .{ .method = .GET, .path = "/api/users" },
        .{ .method = .POST, .path = "/api/users" },
        .{ .method = .GET, .path = "/users/:id" },
    };

    var index = try RouteMiddlewareIndex.build(std.testing.allocator, &entries, &routes);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, index.candidatesFor(0).?);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, index.candidatesFor(1).?);
    try std.testing.expect(index.candidatesFor(2) == null);
}

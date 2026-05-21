const std = @import("std");
const request_mod = @import("../request/request.zig");
const Request = request_mod.Request;
const Param = request_mod.Param;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const path_mod = @import("../core/path.zig");
const http_method = @import("../core/http_method.zig");

pub const Handler = *const fn (req: Request) Response;
pub const ErrorHandler = *const fn (err: anyerror, req: Request) Response;

pub const Route = struct {
    method: std.http.Method,
    method_name: []const u8 = "",
    method_name_owned: bool = false,
    path: []const u8,
    handler: Handler,
    base_path: ?[]const u8 = null,
    base_path_owned: bool = false,
    on_error_handler: ?ErrorHandler = null,
};

pub const LookupResult = struct {
    handler: ?Handler = null,
    params: []const Param = &.{},
    params_storage: ?[]Param = null,
    route_path: ?[]const u8 = null,
    base_route_path: ?[]const u8 = null,
    route_index: ?usize = null,
    on_error_handler: ?ErrorHandler = null,
    reject: ?LookupReject = null,
    tsr: bool = false,
};

pub const LookupReject = enum {
    path_too_long,
    too_many_segments,
    param_value_too_long,
};

pub const Limits = struct {
    max_path_bytes: usize = 4096,
    max_segments: usize = 64,
    max_params: usize = 8,
    max_param_name_bytes: usize = 64,
    max_param_value_bytes: usize = 1024,
};

pub const InitError = std.mem.Allocator.Error || error{
    DuplicateRoute,
    RouteConflict,
    InvalidWildcard,
    CatchAllNotAtEnd,
    MissingCatchAllSlash,
    InvalidPattern,
    PathTooLong,
    TooManySegments,
    TooManyParams,
    ParamNameTooLong,
};

const Wildcard = struct {
    token: []const u8 = "",
    index: usize = 0,
    found: bool = false,
    valid: bool = false,
};

const NodeType = enum {
    static,
    root,
    param,
    catch_all,
};

const Match = struct {
    handler: ?Handler = null,
    param_count: usize = 0,
    route_path: ?[]const u8 = null,
    base_route_path: ?[]const u8 = null,
    route_index: ?usize = null,
    on_error_handler: ?ErrorHandler = null,
    tsr: bool = false,
};

const StaticRoute = struct {
    handler: Handler,
    route_path: []const u8,
    base_route_path: ?[]const u8 = null,
    route_index: usize = 0,
    on_error_handler: ?ErrorHandler = null,
};

const MethodTree = struct {
    method: std.http.Method,
    method_name: []const u8,
    root: *Node,
    exact_routes: std.StringHashMapUnmanaged(StaticRoute) = .empty,
    max_params: usize = 0,
};

const FallbackRoute = struct {
    method: std.http.Method,
    method_name: []const u8,
    path: []const u8,
    handler: Handler,
    base_path: ?[]const u8 = null,
    route_index: usize = 0,
    on_error_handler: ?ErrorHandler = null,
    max_params: usize = 0,
};

const Node = struct {
    path: []const u8 = "",
    indices: std.ArrayListUnmanaged(u8) = .empty,
    wild_child: bool = false,
    n_type: NodeType = .static,
    priority: u32 = 0,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    handler: ?Handler = null,
    route_path: ?[]const u8 = null,
    base_route_path: ?[]const u8 = null,
    route_index: ?usize = null,
    on_error_handler: ?ErrorHandler = null,

    fn addRoute(self: *Node, allocator: std.mem.Allocator, full_path: []const u8, base_path: ?[]const u8, handler: Handler, route_index: usize, on_error_handler: ?ErrorHandler) InitError!void {
        var n = self;
        var path = full_path;

        n.priority += 1;
        if (n.path.len == 0 and n.indices.items.len == 0 and n.children.items.len == 0) {
            try n.insertChild(allocator, path, base_path, handler, route_index, on_error_handler);
            n.n_type = .root;
            return;
        }

        walk: while (true) {
            const common_prefix = longestCommonPrefix(path, n.path);

            if (common_prefix < n.path.len) {
                const child = try createNode(allocator);
                child.* = .{
                    .path = n.path[common_prefix..],
                    .indices = n.indices,
                    .wild_child = n.wild_child,
                    .n_type = .static,
                    .priority = n.priority - 1,
                    .children = n.children,
                    .handler = n.handler,
                    .route_path = n.route_path,
                    .base_route_path = n.base_route_path,
                    .route_index = n.route_index,
                    .on_error_handler = n.on_error_handler,
                };

                n.children = .empty;
                try n.children.append(allocator, child);

                n.indices = .empty;
                try n.indices.append(allocator, n.path[common_prefix]);

                n.path = n.path[0..common_prefix];
                n.handler = null;
                n.route_path = null;
                n.base_route_path = null;
                n.route_index = null;
                n.on_error_handler = null;
                n.wild_child = false;
            }

            if (common_prefix < path.len) {
                path = path[common_prefix..];

                if (n.wild_child) {
                    n = n.children.items[0];
                    n.priority += 1;

                    if (path.len >= n.path.len and
                        std.mem.eql(u8, n.path, path[0..n.path.len]) and
                        n.n_type != .catch_all and
                        (n.path.len >= path.len or path[n.path.len] == '/'))
                    {
                        continue :walk;
                    }

                    return error.RouteConflict;
                }

                const idxc = path[0];

                if (n.n_type == .param and idxc == '/' and n.children.items.len == 1) {
                    n = n.children.items[0];
                    n.priority += 1;
                    continue :walk;
                }

                for (n.indices.items, 0..) |candidate, child_index| {
                    if (candidate == idxc) {
                        const new_pos = n.incrementChildPrio(child_index);
                        n = n.children.items[new_pos];
                        continue :walk;
                    }
                }

                if (idxc != ':' and idxc != '*') {
                    const child = try createNode(allocator);
                    try n.indices.append(allocator, idxc);
                    try n.children.append(allocator, child);
                    const new_pos = n.incrementChildPrio(n.children.items.len - 1);
                    n = n.children.items[new_pos];
                }

                try n.insertChild(allocator, path, base_path, handler, route_index, on_error_handler);
                return;
            }

            if (n.handler != null) return error.DuplicateRoute;
            n.handler = handler;
            n.route_path = full_path;
            n.base_route_path = base_path;
            n.route_index = route_index;
            n.on_error_handler = on_error_handler;
            return;
        }
    }

    fn insertChild(self: *Node, allocator: std.mem.Allocator, full_path: []const u8, base_path: ?[]const u8, handler: Handler, route_index: usize, on_error_handler: ?ErrorHandler) InitError!void {
        var n = self;
        var path = full_path;

        while (true) {
            const wildcard = findWildcard(path);
            if (!wildcard.found) break;

            if (!wildcard.valid or wildcard.token.len < 2) {
                return error.InvalidWildcard;
            }

            if (n.children.items.len > 0) {
                return error.RouteConflict;
            }

            if (wildcard.token[0] == ':') {
                if (wildcard.index > 0) {
                    n.path = path[0..wildcard.index];
                    path = path[wildcard.index..];
                }

                n.wild_child = true;
                const child = try createNode(allocator);
                child.* = .{
                    .path = wildcard.token,
                    .n_type = .param,
                };
                try n.children.append(allocator, child);
                n = child;
                n.priority += 1;

                if (wildcard.token.len < path.len) {
                    path = path[wildcard.token.len..];
                    const next = try createNode(allocator);
                    next.priority = 1;
                    try n.children.append(allocator, next);
                    n = next;
                    continue;
                }

                n.handler = handler;
                n.route_path = full_path;
                n.base_route_path = base_path;
                n.route_index = route_index;
                n.on_error_handler = on_error_handler;
                return;
            }

            if (wildcard.index + wildcard.token.len != path.len) {
                return error.CatchAllNotAtEnd;
            }

            if (wildcard.index == 0 or path[wildcard.index - 1] != '/') {
                return error.MissingCatchAllSlash;
            }

            if (n.path.len > 0 and n.path[n.path.len - 1] == '/') {
                return error.RouteConflict;
            }

            n.path = path[0 .. wildcard.index - 1];
            n.wild_child = true;

            const child = try createNode(allocator);
            child.* = .{
                .path = wildcard.token,
                .n_type = .catch_all,
                .priority = 1,
                .handler = handler,
                .route_path = full_path,
                .base_route_path = base_path,
                .route_index = route_index,
                .on_error_handler = on_error_handler,
            };
            try n.children.append(allocator, child);
            return;
        }

        n.path = path;
        n.handler = handler;
        n.route_path = full_path;
        n.base_route_path = base_path;
        n.route_index = route_index;
        n.on_error_handler = on_error_handler;
    }

    fn getValue(self: *const Node, full_path: []const u8, params: []Param) Match {
        var n = self;
        var path = full_path;
        var param_count: usize = 0;

        walk: while (true) {
            const prefix = n.path;

            if (path.len > prefix.len) {
                if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return .{};
                path = path[prefix.len..];

                if (!n.wild_child) {
                    const idxc = path[0];
                    for (n.indices.items, 0..) |candidate, child_index| {
                        if (candidate == idxc) {
                            n = n.children.items[child_index];
                            continue :walk;
                        }
                    }

                    return .{
                        .tsr = std.mem.eql(u8, path, "/") and n.handler != null,
                    };
                }

                n = n.children.items[0];
                switch (n.n_type) {
                    .param => {
                        var end: usize = 0;
                        while (end < path.len and path[end] != '/') : (end += 1) {}

                        if (param_count < params.len) {
                            params[param_count] = .{
                                .key = n.path[1..],
                                .value = path[0..end],
                            };
                        }
                        param_count += 1;

                        if (end < path.len) {
                            if (n.children.items.len > 0) {
                                path = path[end..];
                                n = n.children.items[0];
                                continue :walk;
                            }

                            return .{
                                .tsr = path.len == end + 1,
                            };
                        }

                        return .{
                            .handler = n.handler,
                            .param_count = param_count,
                            .route_path = n.route_path,
                            .base_route_path = n.base_route_path,
                            .route_index = n.route_index,
                            .on_error_handler = n.on_error_handler,
                            .tsr = n.handler == null and n.children.items.len == 1 and
                                std.mem.eql(u8, n.children.items[0].path, "/") and
                                n.children.items[0].handler != null,
                        };
                    },
                    .catch_all => {
                        if (param_count < params.len) {
                            params[param_count] = .{
                                .key = n.path[1..],
                                .value = path,
                            };
                        }
                        param_count += 1;

                        return .{
                            .handler = n.handler,
                            .param_count = param_count,
                            .route_path = n.route_path,
                            .base_route_path = n.base_route_path,
                            .route_index = n.route_index,
                            .on_error_handler = n.on_error_handler,
                        };
                    },
                    else => unreachable,
                }
            }

            if (!std.mem.eql(u8, path, prefix)) {
                return .{
                    .tsr = path.len + 1 == prefix.len and
                        prefix[path.len] == '/' and
                        std.mem.eql(u8, path, prefix[0..path.len]) and
                        n.handler != null,
                };
            }

            if (n.handler == null) {
                if (std.mem.eql(u8, path, "/") and n.wild_child and n.n_type != .root) {
                    return .{ .tsr = true };
                }

                if (std.mem.eql(u8, path, "/") and n.n_type == .static) {
                    return .{ .tsr = true };
                }

                for (n.indices.items, 0..) |candidate, child_index| {
                    if (candidate != '/') continue;
                    const child = n.children.items[child_index];
                    return .{
                        .tsr = (std.mem.eql(u8, child.path, "/") and child.handler != null) or
                            (child.n_type == .catch_all and child.children.items.len > 0 and child.children.items[0].handler != null),
                    };
                }
            }

            return .{
                .handler = n.handler,
                .param_count = param_count,
                .route_path = n.route_path,
                .base_route_path = n.base_route_path,
                .route_index = n.route_index,
                .on_error_handler = n.on_error_handler,
            };
        }
    }

    fn findCaseInsensitivePathRec(
        self: *const Node,
        allocator: std.mem.Allocator,
        path: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        fix_trailing_slash: bool,
    ) std.mem.Allocator.Error!bool {
        if (path.len < self.path.len or !std.ascii.eqlIgnoreCase(path[0..self.path.len], self.path)) {
            return false;
        }

        const saved_len = out.items.len;
        errdefer out.shrinkRetainingCapacity(saved_len);
        try out.appendSlice(allocator, self.path);

        const rest = path[self.path.len..];
        if (rest.len > 0) {
            if (!self.wild_child) {
                for (self.indices.items, 0..) |candidate, child_index| {
                    if (std.ascii.toLower(candidate) != std.ascii.toLower(rest[0])) continue;
                    const child_saved_len = out.items.len;
                    if (try self.children.items[child_index].findCaseInsensitivePathRec(allocator, rest, out, fix_trailing_slash)) {
                        return true;
                    }
                    out.shrinkRetainingCapacity(child_saved_len);
                }

                if (fix_trailing_slash and std.mem.eql(u8, rest, "/") and self.handler != null) return true;
                return false;
            }

            const child = self.children.items[0];
            switch (child.n_type) {
                .param => {
                    var end: usize = 0;
                    while (end < rest.len and rest[end] != '/') : (end += 1) {}
                    if (end == 0) return false;

                    try out.appendSlice(allocator, rest[0..end]);

                    if (end < rest.len) {
                        if (child.children.items.len > 0) {
                            return child.children.items[0].findCaseInsensitivePathRec(allocator, rest[end..], out, fix_trailing_slash);
                        }
                        return fix_trailing_slash and rest.len == end + 1;
                    }

                    if (child.handler != null) return true;

                    if (fix_trailing_slash and child.children.items.len == 1) {
                        const next = child.children.items[0];
                        if (std.mem.eql(u8, next.path, "/") and next.handler != null) {
                            try out.append(allocator, '/');
                            return true;
                        }
                    }

                    return false;
                },
                .catch_all => {
                    try out.appendSlice(allocator, rest);
                    return child.handler != null;
                },
                else => return false,
            }
        }

        if (self.handler != null) return true;
        if (!fix_trailing_slash) return false;

        for (self.indices.items, 0..) |candidate, child_index| {
            if (candidate != '/') continue;
            const child = self.children.items[child_index];
            if ((std.mem.eql(u8, child.path, "/") and child.handler != null) or
                (child.n_type == .catch_all and child.children.items.len > 0 and child.children.items[0].handler != null))
            {
                try out.append(allocator, '/');
                return true;
            }
        }

        return false;
    }

    fn incrementChildPrio(self: *Node, pos: usize) usize {
        self.children.items[pos].priority += 1;
        const priority = self.children.items[pos].priority;

        var new_pos = pos;
        while (new_pos > 0 and self.children.items[new_pos - 1].priority < priority) : (new_pos -= 1) {
            std.mem.swap(*Node, &self.children.items[new_pos - 1], &self.children.items[new_pos]);
            std.mem.swap(u8, &self.indices.items[new_pos - 1], &self.indices.items[new_pos]);
        }

        return new_pos;
    }
};

pub const Router = struct {
    const stack_param_capacity = 8;

    arena: std.heap.ArenaAllocator,
    trees: []MethodTree,
    fallback_routes: []FallbackRoute,
    limits: Limits = .{},

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) InitError!Router {
        return initWithLimits(allocator, routes, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, routes: []const Route, limits: Limits) InitError!Router {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var trees_list: std.ArrayListUnmanaged(MethodTree) = .empty;
        var fallback_routes: std.ArrayListUnmanaged(FallbackRoute) = .empty;

        for (routes, 0..) |route, route_index| {
            try validateCorePath(route.path, limits);
            const route_param_count = countParams(route.path);

            const tree = try getOrCreateTree(&trees_list, arena_allocator, route.method, routeMethodName(route));
            tree.root.addRoute(arena_allocator, route.path, route.base_path, route.handler, route_index, route.on_error_handler) catch |err| switch (err) {
                error.RouteConflict => {
                    try appendFallbackRoute(&fallback_routes, arena_allocator, route, route_index);
                    continue;
                },
                else => return err,
            };
            if (route_param_count == 0) {
                try tree.exact_routes.put(arena_allocator, route.path, .{
                    .handler = route.handler,
                    .route_path = route.path,
                    .base_route_path = route.base_path,
                    .route_index = route_index,
                    .on_error_handler = route.on_error_handler,
                });
            }
            tree.max_params = @max(tree.max_params, route_param_count);
        }

        return .{
            .arena = arena,
            .trees = try trees_list.toOwnedSlice(arena_allocator),
            .fallback_routes = try fallback_routes.toOwnedSlice(arena_allocator),
            .limits = limits,
        };
    }

    pub fn deinit(self: *Router) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *const Router, req: Request) LookupResult {
        var no_scratch: [0]Param = .{};
        return self.lookupWithScratch(req, &no_scratch);
    }

    pub fn lookupWithScratch(self: *const Router, req: Request, scratch_params: []Param) LookupResult {
        if (req.path.len > self.limits.max_path_bytes) return .{ .reject = .path_too_long };

        const method_name = req.methodName();
        var simple_result: LookupResult = .{};
        if (self.findTree(method_name)) |tree| {
            if (tree.exact_routes.get(req.path)) |exact| {
                return .{
                    .handler = exact.handler,
                    .params = &.{},
                    .params_storage = null,
                    .route_path = exact.route_path,
                    .base_route_path = exact.base_route_path,
                    .route_index = exact.route_index,
                    .on_error_handler = exact.on_error_handler,
                    .tsr = false,
                };
            }

            if (tooManyPathSegments(req.path, self.limits)) return .{ .reject = .too_many_segments };

            if (tree.max_params == 0) {
                const match_without_params = tree.root.getValue(req.path, &.{});
                simple_result = .{
                    .handler = match_without_params.handler,
                    .params = &.{},
                    .params_storage = null,
                    .route_path = match_without_params.route_path,
                    .base_route_path = match_without_params.base_route_path,
                    .route_index = match_without_params.route_index,
                    .on_error_handler = match_without_params.on_error_handler,
                    .tsr = match_without_params.tsr,
                };
            } else {
                var params_storage: ?[]Param = null;
                const params = if (tree.max_params <= scratch_params.len)
                    scratch_params[0..tree.max_params]
                else blk: {
                    const allocated = req.allocator.alloc(Param, tree.max_params) catch return .{};
                    params_storage = allocated;
                    break :blk allocated;
                };

                const match = tree.root.getValue(req.path, params);
                if (match.handler == null) {
                    if (params_storage) |storage| req.allocator.free(storage);
                    simple_result = .{ .tsr = match.tsr };
                } else {
                    if (!paramsWithinLimits(params[0..match.param_count], self.limits)) {
                        if (params_storage) |storage| req.allocator.free(storage);
                        return .{ .reject = .param_value_too_long };
                    }
                    simple_result = .{
                        .handler = match.handler,
                        .params = params[0..match.param_count],
                        .params_storage = params_storage,
                        .route_path = match.route_path,
                        .base_route_path = match.base_route_path,
                        .route_index = match.route_index,
                        .on_error_handler = match.on_error_handler,
                        .tsr = match.tsr,
                    };
                }
            }
        } else if (tooManyPathSegments(req.path, self.limits)) {
            return .{ .reject = .too_many_segments };
        }

        const before_index = simple_result.route_index orelse std.math.maxInt(usize);
        if (self.lookupFallbackRoute(method_name, req.path, req.allocator, scratch_params, before_index)) |fallback_result| {
            if (simple_result.params_storage) |storage| req.allocator.free(storage);
            return fallback_result;
        }

        return simple_result;
    }

    pub fn dispatch(self: *const Router, req: Request) Response {
        var scratch_params: [stack_param_capacity]Param = undefined;
        const result = self.lookupWithScratch(req, &scratch_params);
        const handler = result.handler orelse return response_mod.notFound();
        defer if (result.params_storage) |storage| req.allocator.free(storage);
        var routed_req = req;
        routed_req.params = result.params;
        routed_req.route_path = result.route_path;
        routed_req.base_route_path = result.base_route_path;
        return handler(routed_req);
    }

    pub fn allowed(
        self: *const Router,
        allocator: std.mem.Allocator,
        path: []const u8,
        req_method: std.http.Method,
        include_options: bool,
    ) !?[]const u8 {
        return self.allowedForMethodName(allocator, path, @tagName(req_method), include_options);
    }

    pub fn allowedForMethodName(
        self: *const Router,
        allocator: std.mem.Allocator,
        path: []const u8,
        req_method_name: []const u8,
        include_options: bool,
    ) !?[]const u8 {
        var methods: std.ArrayListUnmanaged([]const u8) = .empty;
        defer methods.deinit(allocator);

        if (std.mem.eql(u8, path, "*")) {
            for (self.trees) |tree| {
                if (http_method.isOptions(tree.method_name)) continue;
                try appendAllowedMethod(allocator, &methods, tree.method_name);
                if (http_method.isGet(tree.method_name)) {
                    try appendAllowedMethod(allocator, &methods, "HEAD");
                }
            }
            for (self.fallback_routes) |fallback_route| {
                if (http_method.isOptions(fallback_route.method_name)) continue;
                try appendAllowedMethod(allocator, &methods, fallback_route.method_name);
                if (http_method.isGet(fallback_route.method_name)) {
                    try appendAllowedMethod(allocator, &methods, "HEAD");
                }
            }
        } else {
            for (self.trees) |*tree| {
                if (http_method.eqlIgnoreCase(tree.method_name, req_method_name) or http_method.isOptions(tree.method_name)) continue;
                if (treeMatchesPath(tree, path)) {
                    try appendAllowedMethod(allocator, &methods, tree.method_name);
                    if (http_method.isGet(tree.method_name)) {
                        try appendAllowedMethod(allocator, &methods, "HEAD");
                    }
                }
            }
            var scratch_params: [stack_param_capacity]Param = undefined;
            for (self.fallback_routes) |fallback_route| {
                if (http_method.eqlIgnoreCase(fallback_route.method_name, req_method_name) or http_method.isOptions(fallback_route.method_name)) continue;
                if (matchFallbackPath(fallback_route.path, path, &scratch_params) != null) {
                    try appendAllowedMethod(allocator, &methods, fallback_route.method_name);
                    if (http_method.isGet(fallback_route.method_name)) {
                        try appendAllowedMethod(allocator, &methods, "HEAD");
                    }
                }
            }
        }

        if (methods.items.len == 0) return null;
        if (include_options) try appendAllowedMethod(allocator, &methods, "OPTIONS");

        sortMethods(methods.items);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (methods.items, 0..) |method, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, method);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn findCaseInsensitivePath(
        self: *const Router,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        fix_trailing_slash: bool,
    ) !?[]const u8 {
        return try self.findCaseInsensitivePathForMethodName(allocator, @tagName(method), path, fix_trailing_slash);
    }

    pub fn findCaseInsensitivePathForMethodName(
        self: *const Router,
        allocator: std.mem.Allocator,
        method_name: []const u8,
        path: []const u8,
        fix_trailing_slash: bool,
    ) !?[]const u8 {
        if (self.findTree(method_name)) |tree| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);

            if (try tree.root.findCaseInsensitivePathRec(allocator, path, &out, fix_trailing_slash)) {
                return try out.toOwnedSlice(allocator);
            }
        }

        return null;
    }

    fn lookupFallbackRoute(
        self: *const Router,
        method_name: []const u8,
        path_value: []const u8,
        allocator: std.mem.Allocator,
        scratch_params: []Param,
        before_route_index: usize,
    ) ?LookupResult {
        for (self.fallback_routes) |fallback_route| {
            if (fallback_route.route_index >= before_route_index) continue;
            if (!http_method.eqlIgnoreCase(fallback_route.method_name, method_name)) continue;

            var params_storage: ?[]Param = null;
            const params = if (fallback_route.max_params <= scratch_params.len)
                scratch_params[0..fallback_route.max_params]
            else blk: {
                const allocated = allocator.alloc(Param, fallback_route.max_params) catch return null;
                params_storage = allocated;
                break :blk allocated;
            };

            const param_count = matchFallbackPath(fallback_route.path, path_value, params) orelse {
                if (params_storage) |storage| allocator.free(storage);
                continue;
            };

            if (!paramsWithinLimits(params[0..param_count], self.limits)) {
                if (params_storage) |storage| allocator.free(storage);
                return .{ .reject = .param_value_too_long };
            }

            return .{
                .handler = fallback_route.handler,
                .params = params[0..param_count],
                .params_storage = params_storage,
                .route_path = fallback_route.path,
                .base_route_path = fallback_route.base_path,
                .route_index = fallback_route.route_index,
                .on_error_handler = fallback_route.on_error_handler,
            };
        }

        return null;
    }

    fn findTree(self: *const Router, method_name: []const u8) ?*const MethodTree {
        for (self.trees) |*tree| {
            if (http_method.eqlIgnoreCase(tree.method_name, method_name)) return tree;
        }
        return null;
    }
};

fn createNode(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Node {
    const node = try allocator.create(Node);
    node.* = .{};
    return node;
}

fn getOrCreateTree(
    trees: *std.ArrayListUnmanaged(MethodTree),
    allocator: std.mem.Allocator,
    method: std.http.Method,
    method_name: []const u8,
) std.mem.Allocator.Error!*MethodTree {
    for (trees.items) |*tree| {
        if (http_method.eqlIgnoreCase(tree.method_name, method_name)) return tree;
    }

    const root = try createNode(allocator);
    root.n_type = .root;

    try trees.append(allocator, .{
        .method = method,
        .method_name = method_name,
        .root = root,
    });
    return &trees.items[trees.items.len - 1];
}

fn longestCommonPrefix(a: []const u8, b: []const u8) usize {
    const max = @min(a.len, b.len);
    var index: usize = 0;
    while (index < max and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn findWildcard(path: []const u8) Wildcard {
    for (path, 0..) |c, start| {
        if (c != ':' and c != '*') continue;

        var valid = true;
        var end = start + 1;
        while (end < path.len and path[end] != '/') : (end += 1) {
            if (path[end] == ':' or path[end] == '*') valid = false;
        }

        return .{
            .token = path[start..end],
            .index = start,
            .found = true,
            .valid = valid,
        };
    }

    return .{};
}

fn countParams(path: []const u8) usize {
    var count: usize = 0;
    for (path) |c| {
        if (c == ':' or c == '*') count += 1;
    }
    return count;
}

fn validateCorePath(path: []const u8, limits: Limits) InitError!void {
    if (std.mem.indexOfScalar(u8, path, '?') != null or
        std.mem.indexOfScalar(u8, path, '{') != null or
        std.mem.indexOfScalar(u8, path, '}') != null)
    {
        return error.InvalidPattern;
    }
    if (path.len > limits.max_path_bytes) return error.PathTooLong;
    if (path_mod.exceedsSegmentLimit(path, limits.max_segments)) return error.TooManySegments;
    if (countParams(path) > limits.max_params) return error.TooManyParams;

    var segment_iter = std.mem.splitScalar(u8, path, '/');
    while (segment_iter.next()) |segment| {
        if (segment.len == 0) continue;
        const marker = segment[0];
        if (marker == ':' or marker == '*') {
            if (segment.len == 1) return if (marker == '*') error.InvalidWildcard else error.ParamNameTooLong;
            if (segment.len - 1 > limits.max_param_name_bytes) return error.ParamNameTooLong;
        }
    }
}

fn tooManyPathSegments(path: []const u8, limits: Limits) bool {
    return path_mod.exceedsSegmentLimit(path, limits.max_segments);
}

fn paramsWithinLimits(params: []const Param, limits: Limits) bool {
    for (params) |param| {
        if (param.value.len > limits.max_param_value_bytes) return false;
    }
    return true;
}

fn appendFallbackRoute(
    fallback_routes: *std.ArrayListUnmanaged(FallbackRoute),
    allocator: std.mem.Allocator,
    route: Route,
    route_index: usize,
) std.mem.Allocator.Error!void {
    try fallback_routes.append(allocator, .{
        .method = route.method,
        .method_name = routeMethodName(route),
        .path = route.path,
        .handler = route.handler,
        .base_path = route.base_path,
        .route_index = route_index,
        .on_error_handler = route.on_error_handler,
        .max_params = countParams(route.path),
    });
}

fn treeMatchesPath(tree: *const MethodTree, path: []const u8) bool {
    if (tree.exact_routes.contains(path)) return true;
    return tree.root.getValue(path, &.{}).handler != null;
}

fn matchFallbackPath(pattern: []const u8, path_value: []const u8, params: []Param) ?usize {
    var pattern_index: usize = if (pattern.len > 0 and pattern[0] == '/') 1 else 0;
    var path_index: usize = if (path_value.len > 0 and path_value[0] == '/') 1 else 0;
    var param_count: usize = 0;

    while (true) {
        const pattern_done = pattern_index >= pattern.len;
        const path_done = path_index >= path_value.len;
        if (pattern_done or path_done) {
            return if (pattern_done and path_done) param_count else null;
        }

        const pattern_start = pattern_index;
        while (pattern_index < pattern.len and pattern[pattern_index] != '/') : (pattern_index += 1) {}
        const pattern_segment = pattern[pattern_start..pattern_index];
        if (pattern_index < pattern.len) pattern_index += 1;

        if (pattern_segment.len > 0 and pattern_segment[0] == '*') {
            if (pattern_index < pattern.len) return null;
            if (pattern_segment.len == 1) return null;
            if (param_count < params.len) {
                const value_start = if (path_startHasSlash(path_value, path_index)) path_index - 1 else path_index;
                params[param_count] = .{
                    .key = pattern_segment[1..],
                    .value = path_value[value_start..],
                };
            }
            return param_count + 1;
        }

        const path_start = path_index;
        while (path_index < path_value.len and path_value[path_index] != '/') : (path_index += 1) {}
        const path_segment = path_value[path_start..path_index];
        if (path_index < path_value.len) path_index += 1;

        if (pattern_segment.len > 0 and pattern_segment[0] == ':') {
            if (pattern_segment.len == 1 or path_segment.len == 0) return null;
            if (param_count < params.len) {
                params[param_count] = .{
                    .key = pattern_segment[1..],
                    .value = path_segment,
                };
            }
            param_count += 1;
            continue;
        }

        if (!std.mem.eql(u8, pattern_segment, path_segment)) return null;
    }
}

fn path_startHasSlash(path_value: []const u8, index: usize) bool {
    return index > 0 and index <= path_value.len and path_value[index - 1] == '/';
}

fn appendAllowedMethod(
    allocator: std.mem.Allocator,
    methods: *std.ArrayListUnmanaged([]const u8),
    method: []const u8,
) !void {
    for (methods.items) |existing| {
        if (http_method.eqlIgnoreCase(existing, method)) return;
    }
    try methods.append(allocator, method);
}

fn sortMethods(methods: [][]const u8) void {
    if (methods.len < 2) return;
    var i: usize = 1;
    while (i < methods.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, methods[j], methods[j - 1])) : (j -= 1) {
            std.mem.swap([]const u8, &methods[j], &methods[j - 1]);
        }
    }
}

fn routeMethodName(route: Route) []const u8 {
    return if (route.method_name.len > 0) route.method_name else @tagName(route.method);
}

fn ok(_: Request) Response {
    return response_mod.text(.ok, "ok");
}

test "router exact route dispatches directly" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/health", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const res = router.dispatch(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "router dispatches by method" {
    const get_handler = struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "get");
        }
    }.run;
    const post_handler = struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "post");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/users", .handler = get_handler },
        .{ .method = .POST, .path = "/users", .handler = post_handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const get_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/users"));
    try std.testing.expectEqualStrings("get", get_res.bodyBytes());

    const post_res = router.dispatch(Request.init(std.testing.allocator, .POST, "/users"));
    try std.testing.expectEqualStrings("post", post_res.bodyBytes());
}

test "router indexes exact routes for the static fast path" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/health", .handler = ok },
        .{ .method = .GET, .path = "/users/:id", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const tree = router.findTree("GET").?;
    try std.testing.expect(tree.exact_routes.contains("/health"));
    try std.testing.expect(!tree.exact_routes.contains("/users/:id"));

    const lookup = router.lookup(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expect(lookup.handler != null);
    try std.testing.expectEqual(@as(?usize, 0), lookup.route_index);
}

test "router dynamic route injects params" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/users/:id", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = Request.init(arena.allocator(), .GET, "/users/42");
    const res = router.dispatch(req);
    try std.testing.expectEqualStrings("42", res.bodyBytes());
}

test "router catch all matches the tail" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("filepath") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/src/*filepath", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const req = Request.init(std.testing.allocator, .GET, "/src/subdir/file.zig");
    const res = router.dispatch(req);
    try std.testing.expectEqualStrings("/subdir/file.zig", res.bodyBytes());
}

test "router supports static and param routes on the same segment" {
    const static_handler = struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "static");
        }
    }.run;
    const param_handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("user") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/user/new", .handler = static_handler },
        .{ .method = .GET, .path = "/user/:user", .handler = param_handler },
    };

    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const static_res = router.dispatch(Request.init(arena.allocator(), .GET, "/user/new"));
    try std.testing.expectEqualStrings("static", static_res.bodyBytes());

    const param_res = router.dispatch(Request.init(arena.allocator(), .GET, "/user/42"));
    try std.testing.expectEqualStrings("42", param_res.bodyBytes());
}

test "router rejects catch all that is not at the end" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/src/*filepath/edit", .handler = ok },
    };

    try std.testing.expectError(error.CatchAllNotAtEnd, Router.init(std.testing.allocator, &routes));
}

test "router allowed returns methods plus OPTIONS" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/users", .handler = ok },
        .{ .method = .POST, .path = "/users", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const allow = (try router.allowed(std.testing.allocator, "/users", .DELETE, true)).?;
    defer std.testing.allocator.free(allow);

    try std.testing.expectEqualStrings("GET, HEAD, OPTIONS, POST", allow);
}

test "router finds case-insensitive canonical path" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/Users/:id", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const fixed = (try router.findCaseInsensitivePath(std.testing.allocator, .GET, "/users/42", true)).?;
    defer std.testing.allocator.free(fixed);

    try std.testing.expectEqualStrings("/Users/42", fixed);
}

test "router rejects optional regex and middle wildcard patterns" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/Users/:id{[0-9]+}", .handler = ok },
    };
    try std.testing.expectError(error.InvalidPattern, Router.init(std.testing.allocator, &routes));

    const optional_routes = [_]Route{
        .{ .method = .GET, .path = "/posts/:id?", .handler = ok },
    };
    try std.testing.expectError(error.InvalidPattern, Router.init(std.testing.allocator, &optional_routes));

    const middle_wildcard_routes = [_]Route{
        .{ .method = .GET, .path = "/docs/*/edit", .handler = ok },
    };
    try std.testing.expectError(error.InvalidWildcard, Router.init(std.testing.allocator, &middle_wildcard_routes));
}

test "router applies hard limits at registration and lookup" {
    const long_path_routes = [_]Route{
        .{ .method = .GET, .path = "/abcd", .handler = ok },
    };
    try std.testing.expectError(error.PathTooLong, Router.initWithLimits(std.testing.allocator, &long_path_routes, .{
        .max_path_bytes = 4,
    }));

    const many_params_routes = [_]Route{
        .{ .method = .GET, .path = "/:a/:b", .handler = ok },
    };
    try std.testing.expectError(error.TooManyParams, Router.initWithLimits(std.testing.allocator, &many_params_routes, .{
        .max_params = 1,
    }));

    const routes = [_]Route{
        .{ .method = .GET, .path = "/users/:id", .handler = ok },
    };
    var router = try Router.initWithLimits(std.testing.allocator, &routes, .{
        .max_param_value_bytes = 2,
    });
    defer router.deinit();

    const req = Request.init(std.testing.allocator, .GET, "/users/123");
    const lookup = router.lookup(req);
    try std.testing.expectEqual(LookupReject.param_value_too_long, lookup.reject.?);
}

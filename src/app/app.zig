const std = @import("std");
const Atomic = std.atomic.Value;
const request_mod = @import("../request/request.zig");
const Request = request_mod.Request;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const path_mod = @import("../core/path.zig");
const core_meta = @import("../core/meta.zig");
const http_names = @import("../core/http_names.zig");
const http_method = @import("../core/http_method.zig");
const request_target = @import("../core/request_target.zig");
const router_mod = @import("../router/router.zig");
const context_mod = @import("../core/context.zig");
const app_error_mod = @import("../core/app_error.zig");
const websocket_mod = @import("../websocket/websocket.zig");
const middleware_index_mod = @import("middleware_index.zig");
const Context = context_mod.Context;
const HTTPException = @import("../core/http_exception.zig").HTTPException;
const Route = router_mod.Route;
const Router = router_mod.Router;
const Handler = router_mod.Handler;
const MiddlewareIndex = middleware_index_mod.MiddlewareIndex;
const RouteMiddlewareIndex = middleware_index_mod.RouteMiddlewareIndex;
pub const ErrorHandler = router_mod.ErrorHandler;
pub const ContextHandler = *const fn (c: *Context) Response;
pub const ContextMiddlewareHandler = *const fn (c: *Context, next: Context.Next) Response;
pub const GetPathFn = *const fn (req: *const Request) []const u8;

pub const App = struct {
    const Self = @This();
    const FinalizeState = enum(u8) {
        open,
        finalizing,
        finalized,
    };
    const MountTarget = union(enum) {
        app: *Self,
        handler: Handler,
    };

    const Mount = struct {
        prefix: []const u8,
        target: MountTarget,
    };

    const MiddlewareEntry = struct {
        prefix: []const u8,
        method_name: ?[]const u8 = null,
        method_name_owned: bool = false,
        handler: DispatchMiddleware,
        on_error_handler: ?ErrorHandler = null,
    };

    const DispatchNext = struct {
        ctx: *const anyopaque,
        run_fn: *const fn (ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: DispatchNext, req: Request) Response {
            return self.run_fn(self.ctx, req);
        }
    };

    const DispatchMiddleware = *const fn (req: Request, next: DispatchNext) Response;

    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        method_name: ?[]const u8 = null,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
        cookies_raw: ?[]const u8 = null,
        raw_ctx: ?*const anyopaque = null,
        env_ctx: ?*anyopaque = null,
        conn_info: request_mod.ConnInfo = .{},
    };

    pub const Options = struct {
        strict: bool = true,
        redirect_fixed_path: bool = true,
        handle_method_not_allowed: bool = true,
        handle_options: bool = true,
        get_path: ?GetPathFn = null,
        router_limits: router_mod.Limits = .{},
    };

    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    mounts: std.ArrayListUnmanaged(Mount) = .empty,
    middlewares: std.ArrayListUnmanaged(MiddlewareEntry) = .empty,
    middleware_index: MiddlewareIndex = .{},
    route_middleware_index: RouteMiddlewareIndex = .{},
    router: ?Router = null,
    finalize_state: Atomic(u8) = .init(@intFromEnum(FinalizeState.open)),
    finalize_mutex: std.atomic.Mutex = .unlocked,
    finalized: bool = false,
    strict: bool = true,
    base_path: []const u8 = "",
    base_path_owned: ?[]const u8 = null,
    redirect_trailing_slash: bool = true,
    redirect_fixed_path: bool = true,
    handle_method_not_allowed: bool = true,
    handle_options: bool = true,
    get_path: ?GetPathFn = null,
    router_limits: router_mod.Limits = .{},
    errors: app_error_mod.Registry,
    not_found_handler: ?Handler = null,
    on_error_handler: ?ErrorHandler = null,
    has_context_handlers: bool = false,
    has_context_middlewares: bool = false,
    has_context_not_found: bool = false,
    has_error_handlers: bool = false,
    has_error_middlewares: bool = false,

    pub fn init(allocator: std.mem.Allocator) App {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, app_options: Options) App {
        return .{
            .allocator = allocator,
            .strict = app_options.strict,
            .redirect_trailing_slash = app_options.strict,
            .redirect_fixed_path = app_options.redirect_fixed_path,
            .handle_method_not_allowed = app_options.handle_method_not_allowed,
            .handle_options = app_options.handle_options,
            .get_path = app_options.get_path,
            .router_limits = app_options.router_limits,
            .errors = app_error_mod.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.router) |*router| router.deinit();
        self.middleware_index.deinit(self.allocator);
        self.route_middleware_index.deinit(self.allocator);
        self.clearBasePath();
        for (self.routes.items) |registered_route| {
            self.allocator.free(registered_route.path);
            if (registered_route.method_name_owned) self.allocator.free(registered_route.method_name);
            if (registered_route.base_path_owned) {
                if (registered_route.base_path) |base_path| self.allocator.free(base_path);
            }
        }
        self.routes.deinit(self.allocator);
        for (self.mounts.items) |mount_entry| {
            self.allocator.free(mount_entry.prefix);
        }
        self.mounts.deinit(self.allocator);
        for (self.middlewares.items) |middleware_entry| {
            self.allocator.free(middleware_entry.prefix);
            if (middleware_entry.method_name_owned) {
                if (middleware_entry.method_name) |method_name| self.allocator.free(method_name);
            }
        }
        self.middlewares.deinit(self.allocator);
        self.errors.deinit();
        self.* = undefined;
    }

    pub fn get(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.GET, path, handler);
    }

    pub fn head(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.HEAD, path, handler);
    }

    pub fn options(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.OPTIONS, path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.POST, path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.PUT, path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.PATCH, path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.DELETE, path, handler);
    }

    pub fn connect(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.CONNECT, path, handler);
    }

    pub fn trace(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRouteOrMethodMiddleware(.TRACE, path, handler);
    }

    pub fn all(self: *App, path: []const u8, handler: anytype) !void {
        const methods = [_]std.http.Method{
            .GET,
            .HEAD,
            .POST,
            .PUT,
            .PATCH,
            .DELETE,
            .OPTIONS,
            .CONNECT,
            .TRACE,
        };

        for (methods) |method| {
            try self.addRouteOrMethodMiddleware(method, path, handler);
        }
    }

    pub fn ws(self: *App, path: []const u8, comptime handler: anytype) !void {
        try self.wsWithOptions(path, handler, .{});
    }

    pub fn wsWithOptions(
        self: *App,
        path: []const u8,
        comptime handler: anytype,
        comptime websocket_options: websocket_mod.WebSocketUpgradeOptions,
    ) !void {
        try self.ensureOpenForMutation();

        const joined_path = try joinPrefixedPath(self.allocator, self.base_path, path);
        const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
        errdefer self.allocator.free(full_path);
        const route_base_path = try ownedRouteBasePath(self.allocator, self.base_path);
        errdefer if (route_base_path) |base_path| self.allocator.free(base_path);

        try self.routes.append(self.allocator, .{
            .method = .GET,
            .method_name = "GET",
            .path = full_path,
            .handler = websocketRouteHandler(handler, websocket_options),
            .base_path = route_base_path,
            .base_path_owned = route_base_path != null,
            .on_error_handler = null,
        });
    }

    pub fn on(self: *App, methods: anytype, paths: anytype, handler: anytype) !void {
        try self.registerOn(methods, paths, handler);
    }

    pub fn useOn(self: *App, methods: anytype, paths: anytype, middleware_or_tuple: anytype) !void {
        try self.registerOnMiddleware(methods, paths, middleware_or_tuple);
    }

    pub fn use(self: *App, middleware_or_tuple: anytype) !void {
        try self.addMiddlewareInput("/", middleware_or_tuple);
    }

    pub fn useAt(self: *App, path: []const u8, middleware_or_tuple: anytype) !void {
        try self.addMiddlewareInput(path, middleware_or_tuple);
    }

    pub fn basePath(self: *App, path: []const u8) !void {
        try self.ensureOpenForMutation();

        const normalized = try normalizePrefix(self.allocator, path);
        errdefer self.allocator.free(normalized);

        if (self.base_path_owned) |existing| {
            self.allocator.free(existing);
        }

        if (std.mem.eql(u8, normalized, "/")) {
            self.allocator.free(normalized);
            self.base_path = "";
            self.base_path_owned = null;
            return;
        }

        self.base_path = normalized;
        self.base_path_owned = normalized;
    }

    pub fn route(self: *App, prefix: []const u8, other: *const App) !void {
        try self.ensureOpenForMutation();
        try self.errors.register(other.errors.defs.items);
        try self.errors.detail_providers.appendSlice(self.allocator, other.errors.detail_providers.items);

        const combined_prefix = try joinPrefixedPath(self.allocator, self.base_path, prefix);
        defer self.allocator.free(combined_prefix);

        const mounted_prefix = try normalizePrefix(self.allocator, combined_prefix);
        defer self.allocator.free(mounted_prefix);

        for (other.routes.items) |nested| {
            const joined_path = try joinPrefixedPath(self.allocator, mounted_prefix, nested.path);
            const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
            errdefer self.allocator.free(full_path);
            const method_name = if (nested.method_name_owned)
                try self.allocator.dupe(u8, nested.method_name)
            else
                nested.method_name;
            errdefer if (nested.method_name_owned) self.allocator.free(method_name);

            const base_path = try joinedBasePath(self.allocator, mounted_prefix, nested.base_path);
            errdefer if (base_path) |owned_base_path| self.allocator.free(owned_base_path);

            try self.routes.append(self.allocator, .{
                .method = nested.method,
                .method_name = method_name,
                .method_name_owned = nested.method_name_owned,
                .path = full_path,
                .handler = nested.handler,
                .base_path = base_path,
                .base_path_owned = base_path != null,
                .on_error_handler = nested.on_error_handler orelse other.on_error_handler,
            });
        }

        for (other.middlewares.items) |nested| {
            const nested_path = if (nested.prefix.len == 0) "/" else nested.prefix;
            const full_prefix = try scopedMiddlewarePrefix(self.allocator, mounted_prefix, nested_path);
            errdefer self.allocator.free(full_prefix);
            const method_name = if (nested.method_name_owned and nested.method_name != null)
                try self.allocator.dupe(u8, nested.method_name.?)
            else
                nested.method_name;
            errdefer if (nested.method_name_owned) {
                if (method_name) |owned_method_name| self.allocator.free(owned_method_name);
            };

            try self.middlewares.append(self.allocator, .{
                .prefix = full_prefix,
                .method_name = method_name,
                .method_name_owned = nested.method_name_owned,
                .handler = nested.handler,
                .on_error_handler = nested.on_error_handler orelse other.on_error_handler,
            });
        }

        self.has_context_handlers = self.has_context_handlers or other.has_context_handlers;
        self.has_context_middlewares = self.has_context_middlewares or other.has_context_middlewares;
        self.has_error_handlers = self.has_error_handlers or other.has_error_handlers;
        self.has_error_middlewares = self.has_error_middlewares or other.has_error_middlewares;
    }

    pub fn mount(self: *App, prefix: []const u8, target: anytype) !void {
        try self.ensureOpenForMutation();

        const combined_prefix = try joinPrefixedPath(self.allocator, self.base_path, prefix);
        defer self.allocator.free(combined_prefix);

        const mounted_prefix = try normalizePrefix(self.allocator, combined_prefix);
        errdefer self.allocator.free(mounted_prefix);

        const resolved = resolveMountTarget(target);
        try self.mounts.append(self.allocator, .{
            .prefix = mounted_prefix,
            .target = resolved.target,
        });
        self.has_context_handlers = self.has_context_handlers or resolved.uses_context;
        self.has_error_handlers = self.has_error_handlers or resolved.uses_error;
    }

    pub fn notFound(self: *App, handler: anytype) !void {
        try self.ensureOpenForMutation();
        const resolved = resolveHandler(handler);
        self.not_found_handler = resolved.handler;
        self.has_context_not_found = resolved.uses_context;
    }

    pub fn onError(self: *App, handler: anytype) !void {
        try self.ensureOpenForMutation();
        const resolved = resolveErrorHandler(handler);
        self.on_error_handler = resolved.handler;
        self.has_error_handlers = true;
    }

    pub fn addRoute(self: *App, method: std.http.Method, path: []const u8, handler: anytype) !void {
        try self.ensureOpenForMutation();
        const resolved = resolveHandler(handler);
        const joined_path = try joinPrefixedPath(self.allocator, self.base_path, path);
        const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
        errdefer self.allocator.free(full_path);
        const route_base_path = try ownedRouteBasePath(self.allocator, self.base_path);
        errdefer if (route_base_path) |base_path| self.allocator.free(base_path);

        try self.routes.append(self.allocator, .{
            .method = method,
            .method_name = @tagName(method),
            .path = full_path,
            .handler = resolved.handler,
            .base_path = route_base_path,
            .base_path_owned = route_base_path != null,
            .on_error_handler = null,
        });
        self.has_context_handlers = self.has_context_handlers or resolved.uses_context;
        self.has_error_handlers = self.has_error_handlers or resolved.uses_error;
    }

    pub fn addCustomRoute(self: *App, method_name: []const u8, path: []const u8, handler: anytype) !void {
        try self.ensureOpenForMutation();
        const resolved = resolveHandler(handler);
        const joined_path = try joinPrefixedPath(self.allocator, self.base_path, path);
        const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
        errdefer self.allocator.free(full_path);
        const route_base_path = try ownedRouteBasePath(self.allocator, self.base_path);
        errdefer if (route_base_path) |base_path| self.allocator.free(base_path);

        const owned_method_name = try self.allocator.dupe(u8, method_name);
        errdefer self.allocator.free(owned_method_name);

        try self.routes.append(self.allocator, .{
            .method = request_mod.methodFromName(method_name) orelse .GET,
            .method_name = owned_method_name,
            .method_name_owned = true,
            .path = full_path,
            .handler = resolved.handler,
            .base_path = route_base_path,
            .base_path_owned = route_base_path != null,
            .on_error_handler = null,
        });
        self.has_context_handlers = self.has_context_handlers or resolved.uses_context;
        self.has_error_handlers = self.has_error_handlers or resolved.uses_error;
    }

    pub fn addMiddleware(self: *App, path: []const u8, middleware: anytype) !void {
        try self.ensureOpenForMutation();

        const scoped_prefix = try scopedMiddlewarePrefix(self.allocator, self.base_path, path);
        errdefer self.allocator.free(scoped_prefix);

        const resolved = resolveMiddlewareHandler(middleware);

        try self.middlewares.append(self.allocator, .{
            .prefix = scoped_prefix,
            .handler = resolved.handler,
            .on_error_handler = null,
        });
        self.has_context_middlewares = self.has_context_middlewares or resolved.uses_context;
        self.has_error_middlewares = self.has_error_middlewares or resolved.uses_error;
    }

    pub fn addMethodMiddleware(self: *App, method: std.http.Method, path: []const u8, middleware: anytype) !void {
        try self.appendMethodMiddleware(@tagName(method), false, path, middleware);
    }

    pub fn addCustomMethodMiddleware(self: *App, method_name: []const u8, path: []const u8, middleware: anytype) !void {
        try self.appendMethodMiddleware(method_name, true, path, middleware);
    }

    fn appendMethodMiddleware(self: *App, method_name: []const u8, comptime own_method_name: bool, path: []const u8, middleware: anytype) !void {
        try self.ensureOpenForMutation();

        const scoped_prefix = try scopedMiddlewarePrefix(self.allocator, self.base_path, path);
        errdefer self.allocator.free(scoped_prefix);

        const owned_method_name = if (own_method_name) try self.allocator.dupe(u8, method_name) else method_name;
        errdefer if (own_method_name) self.allocator.free(owned_method_name);

        const resolved = resolveMiddlewareHandler(middleware);

        try self.middlewares.append(self.allocator, .{
            .prefix = scoped_prefix,
            .method_name = owned_method_name,
            .method_name_owned = own_method_name,
            .handler = resolved.handler,
            .on_error_handler = null,
        });
        self.has_context_middlewares = self.has_context_middlewares or resolved.uses_context;
        self.has_error_middlewares = self.has_error_middlewares or resolved.uses_error;
    }

    fn addRouteOrMethodMiddleware(self: *App, method: std.http.Method, path: []const u8, handler_or_middleware: anytype) !void {
        if (comptime isMiddlewareOnly(handler_or_middleware)) {
            try self.addMethodMiddlewareInput(@tagName(method), false, path, handler_or_middleware);
            return;
        }
        try self.addRoute(method, path, handler_or_middleware);
    }

    fn addCustomRouteOrMethodMiddleware(self: *App, method_name: []const u8, path: []const u8, handler_or_middleware: anytype) !void {
        if (comptime isMiddlewareOnly(handler_or_middleware)) {
            try self.addMethodMiddlewareInput(method_name, true, path, handler_or_middleware);
            return;
        }
        try self.addCustomRoute(method_name, path, handler_or_middleware);
    }

    fn addMiddlewareInput(self: *App, default_path: []const u8, middleware_or_tuple: anytype) !void {
        const InputType = @TypeOf(middleware_or_tuple);
        switch (@typeInfo(InputType)) {
            .@"struct" => |struct_info| {
                if (struct_info.is_tuple) {
                    const fields = std.meta.fields(InputType);
                    if (fields.len == 0) {
                        @compileError("App.use tuple must contain middleware, or .{ path, middleware... }.");
                    }

                    const first = @field(middleware_or_tuple, fields[0].name);
                    if (comptime isStringLike(@TypeOf(first))) {
                        if (fields.len == 1) {
                            @compileError("App.use(.{ path, ... }) must include at least one middleware.");
                        }
                        inline for (fields[1..]) |field| {
                            try self.addMiddleware(first, @field(middleware_or_tuple, field.name));
                        }
                        return;
                    }

                    inline for (fields) |field| {
                        try self.addMiddleware(default_path, @field(middleware_or_tuple, field.name));
                    }
                    return;
                }
            },
            else => {},
        }

        try self.addMiddleware(default_path, middleware_or_tuple);
    }

    fn addMethodMiddlewareInput(
        self: *App,
        method_name: []const u8,
        comptime own_method_name: bool,
        path: []const u8,
        middleware_or_tuple: anytype,
    ) !void {
        const InputType = @TypeOf(middleware_or_tuple);
        switch (@typeInfo(InputType)) {
            .@"struct" => |struct_info| {
                if (struct_info.is_tuple) {
                    const fields = std.meta.fields(InputType);
                    if (fields.len == 0) {
                        @compileError("Method middleware tuple must contain at least one middleware.");
                    }

                    inline for (fields) |field| {
                        try self.appendMethodMiddleware(method_name, own_method_name, path, @field(middleware_or_tuple, field.name));
                    }
                    return;
                }
            },
            else => {},
        }

        try self.appendMethodMiddleware(method_name, own_method_name, path, middleware_or_tuple);
    }

    pub fn finalize(self: *App) !void {
        try self.ensureFinalized();
    }

    fn ensureOpenForMutation(self: *App) error{AppFinalized}!void {
        if (self.finalize_state.load(.acquire) != @intFromEnum(FinalizeState.open)) {
            return error.AppFinalized;
        }
    }

    fn ensureFinalized(self: *App) !void {
        if (self.finalize_state.load(.acquire) == @intFromEnum(FinalizeState.finalized)) return;

        while (!self.finalize_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.finalize_mutex.unlock();

        const state = self.finalize_state.load(.acquire);
        if (state == @intFromEnum(FinalizeState.finalized)) return;
        if (state != @intFromEnum(FinalizeState.open)) return error.AppFinalized;

        self.finalize_state.store(@intFromEnum(FinalizeState.finalizing), .release);
        self.finalizeUnlocked() catch |err| {
            self.finalize_state.store(@intFromEnum(FinalizeState.open), .release);
            return err;
        };
        self.finalized = true;
        self.finalize_state.store(@intFromEnum(FinalizeState.finalized), .release);
    }

    fn finalizeUnlocked(self: *App) !void {
        var middleware_index = try MiddlewareIndex.build(self.allocator, self.middlewares.items);
        errdefer middleware_index.deinit(self.allocator);
        var route_middleware_index = try RouteMiddlewareIndex.build(self.allocator, self.middlewares.items, self.routes.items);
        errdefer route_middleware_index.deinit(self.allocator);
        const router = try Router.initWithLimits(self.allocator, self.routes.items, self.router_limits);
        self.middleware_index = middleware_index;
        self.route_middleware_index = route_middleware_index;
        self.router = router;
    }

    pub fn handle(self: *App, req: Request) Response {
        self.ensureFinalized() catch return response_mod.internalError("router init failed");
        var entry_req = req;
        if (self.get_path) |get_path| {
            entry_req.path = get_path(&entry_req);
        }

        if (!self.usesSharedState()) {
            var response = if (self.middlewares.items.len == 0)
                self.handleEndpoint(entry_req)
            else
                self.runMiddlewares(entry_req, 0);
            if (isHeadRequest(entry_req)) response.head_only = true;
            return response;
        }

        var handled_req = entry_req;
        const owns_context_state = handled_req.context_state == null;

        // When this App is the first to introduce shared state, allocate it
        // via the same uniform `SharedStateScope` that the wrapper family
        // uses, so that streaming responses can extend its lifetime through
        // `Response.finalizeScope`. For inherited state, the caller already
        // owns it and we must not free it.
        const owned_state_scope: ?*context_mod.SharedStateScope = if (owns_context_state) blk: {
            const s = context_mod.SharedStateScope.create(handled_req.allocator) catch
                return response_mod.internalError("context alloc failed");
            handled_req.context_state = @ptrCast(s.state);
            break :blk s;
        } else null;

        const state: *context_mod.SharedState = @ptrCast(@alignCast(handled_req.context_state.?));
        const previous_not_found_handler = state.not_found_handler;
        const previous_on_error_handler = state.on_error_handler;
        const previous_error_registry = state.error_registry;
        state.not_found_handler = self.not_found_handler;
        state.on_error_handler = self.on_error_handler;
        state.error_registry = &self.errors;

        var response = if (self.middlewares.items.len == 0)
            self.handleEndpoint(handled_req)
        else
            self.runMiddlewares(handled_req, 0);

        if (isHeadRequest(handled_req)) response.head_only = true;

        if (owns_context_state) {
            state.runWaitUntilTasks();
        }

        if (owned_state_scope) |s| {
            response.finalizeScope(
                handled_req.allocator,
                @ptrCast(s),
                context_mod.SharedStateScope.deinitOpaque,
            );
        } else {
            // Inherited state - restore handler slots we mutated above so
            // the caller observes no side effects.
            state.on_error_handler = previous_on_error_handler;
            state.not_found_handler = previous_not_found_handler;
            state.error_registry = previous_error_registry;
        }

        return response;
    }

    fn runMiddlewares(self: *App, req: Request, start_index: usize) Response {
        var lookup_cache: MiddlewareLookupCache = .{};
        defer lookup_cache.deinit(req.allocator);
        return self.runMiddlewareCandidateSet(req, start_index, self.middlewareCandidateSet(req, start_index, &lookup_cache), &lookup_cache);
    }

    const MiddlewareCandidateSet = struct {
        candidates: []const usize,
        pinned_path: []const u8 = "",
        pinned_method_name: []const u8 = "",
        pinned: bool = false,
    };

    const MiddlewareLookupCache = struct {
        lookup: ?router_mod.LookupResult = null,
        path: []const u8 = "",
        method_name: []const u8 = "",
        consumed: bool = false,

        fn deinit(self: *MiddlewareLookupCache, allocator: std.mem.Allocator) void {
            if (!self.consumed) {
                if (self.lookup) |lookup| {
                    if (lookup.params_storage) |storage| allocator.free(storage);
                }
            }
            self.* = .{};
        }

        fn store(self: *MiddlewareLookupCache, req: Request, lookup: router_mod.LookupResult) void {
            self.lookup = lookup;
            self.path = req.path;
            self.method_name = req.methodName();
            self.consumed = false;
        }

        fn take(self: *MiddlewareLookupCache, req: Request) ?router_mod.LookupResult {
            const lookup = self.lookup orelse return null;
            if (self.consumed) return null;
            if (!std.mem.eql(u8, req.path, self.path)) return null;
            if (!http_method.eqlIgnoreCase(req.methodName(), self.method_name)) return null;
            self.consumed = true;
            self.lookup = null;
            return lookup;
        }
    };

    fn middlewareCandidateSet(self: *App, req: Request, start_index: usize, lookup_cache: *MiddlewareLookupCache) MiddlewareCandidateSet {
        if (start_index == 0 and !isHeadRequest(req)) {
            const router = &self.router.?;
            var lookup_req = req;
            lookup_req.path = canonicalPath(req.path, self.strict);
            const lookup = router.lookup(lookup_req);
            lookup_cache.store(req, lookup);
            if (lookup.route_index) |route_index| {
                if (self.route_middleware_index.candidatesFor(route_index)) |candidates| {
                    return .{
                        .candidates = candidates,
                        .pinned_path = req.path,
                        .pinned_method_name = req.methodName(),
                        .pinned = true,
                    };
                }
            }
        }

        return .{
            .candidates = self.middleware_index.candidatesFor(req.methodName()),
        };
    }

    fn runMiddlewareCandidateSet(self: *App, req: Request, start_index: usize, candidate_set: MiddlewareCandidateSet, lookup_cache: *MiddlewareLookupCache) Response {
        var candidate_index: usize = 0;
        while (candidate_index < candidate_set.candidates.len and candidate_set.candidates[candidate_index] < start_index) : (candidate_index += 1) {}

        while (candidate_index < candidate_set.candidates.len) : (candidate_index += 1) {
            const middleware_index = candidate_set.candidates[candidate_index];
            const middleware_entry = &self.middlewares.items[middleware_index];
            if (!middlewareMatches(middleware_entry.prefix, req.path, self.strict)) continue;
            return self.dispatchMiddleware(req, middleware_index, middleware_entry, candidate_set, lookup_cache);
        }

        return self.handleEndpointWithLookup(req, lookup_cache.take(req));
    }

    fn dispatchMiddleware(self: *App, req: Request, middleware_index: usize, middleware_entry: *const MiddlewareEntry, candidate_set: MiddlewareCandidateSet, lookup_cache: *MiddlewareLookupCache) Response {
        const frame = MiddlewareFrame{
            .app = self,
            .next_index = middleware_index + 1,
            .candidates = candidate_set.candidates,
            .pinned_path = candidate_set.pinned_path,
            .pinned_method_name = candidate_set.pinned_method_name,
            .pinned = candidate_set.pinned,
            .lookup_cache = lookup_cache,
        };
        const middleware_req = req;
        const previous_on_error_handler = pushScopedErrorHandler(middleware_req, middleware_entry.on_error_handler);
        defer restoreScopedErrorHandler(middleware_req, previous_on_error_handler);
        return middleware_entry.handler(middleware_req, .{
            .ctx = &frame,
            .run_fn = runMiddlewareNext,
        });
    }

    fn handleEndpoint(self: *App, req: Request) Response {
        return self.handleEndpointWithLookup(req, null);
    }

    fn handleEndpointWithLookup(self: *App, req: Request, cached_lookup: ?router_mod.LookupResult) Response {
        const router = &self.router.?;
        var lookup_req = req;
        lookup_req.path = canonicalPath(req.path, self.strict);
        const req_method_name = req.methodName();
        const is_head_request = http_method.isHead(req_method_name);
        const lookup = cached_lookup orelse router.lookup(lookup_req);
        if (lookup.reject) |reject| return rejectedLookupResponse(reject);
        if (lookup.handler) |handler| {
            return self.dispatchLookup(req, lookup, handler);
        }

        var head_get_lookup: ?router_mod.LookupResult = null;
        if (is_head_request) {
            var get_lookup_req = lookup_req;
            get_lookup_req.setMethodName("GET");
            const get_lookup = router.lookup(get_lookup_req);
            if (get_lookup.reject) |reject| return rejectedLookupResponse(reject);
            if (get_lookup.handler) |handler| {
                var response = self.dispatchLookup(req, get_lookup, handler);
                response.head_only = true;
                return response;
            }
            head_get_lookup = get_lookup;
        }

        if (matchMount(self.mounts.items, req.path)) |matched_mount| {
            var mounted_req = req;
            mounted_req.path = matched_mount.path;
            return dispatchMount(matched_mount.mount.target, mounted_req);
        }

        const tsr = lookup.tsr or (if (head_get_lookup) |head_lookup| head_lookup.tsr else false);
        if (self.redirect_trailing_slash and tsr and !std.mem.eql(u8, req.path, "/")) {
            if (trailingSlashVariant(req.allocator, req.path) catch null) |redirect_path| {
                const owns_redirect_path = redirect_path.ptr != req.path.ptr;
                const location = appendQuery(req.allocator, redirect_path, req.query_string) catch redirect_path;
                var res = response_mod.redirectForMethodName(req.methodName(), location);
                if (res.ensureOwned(req.allocator)) {
                    if (owns_redirect_path) req.allocator.free(redirect_path);
                    if (location.ptr != redirect_path.ptr) req.allocator.free(location);
                } else |_| {}
                return res;
            }
        }

        if (self.redirect_fixed_path) {
            const cleaned = if (path_mod.needsCleaning(lookup_req.path))
                path_mod.cleanPath(req.allocator, lookup_req.path) catch lookup_req.path
            else
                lookup_req.path;
            defer if (cleaned.ptr != lookup_req.path.ptr) req.allocator.free(cleaned);
            const fixed_method_name = if (is_head_request) "GET" else req_method_name;
            if (router.findCaseInsensitivePathForMethodName(req.allocator, fixed_method_name, cleaned, true) catch null) |fixed| {
                const location = appendQuery(req.allocator, fixed, req.query_string) catch fixed;
                var res = response_mod.redirectForMethodName(req_method_name, location);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(fixed);
                    if (location.ptr != fixed.ptr) req.allocator.free(location);
                } else |_| {}
                return res;
            }
        }

        if (http_method.isOptions(req_method_name) and self.handle_options) {
            if (router.allowedForMethodName(req.allocator, lookup_req.path, req_method_name, self.handle_options) catch null) |allow| {
                var res = response_mod.options(allow);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(allow);
                } else |_| {}
                return res;
            }
        }

        if (self.handle_method_not_allowed) {
            if (router.allowedForMethodName(req.allocator, lookup_req.path, req_method_name, self.handle_options) catch null) |allow| {
                var res = response_mod.methodNotAllowed(allow);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(allow);
                } else |_| {}
                return res;
            }
        }

        if (self.not_found_handler) |handler| {
            return handler(req);
        }

        return response_mod.notFound();
    }

    fn dispatchLookup(self: *App, req: Request, lookup: router_mod.LookupResult, handler: Handler) Response {
        _ = self;
        defer if (lookup.params_storage) |storage| req.allocator.free(storage);
        var routed_req = req;
        routed_req.params = lookup.params;
        routed_req.route_path = lookup.route_path;
        routed_req.base_route_path = lookup.base_route_path;
        const previous_on_error_handler = pushScopedErrorHandler(routed_req, lookup.on_error_handler);
        defer restoreScopedErrorHandler(routed_req, previous_on_error_handler);
        return handler(routed_req);
    }

    const ScopedErrorRestore = struct {
        active: bool = false,
        previous: ?ErrorHandler = null,
    };

    fn pushScopedErrorHandler(req: Request, scoped_handler: ?ErrorHandler) ScopedErrorRestore {
        const handler = scoped_handler orelse return .{};
        const raw_state = req.context_state orelse return .{};
        const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
        const previous = state.on_error_handler;
        state.on_error_handler = handler;
        return .{ .active = true, .previous = previous };
    }

    fn restoreScopedErrorHandler(req: Request, restore: ScopedErrorRestore) void {
        if (!restore.active) return;
        const raw_state = req.context_state orelse return;
        const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
        state.on_error_handler = restore.previous;
    }

    pub fn fetch(self: *App, req: Request) Response {
        return self.handle(req);
    }

    pub fn request(self: *App, allocator: std.mem.Allocator, input: anytype, req_options: RequestOptions) !Response {
        const InputType = @TypeOf(input);
        if (InputType == Request) {
            return try self.cloneHandledResponse(allocator, input);
        }
        if (InputType == *const Request or InputType == *Request) {
            return try self.cloneHandledResponse(allocator, input.*);
        }
        if (!comptime isStringLike(InputType)) {
            @compileError("App.request input must be a zono.Request, *zono.Request, or a string-like target.");
        }

        const target: []const u8 = input;
        return try self.requestTarget(allocator, target, req_options);
    }

    fn requestTarget(self: *App, allocator: std.mem.Allocator, target: []const u8, req_options: RequestOptions) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const temp_allocator = arena.allocator();
        const split = try request_target.splitAlloc(temp_allocator, target);

        var req = Request.init(temp_allocator, req_options.method, split.path);
        req.query_string = split.query_string;
        req.header_list = req_options.headers;
        req.body_bytes = req_options.body;
        req.cookies_raw = req_options.cookies_raw orelse "";
        req.raw_ctx = req_options.raw_ctx;
        req.env_ctx = req_options.env_ctx;
        req.conn_info = req_options.conn_info;
        if (req_options.method_name) |method_name| req.setMethodName(method_name);

        var response = self.handle(req);
        defer response.deinit();
        return try materializeResponse(allocator, &response);
    }

    fn cloneHandledResponse(self: *App, allocator: std.mem.Allocator, req: Request) !Response {
        var response = self.handle(req);
        defer response.deinit();
        return try materializeResponse(allocator, &response);
    }

    /// Renders a handled response into an owned, buffered `Response` suitable
    /// for inspection by tests or programmatic callers. Streaming bodies are
    /// drained into memory via `renderStreamingToBuffered`.
    fn materializeResponse(allocator: std.mem.Allocator, response: *response_mod.Response) !Response {
        var materialized = switch (response.body_kind) {
            .buffered => try response.clone(allocator),
            .stream, .sse, .file => try response.renderStreamingToBuffered(allocator),
        };
        errdefer materialized.deinit();
        if (response.head_only) {
            _ = materialized.setBody("");
            materialized.head_only = true;
        }
        return materialized;
    }

    fn registerOn(self: *App, methods: anytype, paths: anytype, handler: anytype) !void {
        const MethodsType = @TypeOf(methods);
        if (MethodsType == std.http.Method) {
            try self.registerPaths(methods, paths, handler);
            return;
        }
        if (MethodsType == @TypeOf(.enum_literal)) {
            try self.registerPaths(@field(std.http.Method, @tagName(methods)), paths, handler);
            return;
        }
        if (comptime isStringLike(MethodsType)) {
            try self.registerCustomPaths(methods, paths, handler);
            return;
        }

        switch (comptime @typeInfo(MethodsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (methods) |method| {
                        try self.registerAnyMethodPaths(method, paths, handler);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (methods.*) |method| {
                            try self.registerAnyMethodPaths(method, paths, handler);
                        }
                    },
                    else => @compileError("App.on methods pointer must reference an array of methods."),
                },
                else => @compileError("App.on methods must be a std.http.Method, method name, or an iterable of methods."),
            },
            .array => {
                for (methods) |method| {
                    try self.registerAnyMethodPaths(method, paths, handler);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.on methods must be a std.http.Method, method name, or an iterable of methods.");
                }
                inline for (methods) |method| {
                    try self.registerAnyMethodPaths(method, paths, handler);
                }
            },
            else => @compileError("App.on methods must be a std.http.Method, method name, or an iterable of methods."),
        }
    }

    fn registerOnMiddleware(self: *App, methods: anytype, paths: anytype, middleware_or_tuple: anytype) !void {
        const MethodsType = @TypeOf(methods);
        if (MethodsType == std.http.Method) {
            try self.registerMiddlewarePaths(@tagName(methods), false, paths, middleware_or_tuple);
            return;
        }
        if (MethodsType == @TypeOf(.enum_literal)) {
            const method_name = @tagName(@field(std.http.Method, @tagName(methods)));
            try self.registerMiddlewarePaths(method_name, false, paths, middleware_or_tuple);
            return;
        }
        if (comptime isStringLike(MethodsType)) {
            try self.registerMiddlewarePaths(methods, true, paths, middleware_or_tuple);
            return;
        }

        switch (comptime @typeInfo(MethodsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (methods) |method| {
                        try self.registerAnyMethodMiddlewarePaths(method, paths, middleware_or_tuple);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (methods.*) |method| {
                            try self.registerAnyMethodMiddlewarePaths(method, paths, middleware_or_tuple);
                        }
                    },
                    else => @compileError("App.useOn methods pointer must reference an array of methods."),
                },
                else => @compileError("App.useOn methods must be a std.http.Method, method name, or an iterable of methods."),
            },
            .array => {
                for (methods) |method| {
                    try self.registerAnyMethodMiddlewarePaths(method, paths, middleware_or_tuple);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.useOn methods must be a std.http.Method, method name, or an iterable of methods.");
                }
                inline for (methods) |method| {
                    try self.registerAnyMethodMiddlewarePaths(method, paths, middleware_or_tuple);
                }
            },
            else => @compileError("App.useOn methods must be a std.http.Method, method name, or an iterable of methods."),
        }
    }

    fn registerAnyMethodPaths(self: *App, method: anytype, paths: anytype, handler: anytype) !void {
        const MethodType = @TypeOf(method);
        if (MethodType == std.http.Method) {
            try self.registerPaths(method, paths, handler);
            return;
        }
        if (MethodType == @TypeOf(.enum_literal)) {
            try self.registerPaths(@field(std.http.Method, @tagName(method)), paths, handler);
            return;
        }
        if (comptime isStringLike(MethodType)) {
            try self.registerCustomPaths(method, paths, handler);
            return;
        }
        @compileError("App.on method entries must be std.http.Method values or method name strings.");
    }

    fn registerPaths(self: *App, method: std.http.Method, paths: anytype, handler: anytype) !void {
        const PathsType = @TypeOf(paths);
        if (comptime isStringLike(PathsType)) {
            const path_slice: []const u8 = paths;
            try self.addRouteOrMethodMiddleware(method, path_slice, handler);
            return;
        }

        switch (comptime @typeInfo(PathsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (paths) |path| {
                        const path_slice: []const u8 = path;
                        try self.addRouteOrMethodMiddleware(method, path_slice, handler);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (paths.*) |path| {
                            const path_slice: []const u8 = path;
                            try self.addRouteOrMethodMiddleware(method, path_slice, handler);
                        }
                    },
                    else => @compileError("App.on paths pointer must reference an array of route paths."),
                },
                else => @compileError("App.on paths must be a route path or an iterable of route paths."),
            },
            .array => {
                for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addRouteOrMethodMiddleware(method, path_slice, handler);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.on paths must be a route path or an iterable of route paths.");
                }
                inline for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addRouteOrMethodMiddleware(method, path_slice, handler);
                }
            },
            else => @compileError("App.on paths must be a route path or an iterable of route paths."),
        }
    }

    fn registerCustomPaths(self: *App, method_name: []const u8, paths: anytype, handler: anytype) !void {
        const PathsType = @TypeOf(paths);
        if (comptime isStringLike(PathsType)) {
            const path_slice: []const u8 = paths;
            try self.addCustomRouteOrMethodMiddleware(method_name, path_slice, handler);
            return;
        }

        switch (comptime @typeInfo(PathsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (paths) |path| {
                        const path_slice: []const u8 = path;
                        try self.addCustomRouteOrMethodMiddleware(method_name, path_slice, handler);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (paths.*) |path| {
                            const path_slice: []const u8 = path;
                            try self.addCustomRouteOrMethodMiddleware(method_name, path_slice, handler);
                        }
                    },
                    else => @compileError("App.on paths pointer must reference an array of route paths."),
                },
                else => @compileError("App.on paths must be a route path or an iterable of route paths."),
            },
            .array => {
                for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addCustomRouteOrMethodMiddleware(method_name, path_slice, handler);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.on paths must be a route path or an iterable of route paths.");
                }
                inline for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addCustomRouteOrMethodMiddleware(method_name, path_slice, handler);
                }
            },
            else => @compileError("App.on paths must be a route path or an iterable of route paths."),
        }
    }

    fn registerAnyMethodMiddlewarePaths(self: *App, method: anytype, paths: anytype, middleware_or_tuple: anytype) !void {
        const MethodType = @TypeOf(method);
        if (MethodType == std.http.Method) {
            try self.registerMiddlewarePaths(@tagName(method), false, paths, middleware_or_tuple);
            return;
        }
        if (MethodType == @TypeOf(.enum_literal)) {
            const method_name = @tagName(@field(std.http.Method, @tagName(method)));
            try self.registerMiddlewarePaths(method_name, false, paths, middleware_or_tuple);
            return;
        }
        if (comptime isStringLike(MethodType)) {
            try self.registerMiddlewarePaths(method, true, paths, middleware_or_tuple);
            return;
        }
        @compileError("App.useOn method entries must be std.http.Method values or method name strings.");
    }

    fn registerMiddlewarePaths(
        self: *App,
        method_name: []const u8,
        comptime own_method_name: bool,
        paths: anytype,
        middleware_or_tuple: anytype,
    ) !void {
        const PathsType = @TypeOf(paths);
        if (comptime isStringLike(PathsType)) {
            const path_slice: []const u8 = paths;
            try self.addMethodMiddlewareInput(method_name, own_method_name, path_slice, middleware_or_tuple);
            return;
        }

        switch (comptime @typeInfo(PathsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (paths) |path| {
                        const path_slice: []const u8 = path;
                        try self.addMethodMiddlewareInput(method_name, own_method_name, path_slice, middleware_or_tuple);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (paths.*) |path| {
                            const path_slice: []const u8 = path;
                            try self.addMethodMiddlewareInput(method_name, own_method_name, path_slice, middleware_or_tuple);
                        }
                    },
                    else => @compileError("App.useOn paths pointer must reference an array of paths."),
                },
                else => @compileError("App.useOn paths must be a path or an iterable of paths."),
            },
            .array => {
                for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addMethodMiddlewareInput(method_name, own_method_name, path_slice, middleware_or_tuple);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.useOn paths must be a path or an iterable of paths.");
                }
                inline for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addMethodMiddlewareInput(method_name, own_method_name, path_slice, middleware_or_tuple);
                }
            },
            else => @compileError("App.useOn paths must be a path or an iterable of paths."),
        }
    }

    fn clearBasePath(self: *App) void {
        if (self.base_path_owned) |owned| {
            self.allocator.free(owned);
        }
        self.base_path = "";
        self.base_path_owned = null;
    }

    fn usesSharedState(self: *const App) bool {
        return self.has_context_handlers or
            self.has_context_middlewares or
            self.has_context_not_found or
            self.has_error_handlers or
            self.has_error_middlewares;
    }
};

const MiddlewareFrame = struct {
    app: *App,
    next_index: usize,
    candidates: []const usize = &.{},
    pinned_path: []const u8 = "",
    pinned_method_name: []const u8 = "",
    pinned: bool = false,
    lookup_cache: *App.MiddlewareLookupCache,
};

fn runMiddlewareNext(ctx: *const anyopaque, req: Request) Response {
    const frame: *const MiddlewareFrame = @ptrCast(@alignCast(ctx));
    if (frame.pinned and
        std.mem.eql(u8, req.path, frame.pinned_path) and
        http_method.eqlIgnoreCase(req.methodName(), frame.pinned_method_name))
    {
        return frame.app.runMiddlewareCandidateSet(req, frame.next_index, .{
            .candidates = frame.candidates,
            .pinned_path = frame.pinned_path,
            .pinned_method_name = frame.pinned_method_name,
            .pinned = true,
        }, frame.lookup_cache);
    }
    return frame.app.runMiddlewares(req, frame.next_index);
}

fn isHeadRequest(req: Request) bool {
    return http_method.isHead(req.methodName());
}

const MountMatch = struct {
    mount: *const App.Mount,
    path: []const u8,
};

fn trailingSlashVariant(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len <= 1) return null;

    if (path[path.len - 1] == '/') return path[0 .. path.len - 1];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, path);
    try out.append(allocator, '/');
    return try out.toOwnedSlice(allocator);
}

fn appendQuery(allocator: std.mem.Allocator, path: []const u8, query_string: []const u8) ![]const u8 {
    if (query_string.len == 0) return path;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, path);
    try out.append(allocator, '?');
    try out.appendSlice(allocator, query_string);
    return try out.toOwnedSlice(allocator);
}

fn normalizePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const cleaned = try path_mod.cleanPath(allocator, prefix);
    errdefer allocator.free(cleaned);

    if (cleaned.len > 1 and cleaned[cleaned.len - 1] == '/') {
        const trimmed = try allocator.dupe(u8, cleaned[0 .. cleaned.len - 1]);
        allocator.free(cleaned);
        return trimmed;
    }

    return cleaned;
}

fn normalizeMiddlewarePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const normalized = try normalizePrefix(allocator, prefix);
    errdefer allocator.free(normalized);

    if (normalized.len == 0 or std.mem.eql(u8, normalized, "/")) {
        allocator.free(normalized);
        return try allocator.dupe(u8, "");
    }

    return normalized;
}

fn scopedMiddlewarePrefix(allocator: std.mem.Allocator, base_path: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "*") or std.mem.eql(u8, path, "/*")) {
        if (base_path.len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, base_path);
    }

    const match_path = if (std.mem.endsWith(u8, path, "/*")) path[0 .. path.len - 2] else path;
    const joined_path = try joinPrefixedPath(allocator, base_path, match_path);
    defer allocator.free(joined_path);
    return try normalizeMiddlewarePrefix(allocator, joined_path);
}

fn ownedRouteBasePath(allocator: std.mem.Allocator, base_path: []const u8) !?[]const u8 {
    if (base_path.len == 0) return null;
    return try allocator.dupe(u8, base_path);
}

fn joinedBasePath(allocator: std.mem.Allocator, mounted_prefix: []const u8, nested_base_path: ?[]const u8) !?[]const u8 {
    if (nested_base_path) |nested| {
        const joined = try joinPrefixedPath(allocator, mounted_prefix, nested);
        defer allocator.free(joined);
        const normalized = try normalizePrefix(allocator, joined);
        if (std.mem.eql(u8, normalized, "/")) {
            allocator.free(normalized);
            return null;
        }
        return normalized;
    }

    if (std.mem.eql(u8, mounted_prefix, "/") or mounted_prefix.len == 0) return null;
    return try allocator.dupe(u8, mounted_prefix);
}

fn middlewareMatches(prefix: []const u8, path: []const u8, strict: bool) bool {
    if (prefix.len == 0) return true;

    const candidate_path = canonicalPath(path, strict);
    if (std.mem.eql(u8, candidate_path, prefix)) return true;

    return candidate_path.len > prefix.len and
        std.mem.startsWith(u8, candidate_path, prefix) and
        candidate_path[prefix.len] == '/';
}

fn joinPrefixedPath(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    const normalized_prefix = if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) "" else prefix;
    const route_path = if (path.len == 0) "/" else path;

    if (normalized_prefix.len == 0) {
        if (route_path[0] == '/') return try allocator.dupe(u8, route_path);

        var root_prefixed: std.ArrayListUnmanaged(u8) = .empty;
        errdefer root_prefixed.deinit(allocator);
        try root_prefixed.append(allocator, '/');
        try root_prefixed.appendSlice(allocator, route_path);
        return try root_prefixed.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, route_path, "/")) {
        return try allocator.dupe(u8, normalized_prefix);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, normalized_prefix);
    if (route_path[0] != '/') try out.append(allocator, '/');
    try out.appendSlice(allocator, route_path);
    return try out.toOwnedSlice(allocator);
}

fn canonicalPath(path: []const u8, strict: bool) []const u8 {
    if (strict or path.len <= 1 or path[path.len - 1] != '/') return path;
    return path[0 .. path.len - 1];
}

fn canonicalizeOwnedPath(allocator: std.mem.Allocator, path: []const u8, strict: bool) ![]const u8 {
    const canonical = canonicalPath(path, strict);
    if (canonical.len == path.len) return path;

    const owned = try allocator.dupe(u8, canonical);
    allocator.free(path);
    return owned;
}

fn rejectedLookupResponse(reject: router_mod.LookupReject) Response {
    return switch (reject) {
        .path_too_long, .too_many_segments, .param_value_too_long => response_mod.text(.uri_too_long, "URI Too Long"),
    };
}

const ResolvedMountTarget = struct {
    target: App.MountTarget,
    uses_context: bool = false,
    uses_error: bool = false,
};

fn resolveMountTarget(target: anytype) ResolvedMountTarget {
    const TargetType = @TypeOf(target);
    if (TargetType == *App) return .{ .target = .{ .app = target } };
    if (TargetType == *const App) return .{ .target = .{ .app = @constCast(target) } };
    if (TargetType == Handler) return .{ .target = .{ .handler = target } };

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => blk: {
            const resolved = resolveHandler(target);
            break :blk .{
                .target = .{ .handler = resolved.handler },
                .uses_context = resolved.uses_context,
                .uses_error = resolved.uses_error,
            };
        },
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => blk: {
                const resolved = resolveHandler(target);
                break :blk .{
                    .target = .{ .handler = resolved.handler },
                    .uses_context = resolved.uses_context,
                    .uses_error = resolved.uses_error,
                };
            },
            else => @compileError("App.mount target must be a *zono.App or a compatible handler."),
        },
        else => @compileError("App.mount target must be a *zono.App or a compatible handler."),
    };
}

const ResolvedHandler = struct {
    handler: Handler,
    uses_context: bool,
    uses_error: bool,
};

const ResolvedMiddleware = struct {
    handler: App.DispatchMiddleware,
    uses_context: bool,
    uses_error: bool,
};

const ResolvedErrorHandler = struct {
    handler: ErrorHandler,
};

fn websocketRouteHandler(
    comptime websocket_handler: anytype,
    comptime websocket_options: websocket_mod.WebSocketUpgradeOptions,
) Handler {
    const normalized = if (@TypeOf(websocket_handler) == type)
        websocket_mod.webSocketHandler(websocket_handler)
    else
        websocket_handler;
    return struct {
        fn run(req: Request) Response {
            return websocket_mod.upgradeWebSocket(req, normalized, websocket_options);
        }
    }.run;
}

fn resolveHandler(target: anytype) ResolvedHandler {
    const TargetType = @TypeOf(target);
    if (TargetType == Handler) {
        return .{
            .handler = target,
            .uses_context = false,
            .uses_error = false,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"struct" => |struct_info| switch (struct_info.is_tuple) {
            true => resolveHandlerChain(target, TargetType),
            false => @compileError("Route handlers must be a compatible handler or a tuple like .{ middleware, handler }."),
        },
        .@"fn" => resolveHandlerFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveHandlerFn(target, pointer.child),
            else => @compileError("Route handlers must be fn(c: *zono.Context) zono.Response or fn(c: *zono.Context) !zono.Response."),
        },
        else => @compileError("Route handlers must be fn(c: *zono.Context) zono.Response, fn(c: *zono.Context) !zono.Response, or a tuple like .{ middleware, handler }."),
    };
}

fn resolveHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedHandler {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Route handlers");
    if (info.params.len != 1 or info.params[0].type == null) {
        @compileError("Route handlers must accept exactly one parameter.");
    }

    const ParamType = info.params[0].type.?;
    if (ParamType == *Context) {
        if (returns_error) {
            return .{
                .handler = wrapContextErrorHandler(target),
                .uses_context = true,
                .uses_error = true,
            };
        }
        return .{
            .handler = wrapContextHandler(target),
            .uses_context = true,
            .uses_error = false,
        };
    }

    @compileError("Route handlers must be fn(c: *zono.Context) zono.Response or fn(c: *zono.Context) !zono.Response.");
}

fn resolveHandlerChain(target: anytype, comptime TargetType: type) ResolvedHandler {
    const fields = std.meta.fields(TargetType);
    if (fields.len == 0) {
        @compileError("Route handler tuples must contain at least one handler.");
    }

    comptime var uses_error = false;

    if (fields.len == 1) {
        const resolved = resolveHandler(@field(target, fields[0].name));
        return resolved;
    }

    const middleware_count = fields.len - 1;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        const resolved = comptime resolveMiddlewareHandler(item);
        uses_error = uses_error or resolved.uses_error;
    }

    comptime var middlewares: [middleware_count]App.DispatchMiddleware = undefined;
    comptime var middleware_index: usize = 0;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        const resolved = comptime resolveMiddlewareHandler(item);
        middlewares[middleware_index] = resolved.handler;
        middleware_index += 1;
    }

    const final_resolved = comptime resolveHandler(@field(target, fields[fields.len - 1].name));
    uses_error = uses_error or final_resolved.uses_error;

    return .{
        .handler = wrapRouteChain(middlewares, final_resolved.handler),
        .uses_context = true,
        .uses_error = uses_error,
    };
}

fn resolveMiddlewareHandler(target: anytype) ResolvedMiddleware {
    const TargetType = @TypeOf(target);
    if (TargetType == App.DispatchMiddleware) {
        return .{
            .handler = target,
            .uses_context = true,
            .uses_error = false,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveMiddlewareFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveMiddlewareFn(target, pointer.child),
            else => @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
        },
        else => @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
    };
}

fn resolveMiddlewareFn(comptime target: anytype, comptime FnType: type) ResolvedMiddleware {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Middleware handlers");
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("Middleware handlers must accept exactly two parameters.");
    }

    const FirstParam = info.params[0].type.?;
    const SecondParam = info.params[1].type.?;
    if (FirstParam == *Context and SecondParam == Context.Next) {
        if (returns_error) {
            return .{
                .handler = wrapContextErrorMiddleware(target),
                .uses_context = true,
                .uses_error = true,
            };
        }
        return .{
            .handler = wrapContextMiddleware(target),
            .uses_context = true,
            .uses_error = false,
        };
    }

    @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response.");
}

fn resolveErrorHandler(target: anytype) ResolvedErrorHandler {
    const TargetType = @TypeOf(target);
    if (TargetType == ErrorHandler) {
        return .{
            .handler = target,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveErrorHandlerFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveErrorHandlerFn(target, pointer.child),
            else => @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response."),
        },
        else => @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response."),
    };
}

fn resolveErrorHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedErrorHandler {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "App.onError handlers");
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("App.onError handlers must accept exactly two parameters.");
    }
    if (info.params[0].type.? != anyerror) {
        @compileError("App.onError handlers must accept err: anyerror as the first parameter.");
    }

    const ParamType = info.params[1].type.?;
    if (ParamType == *Context) {
        return .{
            .handler = wrapContextErrorResponder(target, returns_error),
        };
    }

    @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response or fn(err: anyerror, c: *zono.Context) !zono.Response.");
}

fn returnsErrorResponse(comptime return_type: ?type, comptime owner: []const u8) bool {
    if (return_type == null) {
        @compileError(owner ++ " must return zono.Response or !zono.Response.");
    }

    const ReturnType = return_type.?;
    if (ReturnType == Response) return false;

    return switch (@typeInfo(ReturnType)) {
        .error_union => |error_union| blk: {
            if (error_union.payload != Response) {
                @compileError(owner ++ " must return zono.Response or !zono.Response.");
            }
            break :blk true;
        },
        else => @compileError(owner ++ " must return zono.Response or !zono.Response."),
    };
}

/// Per-handler/middleware scope bundle. Always carries a `ContextScope`
/// (the heap `Context` + duped params). When this wrapper is the first to
/// introduce `SharedState` (i.e. nothing in the outer chain provided
/// one), it also carries a `SharedStateScope` that owns that state. The
/// two scopes are attached to the response in order so that on deinit the
/// `Context` is freed before the `SharedState` it borrows from.
const HandlerScope = struct {
    state_scope: ?*context_mod.SharedStateScope,
    ctx_scope: *context_mod.ContextScope,
};

/// Heap-allocates the scope bundle for a context-aware handler. If the
/// inbound request already has a `context_state`, the scope inherits it;
/// otherwise a fresh `SharedState` is owned by `state_scope`. Returns
/// `null` on allocation failure.
fn createHandlerScope(req: Request) ?HandlerScope {
    const inherited_state: ?*context_mod.SharedState = if (req.context_state) |raw|
        @ptrCast(@alignCast(raw))
    else
        null;

    var owned_state_scope: ?*context_mod.SharedStateScope = null;
    if (inherited_state == null) {
        owned_state_scope = context_mod.SharedStateScope.create(req.allocator) catch return null;
    }
    errdefer if (owned_state_scope) |s| s.deinit();

    const state = inherited_state orelse owned_state_scope.?.state;

    const ctx_scope = context_mod.ContextScope.create(req.allocator, req, state) catch {
        if (owned_state_scope) |s| s.deinit();
        return null;
    };

    return .{ .state_scope = owned_state_scope, .ctx_scope = ctx_scope };
}

/// Finalizes a `HandlerScope` after the user handler returns: each scope
/// is either attached to the response (extending its lifetime past this
/// frame) or freed immediately, via `Response.finalizeScope`.
///
/// Attach order matters: the state scope goes on first so that on deinit
/// the `Context` (which borrows the state) is freed before the state.
fn finalizeHandlerScope(scope: HandlerScope, response: *Response) void {
    const allocator = scope.ctx_scope.allocator;
    if (scope.state_scope) |s| {
        response.finalizeScope(allocator, @ptrCast(s), context_mod.SharedStateScope.deinitOpaque);
    }
    response.finalizeScope(allocator, @ptrCast(scope.ctx_scope), context_mod.ContextScope.deinitOpaque);
}

fn responseNeedsContextScope(response: *const Response) bool {
    return switch (response.body_kind) {
        .stream, .sse => true,
        else => response.runtime != .none,
    };
}

fn patchResponseContext(response: *Response, old_ctx: *Context, new_ctx: *Context) void {
    const old_erased: *const anyopaque = @ptrCast(old_ctx);
    const new_erased: *const anyopaque = @ptrCast(new_ctx);
    switch (response.body_kind) {
        .stream => |*runtime| {
            if (runtime.ctx == old_erased) runtime.ctx = new_erased;
        },
        .sse => |*runtime| {
            if (runtime.ctx == old_erased) runtime.ctx = new_erased;
        },
        else => {},
    }
    switch (response.runtime) {
        .websocket => |*runtime| {
            if (runtime.ctx == old_erased) runtime.ctx = new_erased;
        },
        .none => {},
    }
}

fn finalizeStackContext(req: Request, ctx: *Context, response: *Response) void {
    if (!responseNeedsContextScope(response)) return;

    const state: *context_mod.SharedState = @ptrCast(@alignCast(req.context_state.?));
    const ctx_scope = context_mod.ContextScope.create(req.allocator, ctx.req, state) catch {
        response.deinit();
        response.* = response_mod.internalError("context alloc failed");
        return;
    };
    patchResponseContext(response, ctx, ctx_scope.ctx);
    response.finalizeScope(req.allocator, @ptrCast(ctx_scope), context_mod.ContextScope.deinitOpaque);
}

fn runWithStackContext(req: Request, comptime target: anytype) Response {
    if (req.context_state == null) {
        const scope = createHandlerScope(req) orelse
            return response_mod.internalError("context alloc failed");
        var response = target(scope.ctx_scope.ctx);
        finalizeHandlerScope(scope, &response);
        return response;
    }

    var ctx = Context.init(req);
    var response = target(&ctx);
    finalizeStackContext(req, &ctx, &response);
    return response;
}

fn runErrorWithStackContext(req: Request, comptime target: anytype) Response {
    if (req.context_state == null) {
        const scope = createHandlerScope(req) orelse
            return response_mod.internalError("context alloc failed");
        var response = target(scope.ctx_scope.ctx) catch |err| dispatchHandlerError(scope.ctx_scope.ctx.req, err);
        finalizeHandlerScope(scope, &response);
        return response;
    }

    var ctx = Context.init(req);
    var response = target(&ctx) catch |err| dispatchHandlerError(ctx.req, err);
    finalizeStackContext(req, &ctx, &response);
    return response;
}

fn wrapContextHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            return runWithStackContext(req, target);
        }
    }.run;
}

fn wrapContextErrorHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            return runErrorWithStackContext(req, target);
        }
    }.run;
}

fn wrapContextMiddleware(comptime target: anytype) App.DispatchMiddleware {
    return struct {
        fn run(req: Request, next: App.DispatchNext) Response {
            if (req.context_state != null) {
                var ctx = Context.init(req);
                var response = target(&ctx, .{
                    .ctx = &ctx,
                    .next_ctx = &next,
                    .run_fn = runContextMiddlewareNext,
                });
                finalizeStackContext(req, &ctx, &response);
                return response;
            }

            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx, .{
                .ctx = scope.ctx_scope.ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            });
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextErrorMiddleware(comptime target: anytype) App.DispatchMiddleware {
    return struct {
        fn run(req: Request, next: App.DispatchNext) Response {
            if (req.context_state != null) {
                var ctx = Context.init(req);
                var response = target(&ctx, .{
                    .ctx = &ctx,
                    .next_ctx = &next,
                    .run_fn = runContextMiddlewareNext,
                }) catch |err| dispatchHandlerError(ctx.req, err);
                finalizeStackContext(req, &ctx, &response);
                return response;
            }

            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx, .{
                .ctx = scope.ctx_scope.ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            }) catch |err| dispatchHandlerError(scope.ctx_scope.ctx.req, err);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextErrorResponder(comptime target: anytype, comptime returns_error: bool) ErrorHandler {
    return struct {
        fn run(err: anyerror, req: Request) Response {
            if (req.context_state != null) {
                var ctx = Context.init(req);
                ctx.state.last_error = err;
                ctx.err = err;
                var response = if (returns_error)
                    target(err, &ctx) catch |hook_err|
                        dispatchHandlerError(ctx.req, hook_err)
                else
                    target(err, &ctx);
                finalizeStackContext(req, &ctx, &response);
                return response;
            }

            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            scope.ctx_scope.ctx.state.last_error = err;
            scope.ctx_scope.ctx.err = err;
            var response = if (returns_error)
                target(err, scope.ctx_scope.ctx) catch |hook_err|
                    dispatchHandlerError(scope.ctx_scope.ctx.req, hook_err)
            else
                target(err, scope.ctx_scope.ctx);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn runContextMiddlewareNext(next_ctx: *const anyopaque, req: Request) Response {
    const next: *const App.DispatchNext = @ptrCast(@alignCast(next_ctx));
    return next.run(req);
}

fn dispatchHandlerError(req: Request, err: anyerror) Response {
    if (req.context_state) |raw_state| {
        const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
        state.last_error = err;
        // Reentry guard: if we're already inside the user's onError, do NOT
        // call it again - fall through to the static 500. Otherwise we'd
        // recurse forever when the hook itself returns/throws an error.
        if (state.in_error_handler) {
            return response_mod.text(.internal_server_error, "Internal Server Error");
        }
        if (state.on_error_handler) |handler| {
            state.in_error_handler = true;
            defer state.in_error_handler = false;
            return handler(err, req);
        }
        if (err == error.HTTPException) {
            if (state.http_exception) |*exception| {
                return exception.getResponse(req.allocator);
            }
        }
    }

    return response_mod.text(.internal_server_error, "Internal Server Error");
}

fn wrapRouteChain(comptime middlewares: anytype, comptime final_handler: Handler) Handler {
    return struct {
        const chain_middlewares = middlewares;
        const chain_final_handler = final_handler;

        const Frame = struct {
            next_index: usize,
        };

        fn run(req: Request) Response {
            return runFrom(req, 0);
        }

        fn runFrom(req: Request, index: usize) Response {
            if (index >= chain_middlewares.len) {
                return chain_final_handler(req);
            }

            const frame = Frame{
                .next_index = index + 1,
            };
            return chain_middlewares[index](req, .{
                .ctx = &frame,
                .run_fn = runNext,
            });
        }

        fn runNext(ctx: *const anyopaque, req: Request) Response {
            const frame: *const Frame = @ptrCast(@alignCast(ctx));
            return runFrom(req, frame.next_index);
        }
    }.run;
}

fn dispatchMount(target: App.MountTarget, req: Request) Response {
    return switch (target) {
        .app => |mounted_app| mounted_app.handle(req),
        .handler => |handler| handler(req),
    };
}

fn matchMount(mounts: []const App.Mount, path: []const u8) ?MountMatch {
    var best: ?MountMatch = null;

    for (mounts) |*mount_entry| {
        const mounted_path = stripMountPrefix(path, mount_entry.prefix) orelse continue;
        if (best == null or mount_entry.prefix.len > best.?.mount.prefix.len) {
            best = .{
                .mount = mount_entry,
                .path = mounted_path,
            };
        }
    }

    return best;
}

fn stripMountPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "/")) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return "/";
    if (path[prefix.len] != '/') return null;
    return path[prefix.len..];
}

fn isStringLike(comptime T: type) bool {
    return core_meta.isStringLike(T);
}

fn isMiddlewareOnly(comptime target: anytype) bool {
    return isMiddlewareOnlyType(@TypeOf(target));
}

fn isMiddlewareOnlyType(comptime T: type) bool {
    if (T == App.DispatchMiddleware) return true;

    return switch (@typeInfo(T)) {
        .@"fn" => isMiddlewareFnType(T),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => isMiddlewareFnType(pointer.child),
            else => false,
        },
        .@"struct" => |info| blk: {
            if (!info.is_tuple) break :blk false;
            const fields = std.meta.fields(T);
            if (fields.len == 0) break :blk false;
            inline for (fields) |field| {
                if (!isMiddlewareOnlyType(field.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isMiddlewareFnType(comptime FnType: type) bool {
    const info = @typeInfo(FnType).@"fn";
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) return false;
    if (info.params[0].type.? != *Context or info.params[1].type.? != Context.Next) return false;

    const ReturnType = info.return_type orelse return false;
    if (ReturnType == Response) return true;
    return switch (@typeInfo(ReturnType)) {
        .error_union => |error_union| error_union.payload == Response,
        else => false,
    };
}

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    if (http_names.isContentType(name)) return res.content_type;
    if (http_names.isLocation(name)) return res.location;
    if (http_names.isAllow(name)) return res.allow;

    for (res.extraHeaders()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }

    return null;
}

test "app dispatches through finalized router" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "app redirects trailing slash misses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/health/"));
    try std.testing.expectEqual(std.http.Status.moved_permanently, res.status);
    try std.testing.expectEqualStrings("/health", res.location.?);

    const head_res = app.handle(Request.init(arena.allocator(), .HEAD, "/health/"));
    try std.testing.expectEqual(std.http.Status.moved_permanently, head_res.status);
    try std.testing.expectEqualStrings("/health", head_res.location.?);
}

test "app automatically answers OPTIONS and 405" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/users", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const options_res = app.handle(Request.init(arena.allocator(), .OPTIONS, "/users"));
    try std.testing.expectEqual(std.http.Status.no_content, options_res.status);
    try std.testing.expectEqualStrings("GET, HEAD, OPTIONS", options_res.allow.?);

    const post_res = app.handle(Request.init(arena.allocator(), .POST, "/users"));
    try std.testing.expectEqual(std.http.Status.method_not_allowed, post_res.status);
    try std.testing.expectEqualStrings("GET, HEAD, OPTIONS", post_res.allow.?);
}

test "app falls back HEAD to GET route and suppresses materialized body" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            _ = c.header("x-handler-method", c.req.methodName());
            return c.text("healthy");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/health", .{ .method = .HEAD });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("", res.bodyBytes());
    try std.testing.expectEqualStrings("HEAD", res.headerValue("x-handler-method").?);
}

test "HEAD fallback uses HEAD-scoped middleware instead of GET-scoped middleware" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.useOn(.GET, "/health", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-get-middleware", "1");
            return c.takeResponse();
        }
    }.run);
    try app.useOn(.HEAD, "/health", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-head-middleware", "1");
            return c.takeResponse();
        }
    }.run);
    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("healthy");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/health", .{ .method = .HEAD });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqual(null, res.headerValue("x-get-middleware"));
    try std.testing.expectEqualStrings("1", res.headerValue("x-head-middleware").?);
}

test "app uses explicit HEAD route before GET fallback" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/resource", struct {
        fn run(c: *Context) Response {
            return c.text("get");
        }
    }.run);
    try app.head("/resource", struct {
        fn run(c: *Context) Response {
            _ = c.header("x-explicit-head", "1");
            return c.text("head");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/resource", .{ .method = .HEAD });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("", res.bodyBytes());
    try std.testing.expectEqualStrings("1", res.headerValue("x-explicit-head").?);
}

test "app strict false treats trailing slash variants as the same route" {
    var app = App.initWithOptions(std.testing.allocator, .{
        .strict = false,
    });
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/health/", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.path);
        }
    }.run);

    const no_slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, no_slash_res.status);
    try std.testing.expectEqualStrings("/health", no_slash_res.bodyBytes());

    const slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health/"));
    try std.testing.expectEqual(std.http.Status.ok, slash_res.status);
    try std.testing.expectEqualStrings("/health/", slash_res.bodyBytes());
}

test "app basePath and route compose prefixed sub-apps" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var users = App.init(std.testing.allocator);
    defer users.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.basePath("/api/");
    try users.get("/", struct {
        fn list(c: *Context) Response {
            return c.text("users");
        }
    }.list);
    try users.get("/:id", struct {
        fn detail(c: *Context) Response {
            return c.text(c.req.param("id") orelse "missing");
        }
    }.detail);
    try app.route("/users/", &users);

    const list_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users"));
    try std.testing.expectEqualStrings("users", list_res.bodyBytes());

    const detail_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users/42"));
    try std.testing.expectEqualStrings("42", detail_res.bodyBytes());
}

test "app use wraps downstream responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-middleware", "yes");
            return c.takeResponse();
        }
    }.run);
    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("yes", responseHeaderValue(res, "x-middleware").?);
}

test "app middleware owned headers stay valid for stream responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) !Response {
            try c.cookie("sid", "abc", .{});
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/stream", struct {
        fn run(c: *Context) Response {
            return c.streamText(struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("ok");
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/stream", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("ok", res.bodyBytes());
    try std.testing.expectEqualStrings("sid=abc", responseHeaderValue(res, "set-cookie").?);
}

test "app useAt applies middleware to matching prefixes only" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.useAt("/admin", struct {
        fn run(c: *Context, next: Context.Next) Response {
            if (!std.mem.eql(u8, c.req.header("x-admin") orelse "", "1")) {
                return c.text(.{ "denied", .unauthorized });
            }
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/admin/panel", struct {
        fn run(c: *Context) Response {
            return c.text("secret");
        }
    }.run);
    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const denied = app.handle(Request.init(arena.allocator(), .GET, "/admin/panel"));
    try std.testing.expectEqual(std.http.Status.unauthorized, denied.status);
    try std.testing.expectEqualStrings("denied", denied.bodyBytes());

    const public = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, public.status);
    try std.testing.expectEqualStrings("ok", public.bodyBytes());
}

test "app context middleware can set values for context handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.set("message", "hello from context") catch return response_mod.internalError("set failed");
            c.set("status_code", std.http.Status.accepted) catch return response_mod.internalError("set failed");
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx", struct {
        fn run(c: *Context) Response {
            const message = c.get([]const u8, "message") orelse return response_mod.internalError("missing message");
            const status_code = c.get(std.http.Status, "status_code") orelse return response_mod.internalError("missing status");
            c.status(status_code);
            return c.text(message);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx"));
    try std.testing.expectEqual(std.http.Status.accepted, res.status);
    try std.testing.expectEqualStrings("hello from context", res.bodyBytes());
}

test "app onError handles context handler errors" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            c.status(if (err == error.Forbidden) .forbidden else .internal_server_error);
            _ = c.header("x-error", @errorName(err));
            return c.text(c.req.path);
        }
    }.run);
    try app.get("/ctx-boom", struct {
        fn run(c: *Context) !Response {
            _ = c.header("x-before", "1");
            return error.Forbidden;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-boom"));
    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
    try std.testing.expectEqualStrings("/ctx-boom", res.bodyBytes());
    try std.testing.expectEqualStrings("Forbidden", responseHeaderValue(res, "x-error").?);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-before").?);
}

test "app context middleware can inspect c.err after next.run" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            c.status(.bad_request);
            return c.text(@errorName(err));
        }
    }.run);
    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            if (c.err != null) {
                _ = c.header("x-error-seen", "1");
            }
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx-error", struct {
        fn run(_: *Context) !Response {
            return error.Boom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-error"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("Boom", res.bodyBytes());
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-error-seen").?);
}

test "app route tuples support context middleware and handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/tuple-ctx", .{
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                c.set("message", "from tuple") catch return response_mod.internalError("set failed");
                next.run();
                _ = c.header("x-context-route", "1");
                return c.takeResponse();
            }
        }.run,
        struct {
            fn run(c: *Context) Response {
                return c.text(c.vars.get([]const u8, "message") orelse "missing");
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/tuple-ctx"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("from tuple", res.bodyBytes());
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-context-route").?);
}

test "app mount delegates prefixed requests to mounted apps" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var mounted = App.init(std.testing.allocator);
    defer mounted.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mounted.get("/", struct {
        fn root(c: *Context) Response {
            return c.text("mounted root");
        }
    }.root);
    try mounted.get("/hello", struct {
        fn hello(c: *Context) Response {
            return c.text("mounted hello");
        }
    }.hello);
    try app.mount("/nested", &mounted);

    const root_res = app.handle(Request.init(arena.allocator(), .GET, "/nested"));
    try std.testing.expectEqual(std.http.Status.ok, root_res.status);
    try std.testing.expectEqualStrings("mounted root", root_res.bodyBytes());

    const hello_res = app.handle(Request.init(arena.allocator(), .GET, "/nested/hello"));
    try std.testing.expectEqual(std.http.Status.ok, hello_res.status);
    try std.testing.expectEqualStrings("mounted hello", hello_res.bodyBytes());
}

test "app on registers multiple methods and paths" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.on(.{ .PUT, .DELETE }, .{ "/posts", "/authors" }, struct {
        fn run(c: *Context) Response {
            return c.text("multi");
        }
    }.run);

    const put_res = app.handle(Request.init(arena.allocator(), .PUT, "/posts"));
    const delete_res = app.handle(Request.init(arena.allocator(), .DELETE, "/authors"));
    try std.testing.expectEqualStrings("multi", put_res.bodyBytes());
    try std.testing.expectEqualStrings("multi", delete_res.bodyBytes());
}

test "app on registers custom method names" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.on("PURGE", "/cache", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.methodName());
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/cache", .{ .method_name = "PURGE" });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("PURGE", res.bodyBytes());
}

test "fixed path redirect uses custom method names" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.addCustomRoute("PURGE", "/Cache", struct {
        fn run(c: *Context) Response {
            return c.text("purged");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/cache", .{ .method_name = "PURGE" });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.permanent_redirect, res.status);
    try std.testing.expectEqualStrings("/Cache", res.location.?);
}

test "context exposes route path and base path" {
    var api = App.init(std.testing.allocator);
    defer api.deinit();
    try api.basePath("/v1");
    try api.get("/posts/:id", struct {
        fn run(c: *Context) Response {
            return c.json(.{
                .route = c.routePath() orelse "",
                .base = c.basePath() orelse "",
            });
        }
    }.run);

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.basePath("/api");
    try app.route("/", &api);

    var res = try app.request(std.testing.allocator, "/api/v1/posts/42", .{});
    defer res.deinit();

    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"route\":\"/api/v1/posts/:id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.bodyBytes(), "\"base\":\"/api/v1\"") != null);
}

test "app get_path option can override request path" {
    var app = App.initWithOptions(std.testing.allocator, .{
        .get_path = struct {
            fn run(req: *const Request) []const u8 {
                return req.header("x-zono-path") orelse req.path;
            }
        }.run,
    });
    defer app.deinit();

    try app.get("/internal", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/", .{
        .headers = &.{
            .{ .name = "x-zono-path", .value = "/internal" },
        },
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "context exposes raw and env pointers" {
    const Raw = struct { value: []const u8 };
    const Env = struct { value: []const u8 };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/raw", struct {
        fn run(c: *Context) Response {
            const raw = c.raw(Raw) orelse return c.text("missing-raw");
            const env = c.env(Env) orelse return c.text("missing-env");
            if (!std.mem.eql(u8, env.value, "env")) return c.text("bad-env");
            return c.text(raw.value);
        }
    }.run);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = Raw{ .value = "raw" };
    var env = Env{ .value = "env" };
    var req = Request.init(arena.allocator(), .GET, "/raw");
    req.raw_ctx = @ptrCast(&raw);
    req.env_ctx = @ptrCast(&env);

    const res = app.handle(req);
    try std.testing.expectEqualStrings("raw", res.bodyBytes());
}

test "context executionCtx waitUntil runs after handler" {
    const State = struct {
        var ran: bool = false;

        fn mark(ctx: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
    };

    State.ran = false;
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/wait", struct {
        fn run(c: *Context) Response {
            c.waitUntil(.{
                .ctx = @ptrCast(&State.ran),
                .run_fn = State.mark,
            }) catch return response_mod.internalError("waitUntil failed");
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/wait", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("ok", res.bodyBytes());
    try std.testing.expect(State.ran);
}

test "app rejects regex-style routes in the core router" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/files/:name{.*}", struct {
        fn run(c: *Context) Response {
            return c.text("regex");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/files/readme", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try std.testing.expectEqualStrings("router init failed", res.bodyBytes());
}

test "app all registers all common methods" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.all("/echo", struct {
        fn run(c: *Context) Response {
            return c.text(@tagName(c.req.method));
        }
    }.run);

    const get_res = app.handle(Request.init(arena.allocator(), .GET, "/echo"));
    const trace_res = app.handle(Request.init(arena.allocator(), .TRACE, "/echo"));

    try std.testing.expectEqualStrings("GET", get_res.bodyBytes());
    try std.testing.expectEqualStrings("TRACE", trace_res.bodyBytes());
}

test "app custom notFound handler accepts context handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.notFound(struct {
        fn run(c: *Context) Response {
            c.status(.not_found);
            _ = c.header("x-miss", "1");
            return c.text(c.req.path);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/missing"));
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqualStrings("/missing", res.bodyBytes());
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-miss").?);
}

test "app request helper dispatches with query headers and body" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.post("/search", struct {
        fn run(c: *Context) Response {
            if (!std.mem.eql(u8, c.req.query("q") orelse "", "zig")) return c.text(.{ "bad query", .bad_request });
            if (!std.mem.eql(u8, c.req.header("x-mode") orelse "", "test")) return c.text(.{ "bad header", .bad_request });
            if (!std.mem.eql(u8, c.req.text(), "payload")) return c.text(.{ "bad body", .bad_request });
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{
        .method = .POST,
        .headers = &.{.{ .name = "x-mode", .value = "test" }},
        .body = "payload",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "HTTPException produces default error responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/private", struct {
        fn run(c: *Context) !Response {
            return HTTPException.init(.unauthorized, .{ .message = "Unauthorized" }).raise(c);
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/private", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.unauthorized, res.status);
    try std.testing.expectEqualStrings("Unauthorized", res.bodyBytes());
}

test "onError can inspect HTTPException like Hono" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.onError(struct {
        fn run(_: anyerror, c: *Context) Response {
            if (c.httpException()) |exception| {
                var response = exception.getResponse(c.req.allocator);
                _ = response.header("x-error-kind", "http");
                return response;
            }
            return c.text(.{ "Internal Server Error", .internal_server_error });
        }
    }.run);

    try app.get("/private", struct {
        fn run(c: *Context) !Response {
            return HTTPException.init(.forbidden, .{ .message = "Forbidden" }).raise(c);
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/private", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
    try std.testing.expectEqualStrings("Forbidden", res.bodyBytes());
    try std.testing.expectEqualStrings("http", responseHeaderValue(res, "x-error-kind").?);
}

test "app request helper accepts absolute urls" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/hello", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.query("name") orelse "missing");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "https://example.com/hello?name=zono", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("zono", res.bodyBytes());
}

test "app request target splitter keeps embedded scheme in origin-form paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const split = try request_target.splitAlloc(arena.allocator(), "/proxy/http://example.com/file?x=1");
    try std.testing.expectEqualStrings("/proxy/http://example.com/file", split.path);
    try std.testing.expectEqualStrings("x=1", split.query_string);
}

test "app request helper accepts zono request values" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.post("/submit", struct {
        fn run(c: *Context) Response {
            if (!std.mem.eql(u8, c.req.query("draft") orelse "", "1")) return c.text(.{ "bad query", .bad_request });
            return c.text(.{ c.req.text(), .created });
        }
    }.run);

    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.query_string = "draft=1";
    req.body_bytes = "payload";

    var res = try app.request(std.testing.allocator, req, .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("payload", res.bodyBytes());
}

test "app request helper rejects websocket upgrade responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return c.upgradeWebSocket(struct {
                fn socket(_: *response_mod.WebSocketConnection) !void {}
            }.socket, .{});
        }
    }.run);

    try std.testing.expectError(error.UnsupportedRuntimeClone, app.request(std.testing.allocator, "/ws", .{
        .headers = &.{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "connection", .value = "Upgrade" },
            .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
            .{ .name = "sec-websocket-version", .value = "13" },
        },
    }));
}

test "app request helper renders chunked stream handler into buffered body" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/stream", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("hello ");
                    try w.writeAll("world");
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/stream", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("text/plain", res.content_type);
    try std.testing.expectEqualStrings("hello world", res.bodyBytes());
    try std.testing.expect(res.body_kind == .buffered);
}

test "app request helper renders streamText alias" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/stream-text", struct {
        fn run(c: *Context) Response {
            return c.streamText(struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("plain");
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/stream-text", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("plain", res.bodyBytes());
}

test "app request helper carries conn info" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/conn", struct {
        fn run(c: *Context) Response {
            const info = c.connInfo();
            if (info.remote == null or info.local == null) return c.text("missing");
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/conn", .{
        .conn_info = .{
            .remote = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 1234),
            .local = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080),
        },
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

test "app request helper supports content-length stream variant" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/sized", struct {
        fn run(c: *Context) Response {
            return c.stream("application/octet-stream", struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("12345");
                }
            }.write, .{ .content_length = 5 });
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/sized", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("12345", res.bodyBytes());
}

test "app request helper renders sse handler with multi-line data" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/events", struct {
        fn run(c: *Context) Response {
            return c.sse(struct {
                fn write(w: *response_mod.SseWriter) !void {
                    try w.send(.{ .event = "tick", .id = "1", .data = "first" });
                    try w.send(.{ .data = "line1\nline2" });
                }
            }.write);
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/events", .{});
    defer res.deinit();

    try std.testing.expect(std.mem.startsWith(u8, res.content_type, "text/event-stream"));

    var saw_cache_header = false;
    var saw_accel_header = false;
    for (res.extraHeaders()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cache-control") and
            std.mem.eql(u8, h.value, "no-cache")) saw_cache_header = true;
        if (std.ascii.eqlIgnoreCase(h.name, "x-accel-buffering") and
            std.mem.eql(u8, h.value, "no")) saw_accel_header = true;
    }
    try std.testing.expect(saw_cache_header);
    try std.testing.expect(saw_accel_header);

    const expected =
        "id: 1\nevent: tick\ndata: first\n\n" ++
        "data: line1\ndata: line2\n\n";
    try std.testing.expectEqualStrings(expected, res.bodyBytes());
}

test "app request helper passes context to two-arg stream handler" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/greet/:name", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const name = ctx.req.param("name") orelse "world";
                    try w.print("hi {s}", .{name});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/greet/zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("hi zig", res.bodyBytes());
}

test "app fetch aliases handle" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.fetch(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.bodyBytes());
}

// Regression: prior to the StreamingScope refactor, a streaming handler's
// captured Context was a detached snapshot - values written via
// `c.set` in outer middleware were invisible inside the streaming
// callback (the API silently lied). With heap-allocated context state
// transferred to the response on streaming, the inner callback now sees
// the same SharedState as the outer middleware that ran it.
test "streaming with_context inherits outer middleware shared state" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.set("user", @as([]const u8, "alice")) catch
                return response_mod.internalError("set failed");
            next.run();
            return c.takeResponse();
        }
    }.run);

    try app.get("/who", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const user = ctx.get([]const u8, "user") orelse "anonymous";
                    try w.print("hello {s}", .{user});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/who", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("hello alice", res.bodyBytes());
}

// Regression: route params previously had to be duped inside the stream
// adapter because the router freed `params_storage` after the outer
// handler returned. With StreamingScope owning a duped copy installed on
// `req.params` from the start, params remain valid during streaming
// without per-adapter dupe logic.
test "streaming with_context can read route params after outer return" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/items/:id", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const id = ctx.req.param("id") orelse "?";
                    try w.print("item={s}", .{id});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/items/42", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("item=42", res.bodyBytes());
}

test "app onError reentry guard prevents recursion when hook itself errors" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Hook itself returns an error. The reentry guard must catch the second
    // dispatch and serve the static 500 instead of looping forever.
    try app.onError(struct {
        fn run(_: anyerror, _: *Context) !Response {
            return error.HookExploded;
        }
    }.run);
    try app.get("/boom", struct {
        fn run(_: *Context) !Response {
            return error.OriginalBoom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/boom"));
    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try std.testing.expectEqualStrings("Internal Server Error", res.bodyBytes());
}

test "app onError accepts the error-returning context signature" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.onError(struct {
        fn run(err: anyerror, c: *Context) !Response {
            c.status(.bad_gateway);
            return c.text(@errorName(err));
        }
    }.run);
    try app.get("/err-ctx", struct {
        fn run(_: *Context) !Response {
            return error.GatewayDown;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/err-ctx"));
    try std.testing.expectEqual(std.http.Status.bad_gateway, res.status);
    try std.testing.expectEqualStrings("GatewayDown", res.bodyBytes());
}

test "app use accepts Hono-style tuple inputs" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(.{struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-global", "1");
            return c.takeResponse();
        }
    }.run});
    try app.use(.{
        "/api",
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                next.run();
                _ = c.header("x-api-a", "1");
                return c.takeResponse();
            }
        }.run,
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                next.run();
                _ = c.header("x-api-b", "1");
                return c.takeResponse();
            }
        }.run,
    });
    try app.get("/api/ok", struct {
        fn run(c: *Context) Response {
            return c.text("api");
        }
    }.run);
    try app.get("/public", struct {
        fn run(c: *Context) Response {
            return c.text("public");
        }
    }.run);

    var api_res = try app.request(std.testing.allocator, "/api/ok", .{});
    defer api_res.deinit();
    try std.testing.expectEqualStrings("api", api_res.bodyBytes());
    try std.testing.expectEqualStrings("1", api_res.headerValue("x-global").?);
    try std.testing.expectEqualStrings("1", api_res.headerValue("x-api-a").?);
    try std.testing.expectEqualStrings("1", api_res.headerValue("x-api-b").?);

    var public_res = try app.request(std.testing.allocator, "/public", .{});
    defer public_res.deinit();
    try std.testing.expectEqualStrings("public", public_res.bodyBytes());
    try std.testing.expectEqualStrings("1", public_res.headerValue("x-global").?);
    try std.testing.expectEqual(null, public_res.headerValue("x-api-a"));
}

test "app method routes accept middleware-only handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.post("/api/*", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-post-only", "1");
            return c.takeResponse();
        }
    }.run);
    try app.get("/api/items", struct {
        fn run(c: *Context) Response {
            return c.text("get");
        }
    }.run);
    try app.post("/api/items", struct {
        fn run(c: *Context) Response {
            return c.text("post");
        }
    }.run);

    var get_res = try app.request(std.testing.allocator, "/api/items", .{});
    defer get_res.deinit();
    var post_res = try app.request(std.testing.allocator, "/api/items", .{ .method = .POST });
    defer post_res.deinit();

    try std.testing.expectEqualStrings("get", get_res.bodyBytes());
    try std.testing.expectEqual(null, get_res.headerValue("x-post-only"));
    try std.testing.expectEqualStrings("post", post_res.bodyBytes());
    try std.testing.expectEqualStrings("1", post_res.headerValue("x-post-only").?);
}

test "app useOn registers method-scoped middleware for multiple paths" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.useOn(.{ .GET, .POST }, .{ "/admin", "/api/*" }, struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-scoped", c.req.methodName());
            return c.takeResponse();
        }
    }.run);
    try app.get("/admin", struct {
        fn run(c: *Context) Response {
            return c.text("admin");
        }
    }.run);
    try app.post("/api/users", struct {
        fn run(c: *Context) Response {
            return c.text("users");
        }
    }.run);
    try app.delete("/api/users", struct {
        fn run(c: *Context) Response {
            return c.text("delete");
        }
    }.run);

    var admin = try app.request(std.testing.allocator, "/admin", .{});
    defer admin.deinit();
    var users = try app.request(std.testing.allocator, "/api/users", .{ .method = .POST });
    defer users.deinit();
    var deleted = try app.request(std.testing.allocator, "/api/users", .{ .method = .DELETE });
    defer deleted.deinit();

    try std.testing.expectEqualStrings("GET", admin.headerValue("x-scoped").?);
    try std.testing.expectEqualStrings("POST", users.headerValue("x-scoped").?);
    try std.testing.expectEqual(null, deleted.headerValue("x-scoped"));
}

test "app middleware method index keeps registration order" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.useOn(.POST, "/api/*", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.useAt("/api", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            return c.takeResponse();
        }
    }.run);

    try app.finalize();

    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, app.middleware_index.candidatesFor("GET"));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, app.middleware_index.candidatesFor("POST"));
}

test "app middleware method index supports custom methods" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.addCustomMethodMiddleware("REPORT", "/reports", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-report", "1");
            return c.takeResponse();
        }
    }.run);
    try app.addCustomRoute("REPORT", "/reports", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/reports", .{ .method_name = "REPORT" });
    defer res.deinit();

    try std.testing.expectEqualStrings("ok", res.bodyBytes());
    try std.testing.expectEqualStrings("1", res.headerValue("x-report").?);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, app.middleware_index.candidatesFor("REPORT"));
}

test "app hooks are frozen after finalize" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.finalize();

    try std.testing.expectError(error.AppFinalized, app.notFound(struct {
        fn run(c: *Context) Response {
            return c.text("missing");
        }
    }.run));

    try std.testing.expectError(error.AppFinalized, app.onError(struct {
        fn run(_: anyerror, c: *Context) Response {
            return c.text("boom");
        }
    }.run));
}

test "app ws registers a first-class websocket route" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.wsWithOptions("/ws", struct {
        fn onOpen(_: *response_mod.WebSocketConnection) void {}
    }, .{ .protocol = "chat" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
        .{ .name = "sec-websocket-protocol", .value = "chat" },
    };

    var res = app.handle(req);
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    switch (res.runtime) {
        .websocket => |runtime| try std.testing.expectEqualStrings("chat", runtime.protocol.?),
        else => return error.ExpectedWebSocketRuntime,
    }
}

test "context response helpers accept Hono-style response options" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/text", struct {
        fn run(c: *Context) Response {
            const headers = &[_]std.http.Header{
                .{ .name = "x-text", .value = "1" },
            };
            return c.text(.{ "created", 201, headers });
        }
    }.run);
    try app.get("/html", struct {
        fn run(c: *Context) Response {
            const headers = &[_]std.http.Header{
                .{ .name = "x-html", .value = "1" },
            };
            return c.html(.{
                .content = "<b>ok</b>",
                .status = .accepted,
                .headers = headers,
            });
        }
    }.run);
    try app.get("/json", struct {
        fn run(c: *Context) Response {
            const headers = &[_]std.http.Header{
                .{ .name = "x-json", .value = "1" },
            };
            return c.json(.{ .{ .ok = true }, .created, headers });
        }
    }.run);
    try app.get("/body", struct {
        fn run(c: *Context) Response {
            const headers = &[_]std.http.Header{
                .{ .name = "x-body", .value = "1" },
            };
            return c.body(.{ "raw", .accepted, "application/custom", headers });
        }
    }.run);
    try app.get("/body-struct", struct {
        fn run(c: *Context) Response {
            return c.body(.{
                .content = "struct-body",
                .content_type = "application/zono",
                .status = 202,
            });
        }
    }.run);

    var text_res = try app.request(std.testing.allocator, "/text", .{});
    defer text_res.deinit();
    try std.testing.expectEqual(std.http.Status.created, text_res.status);
    try std.testing.expectEqualStrings("created", text_res.bodyBytes());
    try std.testing.expectEqualStrings("1", text_res.headerValue("x-text").?);

    var html_res = try app.request(std.testing.allocator, "/html", .{});
    defer html_res.deinit();
    try std.testing.expectEqual(std.http.Status.accepted, html_res.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", html_res.content_type);
    try std.testing.expectEqualStrings("1", html_res.headerValue("x-html").?);

    var json_res = try app.request(std.testing.allocator, "/json", .{});
    defer json_res.deinit();
    try std.testing.expectEqual(std.http.Status.created, json_res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", json_res.content_type);
    try std.testing.expectEqualStrings("1", json_res.headerValue("x-json").?);
    try std.testing.expect(std.mem.indexOf(u8, json_res.bodyBytes(), "\"ok\":true") != null);

    var body_res = try app.request(std.testing.allocator, "/body", .{});
    defer body_res.deinit();
    try std.testing.expectEqual(std.http.Status.accepted, body_res.status);
    try std.testing.expectEqualStrings("application/custom", body_res.content_type);
    try std.testing.expectEqualStrings("raw", body_res.bodyBytes());
    try std.testing.expectEqualStrings("1", body_res.headerValue("x-body").?);

    var body_struct_res = try app.request(std.testing.allocator, "/body-struct", .{});
    defer body_struct_res.deinit();
    try std.testing.expectEqual(std.http.Status.accepted, body_struct_res.status);
    try std.testing.expectEqualStrings("application/zono", body_struct_res.content_type);
    try std.testing.expectEqualStrings("struct-body", body_struct_res.bodyBytes());
}

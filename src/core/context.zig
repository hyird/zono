const std = @import("std");
const request_mod = @import("../request/request.zig");
const Request = request_mod.Request;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const http_exception_mod = @import("http_exception.zig");
const app_error_mod = @import("app_error.zig");
const core_meta = @import("meta.zig");
const http_names = @import("http_names.zig");
const Handler = @import("../router/router.zig").Handler;
const time = @import("time.zig");
const websocket_mod = @import("../websocket/websocket.zig");

pub const Renderer = *const fn (c: *Context, content: []const u8) Response;

pub const ResponseOptions = struct {
    status: ?std.http.Status = null,
    headers: []const std.http.Header = &.{},
    content_type: ?[]const u8 = null,
};

const VariableEntry = struct {
    value: *anyopaque,
    type_name: []const u8,
    deinit_fn: *const fn (allocator: std.mem.Allocator, value: *anyopaque) void,
};

pub const WaitUntilTask = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque) void,
    deinit_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn run(self: WaitUntilTask) void {
        self.run_fn(self.ctx);
        if (self.deinit_fn) |deinit_fn| deinit_fn(self.ctx);
    }
};

pub const ExecutionContext = struct {
    state: *SharedState,

    pub fn waitUntil(self: ExecutionContext, task: WaitUntilTask) std.mem.Allocator.Error!void {
        try self.state.wait_until_tasks.append(self.state.allocator, task);
    }
};

pub const SharedState = struct {
    allocator: std.mem.Allocator,
    response: Response = .{
        .status = .ok,
        .content_type = "",
    },
    variables: std.StringHashMapUnmanaged(VariableEntry) = .empty,
    not_found_handler: ?Handler = null,
    on_error_handler: ?*const fn (err: anyerror, req: Request) Response = null,
    error_registry: ?*const app_error_mod.Registry = null,
    renderer: ?Renderer = null,
    last_error: ?anyerror = null,
    http_exception: ?http_exception_mod.HTTPException = null,
    deadline_ns: ?u64 = null,
    wait_until_tasks: std.ArrayListUnmanaged(WaitUntilTask) = .empty,
    /// Reentry guard for `App.onError`: when an error handler itself fails or
    /// throws, we must not re-invoke the user hook (infinite recursion). The
    /// dispatch site sets this to `true` for the duration of the user
    /// handler call and clears it after; nested errors fall through to the
    /// static `Internal Server Error` 500.
    in_error_handler: bool = false,

    pub fn init(allocator: std.mem.Allocator) SharedState {
        return .{
            .allocator = allocator,
            .response = .{
                .status = .ok,
                .content_type = "",
                .header_allocator = allocator,
            },
        };
    }

    pub fn deinit(self: *SharedState) void {
        self.response.deinit();
        deinitVariableMap(self.allocator, &self.variables);
        self.clearWaitUntilTasks();
        if (self.http_exception) |*exception| exception.deinit();
    }

    pub fn set(self: *SharedState, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        try putVariableValue(self.allocator, &self.variables, key, value);
    }

    pub fn get(self: *const SharedState, comptime T: type, key: []const u8) ?T {
        return getVariableValue(&self.variables, T, key);
    }

    pub fn contains(self: *const SharedState, key: []const u8) bool {
        return self.variables.contains(key);
    }

    pub fn setHTTPException(self: *SharedState, exception: http_exception_mod.HTTPException) void {
        if (self.http_exception) |*existing| existing.deinit();
        self.http_exception = exception;
        self.last_error = error.HTTPException;
    }

    pub fn runWaitUntilTasks(self: *SharedState) void {
        var tasks = self.wait_until_tasks;
        self.wait_until_tasks = .empty;
        defer tasks.deinit(self.allocator);
        for (tasks.items) |task| task.run();
    }

    fn clearWaitUntilTasks(self: *SharedState) void {
        for (self.wait_until_tasks.items) |task| {
            if (task.deinit_fn) |deinit_fn| deinit_fn(task.ctx);
        }
        self.wait_until_tasks.deinit(self.allocator);
        self.wait_until_tasks = .empty;
    }
};

pub const Context = struct {
    pub const Var = struct {
        state: *const SharedState,

        pub fn get(self: Var, comptime T: type, key: []const u8) ?T {
            return self.state.get(T, key);
        }

        pub fn contains(self: Var, key: []const u8) bool {
            return self.state.contains(key);
        }
    };

    pub const Next = struct {
        ctx: *Context,
        next_ctx: *const anyopaque,
        run_fn: *const fn (next_ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: Next) void {
            self.ctx.mergeResponse(self.run_fn(self.next_ctx, self.ctx.req));
            self.ctx.err = self.ctx.state.last_error;
        }
    };

    req: Request,
    res: *Response,
    state: *SharedState,
    vars: Var,
    err: ?anyerror = null,

    pub fn init(req: Request) Context {
        const raw_state = req.contextState() orelse @panic("Context requires a request with initialized context state.");
        const state: *SharedState = @ptrCast(@alignCast(raw_state));
        return .{
            .req = req,
            .res = &state.response,
            .state = state,
            .vars = .{ .state = state },
            .err = state.last_error,
        };
    }

    pub fn status(self: *Context, value: std.http.Status) void {
        self.res.setStatus(value);
    }

    /// Returns the live `std.Io` handle bound to the server that is servicing
    /// this request. `null` in unit-test paths that go through `App.handle`
    /// directly without booting a `Server`. Handlers that need to do real
    /// I/O (open files, outbound client calls, sleep, etc.) should use this
    /// instead of spinning up their own runtime, which would escape the
    /// server's scheduling and cancellation.
    pub fn io(self: *Context) ?std.Io {
        return self.req.server_io;
    }

    pub fn executionCtx(self: *Context) ExecutionContext {
        return .{ .state = self.state };
    }

    pub fn waitUntil(self: *Context, task: WaitUntilTask) std.mem.Allocator.Error!void {
        try self.executionCtx().waitUntil(task);
    }

    pub fn setDeadlineNanoseconds(self: *Context, deadline_ns: ?u64) void {
        self.state.deadline_ns = deadline_ns;
    }

    pub fn deadlineExceeded(self: *const Context) bool {
        const now = time.nowNanoseconds();
        if (self.req.deadline_ns) |deadline_ns| {
            if (now >= deadline_ns) return true;
        }
        if (self.state.deadline_ns) |deadline_ns| {
            if (now >= deadline_ns) return true;
        }
        return false;
    }

    pub fn isAborted(self: *const Context) bool {
        return self.req.isAborted() or self.deadlineExceeded();
    }

    pub fn abort(self: *Context) void {
        self.req.abort();
    }

    pub fn header(self: *Context, name: []const u8, value: []const u8) bool {
        return self.res.header(name, value);
    }

    pub fn deleteHeader(self: *Context, name: []const u8) bool {
        return self.res.deleteHeader(name);
    }

    pub fn set(self: *Context, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        try self.state.set(key, value);
    }

    pub fn get(self: *Context, comptime T: type, key: []const u8) ?T {
        return self.state.get(T, key);
    }

    pub fn setHTTPException(self: *Context, exception: http_exception_mod.HTTPException) void {
        self.state.setHTTPException(exception);
        self.err = error.HTTPException;
    }

    pub fn httpException(self: *const Context) ?*const http_exception_mod.HTTPException {
        return if (self.state.http_exception) |*exception| exception else null;
    }

    pub fn appError(self: *const Context, err: anyerror) ?app_error_mod.Def {
        if (self.state.error_registry) |registry| {
            if (registry.lookup(err)) |def| return def;
        }
        return app_error_mod.defaultDef(err);
    }

    pub fn errorDetail(self: *const Context, err: anyerror) ?app_error_mod.Detail {
        const registry = self.state.error_registry orelse return null;
        return registry.detail(err);
    }

    pub fn routePath(self: *const Context) ?[]const u8 {
        return self.req.routePath();
    }

    pub fn basePath(self: *const Context) ?[]const u8 {
        return self.req.basePath();
    }

    pub fn baseRoutePath(self: *const Context) ?[]const u8 {
        return self.req.baseRoutePath();
    }

    pub fn errorValue(self: *const Context) ?anyerror {
        return self.err orelse self.state.last_error;
    }

    pub fn lastError(self: *const Context) ?anyerror {
        return self.errorValue();
    }

    pub fn raw(self: *const Context, comptime T: type) ?*const T {
        return self.req.raw(T);
    }

    pub fn env(self: *const Context, comptime T: type) ?*T {
        return self.req.env(T);
    }

    pub fn connInfo(self: *const Context) request_mod.ConnInfo {
        return self.req.connInfo();
    }

    pub fn target(self: *const Context, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return self.req.target(allocator);
    }

    pub fn url(self: *const Context, allocator: std.mem.Allocator, scheme_override: ?[]const u8) std.mem.Allocator.Error![]const u8 {
        return self.req.url(allocator, scheme_override);
    }

    pub fn bodyStream(self: *const Context) request_mod.BodyStream {
        return self.req.bodyStream();
    }

    pub fn bodyReader(self: *const Context) request_mod.BodyReader {
        return self.req.bodyReader();
    }

    pub fn hasStreamingBody(self: *const Context) bool {
        return self.req.hasStreamingBody();
    }

    pub fn saveBodyToFile(self: *const Context, path: []const u8, options: request_mod.SaveBodyOptions) request_mod.SaveBodyError!usize {
        return try self.req.saveBodyToFile(path, options);
    }

    pub fn cloneRawRequest(self: *const Context, allocator: std.mem.Allocator) std.mem.Allocator.Error!request_mod.RawRequest {
        return self.req.cloneRawRequest(allocator);
    }

    pub fn setRenderer(self: *Context, renderer: Renderer) void {
        self.state.renderer = renderer;
    }

    pub fn render(self: *Context, content: []const u8) Response {
        if (self.state.renderer) |renderer| return renderer(self, content);
        return self.html(content);
    }

    pub fn body(self: *Context, content_or_options: anytype) Response {
        return bodyInput(self, content_or_options);
    }

    pub fn text(self: *Context, content_or_options: anytype) Response {
        return textInput(self, content_or_options);
    }

    pub fn html(self: *Context, content_or_options: anytype) Response {
        return htmlInput(self, content_or_options);
    }

    pub fn json(self: *Context, value_or_options: anytype) Response {
        return jsonInput(self, value_or_options);
    }

    pub fn notFound(self: *Context) Response {
        const response = if (self.state.not_found_handler) |handler|
            handler(self.req)
        else
            response_mod.notFound();

        self.mergeResponse(response);
        return self.takeResponse();
    }

    pub fn redirect(self: *Context, location_or_options: anytype) Response {
        return redirectInput(self, location_or_options);
    }

    pub fn upgradeWebSocket(self: *Context, comptime handler: anytype, options: websocket_mod.WebSocketUpgradeOptions) Response {
        return websocket_mod.upgradeWebSocket(self.req, handler, options);
    }

    /// Build a streaming (chunked or content-length) response. The handler is
    /// called once headers are flushed, with a writer that surfaces aborts via
    /// `StreamWriter.isAborted()`.
    ///
    /// The `handler` may be `fn(*StreamWriter) !void` or
    /// `fn(*Context, *StreamWriter) !void`. Captures are not supported; pass
    /// state through `Context.set/get` if needed.
    pub fn stream(
        self: *Context,
        content_type: []const u8,
        comptime handler: anytype,
        options: StreamOptions,
    ) Response {
        return buildStreamResponse(self, content_type, handler, options);
    }

    pub fn streamText(
        self: *Context,
        comptime handler: anytype,
        options: StreamOptions,
    ) Response {
        return self.stream("text/plain; charset=utf-8", handler, options);
    }

    /// Build a Server-Sent Events response. Sets the appropriate
    /// `text/event-stream` content type and disables buffering caches by
    /// default.
    pub fn sse(self: *Context, comptime handler: anytype) Response {
        return buildSseResponse(self, handler);
    }

    pub fn streamSSE(self: *Context, comptime handler: anytype) Response {
        return self.sse(handler);
    }

    pub fn cookie(
        self: *Context,
        name: []const u8,
        value: []const u8,
        cookie_options: response_mod.CookieOptions,
    ) response_mod.CookieError!void {
        try self.res.cookie(self.req.allocator, name, value, cookie_options);
    }

    pub fn deleteCookie(
        self: *Context,
        name: []const u8,
        delete_options: response_mod.DeleteCookieOptions,
    ) response_mod.CookieError!void {
        try self.res.deleteCookie(self.req.allocator, name, delete_options);
    }

    pub fn takeResponse(self: *Context) Response {
        const response = self.state.response;
        self.state.response = .{
            .status = .ok,
            .content_type = "",
            .header_allocator = self.state.allocator,
        };
        self.res = &self.state.response;
        return response;
    }

    fn mergeResponse(self: *Context, response: Response) void {
        var merged = response;
        if (self.res.owned_allocator != null and merged.owned_allocator == null) {
            if (merged.clone(self.req.allocator)) |cloned| {
                var cloned_with_scopes = cloned;
                cloned_with_scopes.scopes = merged.scopes;
                merged.scopes = .{};
                merged.deinit();
                merged = cloned_with_scopes;
            } else |_| {
                merged.ensureOwned(self.req.allocator) catch return self.replaceWithMergeError(&merged);
            }
        } else if (self.res.owned_headers_allocator != null and merged.owned_allocator == null) {
            merged.ensureExtraHeadersOwned(self.req.allocator) catch return self.replaceWithMergeError(&merged);
        }
        if (merged.owned_allocator == null and merged.owned_headers_allocator == null and merged.header_allocator == null) {
            merged.header_allocator = self.req.allocator;
        }
        if (self.res.status != .ok and merged.status == .ok) {
            merged.setStatus(self.res.status);
        }
        if (self.res.content_type.len > 0 and merged.content_type.len == 0) {
            if (!merged.setContentType(self.res.content_type)) return self.replaceWithMergeError(&merged);
        }
        if (self.res.location != null and merged.location == null) {
            if (!merged.setLocation(self.res.location)) return self.replaceWithMergeError(&merged);
        }
        if (self.res.allow != null and merged.allow == null) {
            if (!merged.setAllow(self.res.allow)) return self.replaceWithMergeError(&merged);
        }
        for (self.res.extraHeaders()) |entry| {
            if (http_names.isSetCookie(entry.name)) {
                if (!merged.appendHeader(entry.name, entry.value)) return self.replaceWithMergeError(&merged);
            } else {
                if (!merged.header(entry.name, entry.value)) return self.replaceWithMergeError(&merged);
            }
        }

        self.state.response.deinit();
        self.state.response = merged;
        self.res = &self.state.response;
    }

    fn replaceWithMergeError(self: *Context, merged: *Response) void {
        merged.deinit();
        self.state.response.deinit();
        self.state.response = response_mod.internalError("response merge allocation failed");
        self.res = &self.state.response;
    }
};

pub fn streamText(c: *Context, comptime handler: anytype, options: StreamOptions) Response {
    return c.streamText(handler, options);
}

pub fn streamSSE(c: *Context, comptime handler: anytype) Response {
    return c.streamSSE(handler);
}

fn applyResponseOptions(c: *Context, response_options: ResponseOptions) bool {
    if (response_options.status) |status_code| c.status(status_code);
    for (response_options.headers) |header_entry| {
        if (!c.header(header_entry.name, header_entry.value)) return false;
    }
    return true;
}

fn sendBody(c: *Context, content: []const u8, default_content_type: []const u8, response_options: ResponseOptions) Response {
    if (canUseDirectBodyResponse(c, response_options)) {
        var response = response_mod.body(.ok, default_content_type, content);
        response.header_allocator = c.state.allocator;
        return response;
    }

    if (!applyResponseOptions(c, response_options) or
        !c.res.setContentType(response_options.content_type orelse default_content_type) or
        !c.res.setBody(content) or
        !c.res.setLocation(null) or
        !c.res.setAllow(null))
    {
        c.state.response.deinit();
        c.state.response = response_mod.internalError("response allocation failed");
        c.res = &c.state.response;
    }
    return c.takeResponse();
}

fn canUseDirectBodyResponse(c: *const Context, response_options: ResponseOptions) bool {
    return response_options.status == null and
        response_options.headers.len == 0 and
        response_options.content_type == null and
        responseIsPristine(c.res);
}

fn responseIsPristine(response: *const Response) bool {
    if (response.status != .ok) return false;
    if (response.content_type.len != 0 or response.bodyBytes().len != 0) return false;
    if (response.location != null or response.allow != null) return false;
    if (response.extraHeaders().len != 0) return false;
    if (response.owned_allocator != null or response.owned_headers_allocator != null) return false;
    if (response.runtime != .none or response.scopes.head != null) return false;
    return switch (response.body_kind) {
        .buffered => |body| body.len == 0,
        else => false,
    };
}

fn textInput(c: *Context, input: anytype) Response {
    const InputType = @TypeOf(input);
    if (comptime isStringLike(InputType)) return sendBody(c, input, "text/plain; charset=utf-8", .{});

    switch (@typeInfo(InputType)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const fields = std.meta.fields(InputType);
                if (fields.len == 0) @compileError("Context.text tuple must contain content.");
                const content = @field(input, fields[0].name);
                if (comptime !isStringLike(@TypeOf(content))) @compileError("Context.text content must be a string.");
                var response_options: ResponseOptions = .{};
                inline for (fields[1..]) |field| {
                    mergeResponseOption(&response_options, @field(input, field.name));
                }
                return sendBody(c, content, "text/plain; charset=utf-8", response_options);
            }

            if (!@hasField(InputType, "content")) {
                @compileError("Context.text accepts a string, .{ content, status?, headers? }, or .{ .content = ..., .status = ..., .headers = ... }.");
            }
            var response_options: ResponseOptions = .{};
            if (@hasField(InputType, "status")) mergeResponseOption(&response_options, input.status);
            if (@hasField(InputType, "headers")) response_options.headers = headerSlice(input.headers);
            if (@hasField(InputType, "content_type")) response_options.content_type = input.content_type;
            return sendBody(c, input.content, "text/plain; charset=utf-8", response_options);
        },
        else => @compileError("Context.text accepts a string or response options tuple/struct."),
    }
}

fn bodyInput(c: *Context, input: anytype) Response {
    const InputType = @TypeOf(input);
    if (comptime isStringLike(InputType)) return sendBody(c, input, "", .{});

    switch (@typeInfo(InputType)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const fields = std.meta.fields(InputType);
                if (fields.len == 0) @compileError("Context.body tuple must contain content.");
                const content = @field(input, fields[0].name);
                if (comptime !isStringLike(@TypeOf(content))) @compileError("Context.body content must be a string.");
                var response_options: ResponseOptions = .{};
                inline for (fields[1..]) |field| {
                    mergeResponseOption(&response_options, @field(input, field.name));
                }
                return sendBody(c, content, "", response_options);
            }

            if (!@hasField(InputType, "content")) {
                @compileError("Context.body accepts a string, .{ content, status?, headers?, content_type? }, or .{ .content = ..., .status = ..., .headers = ..., .content_type = ... }.");
            }
            var response_options: ResponseOptions = .{};
            if (@hasField(InputType, "status")) mergeResponseOption(&response_options, input.status);
            if (@hasField(InputType, "headers")) response_options.headers = headerSlice(input.headers);
            if (@hasField(InputType, "content_type")) response_options.content_type = input.content_type;
            return sendBody(c, input.content, "", response_options);
        },
        else => @compileError("Context.body accepts a string or response options tuple/struct."),
    }
}

fn htmlInput(c: *Context, input: anytype) Response {
    const InputType = @TypeOf(input);
    if (comptime isStringLike(InputType)) return sendBody(c, input, "text/html; charset=utf-8", .{});

    switch (@typeInfo(InputType)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const fields = std.meta.fields(InputType);
                if (fields.len == 0) @compileError("Context.html tuple must contain content.");
                const content = @field(input, fields[0].name);
                if (comptime !isStringLike(@TypeOf(content))) @compileError("Context.html content must be a string.");
                var response_options: ResponseOptions = .{};
                inline for (fields[1..]) |field| {
                    mergeResponseOption(&response_options, @field(input, field.name));
                }
                return sendBody(c, content, "text/html; charset=utf-8", response_options);
            }

            if (!@hasField(InputType, "content")) {
                @compileError("Context.html accepts a string, .{ content, status?, headers? }, or .{ .content = ..., .status = ..., .headers = ... }.");
            }
            var response_options: ResponseOptions = .{};
            if (@hasField(InputType, "status")) mergeResponseOption(&response_options, input.status);
            if (@hasField(InputType, "headers")) response_options.headers = headerSlice(input.headers);
            if (@hasField(InputType, "content_type")) response_options.content_type = input.content_type;
            return sendBody(c, input.content, "text/html; charset=utf-8", response_options);
        },
        else => @compileError("Context.html accepts a string or response options tuple/struct."),
    }
}

fn jsonInput(c: *Context, input: anytype) Response {
    const InputType = @TypeOf(input);

    switch (@typeInfo(InputType)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const fields = std.meta.fields(InputType);
                if (fields.len == 0) @compileError("Context.json tuple must contain a value.");
                const value = @field(input, fields[0].name);
                var response_options: ResponseOptions = .{};
                inline for (fields[1..]) |field| {
                    mergeResponseOption(&response_options, @field(input, field.name));
                }
                return jsonValue(c, value, response_options);
            }
        },
        else => {},
    }

    return jsonValue(c, input, .{});
}

fn jsonValue(c: *Context, value: anytype, response_options: ResponseOptions) Response {
    const ValueType = @TypeOf(value);
    if (comptime isStringLike(ValueType)) {
        return sendBody(c, value, "application/json; charset=utf-8", response_options);
    }

    var out: std.Io.Writer.Allocating = .init(c.req.allocator);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(value) catch return response_mod.internalError("json write failed");
    return sendBody(c, out.written(), "application/json; charset=utf-8", response_options);
}

fn redirectInput(c: *Context, input: anytype) Response {
    const InputType = @TypeOf(input);
    if (comptime isStringLike(InputType)) return sendRedirect(c, input, .found);

    switch (@typeInfo(InputType)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const fields = std.meta.fields(InputType);
                if (fields.len == 0) @compileError("Context.redirect tuple must contain a location.");
                const location = @field(input, fields[0].name);
                if (comptime !isStringLike(@TypeOf(location))) @compileError("Context.redirect location must be a string.");
                var status_code: std.http.Status = .found;
                inline for (fields[1..]) |field| {
                    status_code = redirectStatus(@field(input, field.name));
                }
                return sendRedirect(c, location, status_code);
            }

            if (!@hasField(InputType, "location")) {
                @compileError("Context.redirect accepts a string, .{ location, status? }, or .{ .location = ..., .status = ... }.");
            }
            const status_code = if (@hasField(InputType, "status")) redirectStatus(input.status) else .found;
            return sendRedirect(c, input.location, status_code);
        },
        else => @compileError("Context.redirect accepts a string or redirect options tuple/struct."),
    }
}

fn sendRedirect(c: *Context, location: []const u8, status_code: std.http.Status) Response {
    c.res.setStatus(status_code);
    _ = c.res.setContentType("");
    _ = c.res.setBody("");
    _ = c.res.setAllow(null);
    _ = c.res.setLocation(location);
    return c.takeResponse();
}

fn redirectStatus(status: anytype) std.http.Status {
    const StatusType = @TypeOf(status);
    if (comptime StatusType == std.http.Status) return status;
    if (comptime StatusType == @TypeOf(.enum_literal)) return @field(std.http.Status, @tagName(status));
    if (comptime switch (@typeInfo(StatusType)) {
        .comptime_int, .int => true,
        else => false,
    }) return @enumFromInt(status);
    @compileError("Context.redirect status must be a std.http.Status, enum literal, or integer status code.");
}

fn mergeResponseOption(response_options: *ResponseOptions, option: anytype) void {
    const OptionType = @TypeOf(option);
    if (comptime OptionType == std.http.Status) {
        response_options.status = option;
        return;
    }
    if (comptime OptionType == @TypeOf(.enum_literal)) {
        response_options.status = @field(std.http.Status, @tagName(option));
        return;
    }
    if (comptime switch (@typeInfo(OptionType)) {
        .comptime_int, .int => true,
        else => false,
    }) {
        response_options.status = @enumFromInt(option);
        return;
    }
    if (comptime OptionType == ResponseOptions) {
        if (option.status) |status_code| response_options.status = status_code;
        if (option.headers.len > 0) response_options.headers = option.headers;
        if (option.content_type) |content_type| response_options.content_type = content_type;
        return;
    }
    if (comptime isHeaderSlice(OptionType)) {
        response_options.headers = headerSlice(option);
        return;
    }
    if (comptime isStringLike(OptionType)) {
        response_options.content_type = option;
        return;
    }
    @compileError("Unsupported Context response option. Use a status, []const std.http.Header, content-type string, or zono.ResponseOptions.");
}

fn isHeaderSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == std.http.Header,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == std.http.Header,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn headerSlice(headers: anytype) []const std.http.Header {
    const HeaderType = @TypeOf(headers);
    return switch (@typeInfo(HeaderType)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => headers,
            .one => switch (@typeInfo(pointer.child)) {
                .array => headers[0..],
                else => @compileError("headers must be []const std.http.Header or &[_]std.http.Header{...}."),
            },
            else => @compileError("headers must be []const std.http.Header or &[_]std.http.Header{...}."),
        },
        else => @compileError("headers must be []const std.http.Header or &[_]std.http.Header{...}."),
    };
}

pub const StreamOptions = struct {
    /// When known, the precise body length so the response can use
    /// content-length instead of chunked encoding.
    content_length: ?u64 = null,
};

/// Heap-owned `SharedState`. Used by `App.handle` (and any wrapper that
/// is the first to introduce `SharedState`) so that streaming responses
/// can extend the state's lifetime past the wrapper's stack frame via
/// `Response.attachScope`. Single responsibility: own the `SharedState`
/// and free it (and the bookkeeping wrapper) on deinit.
pub const SharedStateScope = struct {
    allocator: std.mem.Allocator,
    state_storage: SharedState,
    state: *SharedState,

    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*SharedStateScope {
        const scope = try allocator.create(SharedStateScope);
        errdefer allocator.destroy(scope);
        scope.allocator = allocator;
        scope.state_storage = SharedState.init(allocator);
        scope.state = &scope.state_storage;
        return scope;
    }

    pub fn deinit(self: *SharedStateScope) void {
        const allocator = self.allocator;
        self.state.deinit();
        allocator.destroy(self);
    }

    pub fn deinitOpaque(scope_ptr: *anyopaque) void {
        const self: *SharedStateScope = @ptrCast(@alignCast(scope_ptr));
        self.deinit();
    }
};

/// Heap-owned `Context` plus a duped copy of route params. Borrows the
/// `SharedState` pointer (lifetime is guaranteed by either an inherited
/// outer scope or a sibling `SharedStateScope` attached to the same
/// `Response`). Created by the `wrapContext*` family on entry to each
/// context-aware handler/middleware so that streaming callbacks fired
/// after the wrapper returns still see a valid `*Context`, route params,
/// and `SharedState`.
///
/// The router's `params_storage` is freed shortly after the outer handler
/// returns, so we always dupe params even when state ownership is
/// inherited.
pub const ContextScope = struct {
    allocator: std.mem.Allocator,
    ctx_storage: Context,
    ctx: *Context,
    params: []const request_mod.Param,

    pub fn create(
        allocator: std.mem.Allocator,
        req: Request,
        state: *SharedState,
    ) std.mem.Allocator.Error!*ContextScope {
        const scope = try allocator.create(ContextScope);
        errdefer allocator.destroy(scope);

        const owned_params = if (req.params.len == 0)
            &[_]request_mod.Param{}
        else
            try allocator.dupe(request_mod.Param, req.params);
        errdefer if (owned_params.len > 0) allocator.free(owned_params);

        var scoped_req = req;
        scoped_req.params = owned_params;
        scoped_req.context_state = @ptrCast(state);

        scope.allocator = allocator;
        scope.params = owned_params;
        scope.ctx_storage = Context.init(scoped_req);
        scope.ctx = &scope.ctx_storage;
        return scope;
    }

    pub fn deinit(self: *ContextScope) void {
        const allocator = self.allocator;
        if (self.params.len > 0) allocator.free(self.params);
        allocator.destroy(self);
    }

    pub fn deinitOpaque(scope_ptr: *anyopaque) void {
        const self: *ContextScope = @ptrCast(@alignCast(scope_ptr));
        self.deinit();
    }
};

fn buildStreamResponse(
    self: *Context,
    content_type: []const u8,
    comptime handler: anytype,
    options: StreamOptions,
) Response {
    const Adapter = streamAdapter(@TypeOf(handler), handler);

    return response_mod.stream(content_type, .{
        .ctx = @ptrCast(self),
        .run_fn = Adapter.run,
        .content_length = options.content_length,
    });
}

fn buildSseResponse(self: *Context, comptime handler: anytype) Response {
    const Adapter = sseAdapter(@TypeOf(handler), handler);

    var response = response_mod.sse(.{
        .ctx = @ptrCast(self),
        .run_fn = Adapter.run,
    });
    // Disable proxy buffering (nginx etc.) so events arrive promptly.
    _ = response.appendHeader("cache-control", "no-cache");
    _ = response.appendHeader("x-accel-buffering", "no");
    return response;
}

const StreamHandlerKind = enum { writer_only, with_context };

fn classifyStreamHandler(comptime HandlerType: type, comptime SecondParam: type) StreamHandlerKind {
    const info = streamHandlerFnInfo(HandlerType);
    return switch (info.params.len) {
        1 => blk: {
            const P0 = info.params[0].type orelse @compileError("stream handler params must be concrete types");
            if (P0 != SecondParam) @compileError("single-arg stream handler must take *StreamWriter or *SseWriter");
            break :blk .writer_only;
        },
        2 => blk: {
            const P0 = info.params[0].type orelse @compileError("stream handler params must be concrete types");
            const P1 = info.params[1].type orelse @compileError("stream handler params must be concrete types");
            if (P0 != *Context or P1 != SecondParam) @compileError("two-arg stream handler must be fn(*Context, writer) !void");
            break :blk .with_context;
        },
        else => @compileError("stream handler must take 1 or 2 args"),
    };
}

fn streamHandlerFnInfo(comptime HandlerType: type) std.builtin.Type.Fn {
    return switch (@typeInfo(HandlerType)) {
        .@"fn" => |f| f,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => @compileError("stream handler must be a function"),
        },
        else => @compileError("stream handler must be a function"),
    };
}

fn streamAdapter(comptime HandlerType: type, comptime handler: anytype) type {
    const kind = classifyStreamHandler(HandlerType, *response_mod.StreamWriter);
    return struct {
        // The Adapter is intentionally trivial: it just relays the heap-
        // allocated `*Context` (already kept alive by `StreamingScope` on
        // the outer `Response`) into the user's callback. No per-adapter
        // allocation/dupe is required - the `wrapContextHandler` family
        // owns lifetime management above us.
        fn run(ctx: *const anyopaque, writer: *response_mod.StreamWriter) anyerror!void {
            switch (kind) {
                .writer_only => try handler(writer),
                .with_context => {
                    const c: *Context = @ptrCast(@alignCast(@constCast(ctx)));
                    try handler(c, writer);
                },
            }
        }
    };
}

fn sseAdapter(comptime HandlerType: type, comptime handler: anytype) type {
    const kind = classifyStreamHandler(HandlerType, *response_mod.SseWriter);
    return struct {
        fn run(ctx: *const anyopaque, writer: *response_mod.SseWriter) anyerror!void {
            switch (kind) {
                .writer_only => try handler(writer),
                .with_context => {
                    const c: *Context = @ptrCast(@alignCast(@constCast(ctx)));
                    try handler(c, writer);
                },
            }
        }
    };
}

fn putVariableValue(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(VariableEntry),
    key: []const u8,
    value: anytype,
) std.mem.Allocator.Error!void {
    const ValueType = @TypeOf(value);
    const T = if (comptime isStringLike(ValueType)) []const u8 else ValueType;
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    const stored_value = try allocator.create(T);
    errdefer allocator.destroy(stored_value);
    stored_value.* = if (comptime isStringLike(ValueType)) value else value;

    const entry: VariableEntry = .{
        .value = @ptrCast(stored_value),
        .type_name = @typeName(T),
        .deinit_fn = deinitValueFn(T),
    };

    const result = try map.getOrPut(allocator, key);
    if (result.found_existing) {
        allocator.free(owned_key);
        result.value_ptr.deinit_fn(allocator, result.value_ptr.value);
        result.value_ptr.* = entry;
        return;
    }

    result.key_ptr.* = owned_key;
    result.value_ptr.* = entry;
}

fn getVariableValue(
    map: *const std.StringHashMapUnmanaged(VariableEntry),
    comptime T: type,
    key: []const u8,
) ?T {
    const entry = map.get(key) orelse return null;
    if (!std.mem.eql(u8, entry.type_name, @typeName(T))) return null;

    const typed_value: *const T = @ptrCast(@alignCast(entry.value));
    return typed_value.*;
}

fn deinitVariableMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(VariableEntry),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit_fn(allocator, entry.value_ptr.value);
    }
    map.deinit(allocator);
    map.* = .empty;
}

fn deinitValueFn(comptime T: type) *const fn (allocator: std.mem.Allocator, value: *anyopaque) void {
    return struct {
        fn run(allocator: std.mem.Allocator, value: *anyopaque) void {
            const typed_value: *T = @ptrCast(@alignCast(value));
            allocator.destroy(typed_value);
        }
    }.run;
}

fn isStringLike(comptime T: type) bool {
    return core_meta.isStringLike(T);
}

test "context response helpers expose only single-argument style" {
    try std.testing.expect(!@hasDecl(Context, "bodyWithContentType"));
    try std.testing.expect(!@hasDecl(Context, "bodyWithOptions"));
    try std.testing.expect(!@hasDecl(Context, "bodyWithStatus"));
    try std.testing.expect(!@hasDecl(Context, "textWithOptions"));
    try std.testing.expect(!@hasDecl(Context, "textWithStatus"));
    try std.testing.expect(!@hasDecl(Context, "htmlWithOptions"));
    try std.testing.expect(!@hasDecl(Context, "htmlWithStatus"));
    try std.testing.expect(!@hasDecl(Context, "jsonWithOptions"));
    try std.testing.expect(!@hasDecl(Context, "jsonWithStatus"));
}

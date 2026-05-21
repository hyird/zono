const std = @import("std");

pub const Def = struct {
    err: anyerror,
    status: std.http.Status = .bad_request,
    code: []const u8 = "",
    message: []const u8 = "",

    pub fn codeValue(self: Def) []const u8 {
        return if (self.code.len > 0) self.code else @errorName(self.err);
    }

    pub fn messageValue(self: Def) []const u8 {
        return if (self.message.len > 0) self.message else self.status.phrase() orelse "Error";
    }
};

pub const Detail = struct {
    ctx: *const anyopaque,
    err: anyerror,
    format_fn: *const fn (ctx: *const anyopaque, err: anyerror, writer: *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn format(self: Detail, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.format_fn(self.ctx, self.err, writer);
    }
};

pub const DetailProvider = struct {
    ctx: *const anyopaque,
    has_fn: *const fn (ctx: *const anyopaque, err: anyerror) bool,
    format_fn: *const fn (ctx: *const anyopaque, err: anyerror, writer: *std.Io.Writer) std.Io.Writer.Error!void,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    defs: std.ArrayListUnmanaged(Def) = .empty,
    detail_providers: std.ArrayListUnmanaged(DetailProvider) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.defs.deinit(self.allocator);
        self.detail_providers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, defs_or_factory: anytype) std.mem.Allocator.Error!void {
        const Input = @TypeOf(defs_or_factory);

        if (comptime isZeroArgFactory(Input)) {
            return self.register(defs_or_factory());
        }

        if (comptime Input == Def) {
            try self.appendDef(defs_or_factory);
            return;
        }

        switch (comptime @typeInfo(Input)) {
            .@"struct" => |struct_info| {
                if (!struct_info.is_tuple) {
                    try self.appendDef(defs_or_factory);
                    return;
                }
                inline for (std.meta.fields(Input)) |field| {
                    try self.register(@field(defs_or_factory, field.name));
                }
            },
            .array => {
                for (defs_or_factory) |def| try self.appendDef(def);
            },
            .pointer => |pointer_info| switch (pointer_info.size) {
                .slice => {
                    for (defs_or_factory) |def| try self.appendDef(def);
                },
                .one => switch (@typeInfo(pointer_info.child)) {
                    .array => {
                        for (defs_or_factory[0..]) |def| try self.appendDef(def);
                    },
                    .@"struct" => try self.register(defs_or_factory.*),
                    else => @compileError("AppErrorRegistry.register accepts a zono.AppErrorDef, a slice/array of defs, a tuple of defs, or a zero-arg factory returning those."),
                },
                else => @compileError("AppErrorRegistry.register accepts a zono.AppErrorDef, a slice/array of defs, a tuple of defs, or a zero-arg factory returning those."),
            },
            else => @compileError("AppErrorRegistry.register accepts a zono.AppErrorDef, a slice/array of defs, a tuple of defs, or a zero-arg factory returning those."),
        }
    }

    fn appendDef(self: *Registry, def_like: anytype) std.mem.Allocator.Error!void {
        const def = normalizeDef(def_like);
        try self.defs.append(self.allocator, def);
    }

    pub fn lookup(self: *const Registry, err: anyerror) ?Def {
        for (self.defs.items) |def| {
            if (def.err == err) return def;
        }
        return defaultDef(err);
    }

    pub fn observe(self: *Registry, source: anytype) std.mem.Allocator.Error!void {
        const SourcePtr = @TypeOf(source);
        const source_info = switch (@typeInfo(SourcePtr)) {
            .pointer => |pointer| pointer,
            else => @compileError("AppErrorRegistry.observe expects a pointer to a detail source."),
        };
        if (source_info.size != .one) {
            @compileError("AppErrorRegistry.observe expects a single-item pointer.");
        }

        const Source = source_info.child;
        if (!@hasDecl(Source, "errorDetail")) {
            @compileError("AppErrorRegistry.observe sources must provide errorDetail(err: anyerror).");
        }

        const const_source: *const Source = source;
        try self.detail_providers.append(self.allocator, .{
            .ctx = @ptrCast(const_source),
            .has_fn = struct {
                fn run(ctx: *const anyopaque, err: anyerror) bool {
                    const typed: *const Source = @ptrCast(@alignCast(ctx));
                    const error_detail = typed.errorDetail(err);
                    return detailHasContent(error_detail);
                }
            }.run,
            .format_fn = struct {
                fn run(ctx: *const anyopaque, err: anyerror, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    const typed: *const Source = @ptrCast(@alignCast(ctx));
                    try writer.print("{f}", .{typed.errorDetail(err)});
                }
            }.run,
        });
    }

    pub fn detail(self: *const Registry, err: anyerror) ?Detail {
        for (self.detail_providers.items) |provider| {
            if (!provider.has_fn(provider.ctx, err)) continue;
            return .{
                .ctx = provider.ctx,
                .err = err,
                .format_fn = provider.format_fn,
            };
        }
        return null;
    }
};

fn normalizeDef(def_like: anytype) Def {
    const T = @TypeOf(def_like);
    if (comptime T == Def) return def_like;
    if (comptime !hasField(T, "err")) {
        @compileError("AppErrorDef-like values must include .err.");
    }
    return .{
        .err = def_like.err,
        .status = if (comptime hasField(T, "status")) def_like.status else .bad_request,
        .code = if (comptime hasField(T, "code")) def_like.code else "",
        .message = if (comptime hasField(T, "message")) def_like.message else "",
    };
}

fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, name),
        else => false,
    };
}

fn detailHasContent(detail: anytype) bool {
    const DetailType = @TypeOf(detail);
    if (comptime @hasDecl(DetailType, "hasDetail")) return detail.hasDetail();
    if (comptime hasField(DetailType, "server")) return detail.server != null;
    return true;
}

pub fn defaultDef(err: anyerror) ?Def {
    return switch (err) {
        error.EmptyRequestBody => .{
            .err = err,
            .status = .bad_request,
            .code = "EMPTY_REQUEST_BODY",
            .message = "Request body is required.",
        },
        error.InvalidRequestBody => .{
            .err = err,
            .status = .bad_request,
            .code = "INVALID_REQUEST_BODY",
            .message = "Request body is invalid.",
        },
        error.UnsupportedRequestBody => .{
            .err = err,
            .status = .unsupported_media_type,
            .code = "UNSUPPORTED_REQUEST_BODY",
            .message = "Request body content type is not supported.",
        },
        error.MissingParam => .{
            .err = err,
            .status = .bad_request,
            .code = "MISSING_PARAM",
            .message = "Required route parameter is missing.",
        },
        error.InvalidParam => .{
            .err = err,
            .status = .bad_request,
            .code = "INVALID_PARAM",
            .message = "Route parameter is invalid.",
        },
        error.MissingQuery => .{
            .err = err,
            .status = .bad_request,
            .code = "MISSING_QUERY",
            .message = "Required query parameter is missing.",
        },
        error.InvalidQuery => .{
            .err = err,
            .status = .bad_request,
            .code = "INVALID_QUERY",
            .message = "Query parameter is invalid.",
        },
        else => null,
    };
}

fn isZeroArgFactory(comptime T: type) bool {
    const fn_info = switch (@typeInfo(T)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => return false,
        },
        else => return false,
    };
    return fn_info.params.len == 0 and fn_info.return_type != null;
}

test "app error registry registers defs and falls back to request defaults" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(Def{
        .err = error.NoPermission,
        .status = .forbidden,
        .code = "NO_PERMISSION",
        .message = "No permission.",
    });

    try std.testing.expectEqual(std.http.Status.forbidden, registry.lookup(error.NoPermission).?.status);
    try std.testing.expectEqualStrings("NO_PERMISSION", registry.lookup(error.NoPermission).?.codeValue());
    try std.testing.expectEqual(std.http.Status.bad_request, registry.lookup(error.InvalidQuery).?.status);
    try std.testing.expectEqual(null, registry.lookup(error.Unregistered));
}

test "app error registry accepts zero-arg factories and tuples" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const Factory = struct {
        fn defs() []const Def {
            return &.{
                .{ .err = error.AuthExpired, .status = .unauthorized, .code = "AUTH_EXPIRED" },
            };
        }
    };

    try registry.register(.{
        Def{ .err = error.ForbiddenThing, .status = .forbidden },
        Factory.defs,
    });

    try std.testing.expectEqual(std.http.Status.forbidden, registry.lookup(error.ForbiddenThing).?.status);
    try std.testing.expectEqual(std.http.Status.unauthorized, registry.lookup(error.AuthExpired).?.status);
}

test "app error registry accepts anonymous def arrays" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(&.{
        .{ .err = error.AnonymousDef, .status = .conflict, .code = "ANON" },
    });

    try std.testing.expectEqual(std.http.Status.conflict, registry.lookup(error.AnonymousDef).?.status);
}

test "app error registry observes detail sources" {
    const FakeDetail = struct {
        err: anyerror,
        active: bool,

        fn hasDetail(self: @This()) bool {
            return self.active;
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("detail:{s}", .{@errorName(self.err)});
        }
    };

    const Source = struct {
        active: bool = true,

        pub fn errorDetail(self: *const @This(), err: anyerror) FakeDetail {
            return .{ .err = err, .active = self.active };
        }
    };

    var source = Source{};
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.observe(&source);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{registry.detail(error.ServerError).?});
    try std.testing.expectEqualStrings("detail:ServerError", writer.buffered());

    source.active = false;
    try std.testing.expectEqual(null, registry.detail(error.ServerError));
}

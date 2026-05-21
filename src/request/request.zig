const std = @import("std");
const zio = @import("zio");
const body_mod = @import("body.zig");
const core_meta = @import("../core/meta.zig");
const http_names = @import("../core/http_names.zig");
const time = @import("../core/time.zig");

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Header = std.http.Header;
const HeaderLookupFn = *const fn (ctx: *const anyopaque, name: []const u8) ?[]const u8;
const HeadersCollectFn = *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const Header;
pub const FormError = std.mem.Allocator.Error || error{
    InvalidPercentEncoding,
};
pub const ParseBodyError = FormError || error{
    UnsupportedContentType,
    LiveBodyUnavailable,
    MissingMultipartBoundary,
    InvalidMultipartBody,
};

pub const ParseBodyOptions = struct {
    all: bool = false,
    dot: bool = false,
};

pub const Blob = struct {
    data: []const u8,
    content_type: ?[]const u8 = null,
};

pub const ConnInfo = struct {
    remote: ?std.Io.net.IpAddress = null,
    local: ?std.Io.net.IpAddress = null,
};

pub const BodyStream = body_mod.BodyStream;
pub const BodyReadError = body_mod.BodyReadError;
pub const BodyStreamError = body_mod.BodyStreamError;

pub const SaveBodyError = BodyStreamError || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.File.Writer.EndError || error{
    ServerIoUnavailable,
};

pub const SaveBodyOptions = struct {
    max_bytes: ?usize = null,
    create_options: std.Io.Dir.CreateFileOptions = .{},
    buffer_size: usize = 64 * 1024,
};

pub const SaveMultipartOptions = struct {
    max_field_bytes: usize = 1024 * 1024,
    max_file_bytes: usize = 1024 * 1024 * 1024,
    max_line_bytes: usize = 64 * 1024,
    file_buffer_size: usize = 64 * 1024,
    create_options: std.Io.Dir.CreateFileOptions = .{},
};

pub const SavedMultipartField = struct {
    name: []const u8,
    value: []const u8,
};

pub const SavedMultipartFile = struct {
    name: []const u8,
    filename: []const u8,
    path: []const u8,
    content_type: ?[]const u8 = null,
    size: usize = 0,
};

pub const SavedMultipart = struct {
    allocator: std.mem.Allocator,
    fields: []SavedMultipartField = &.{},
    files: []SavedMultipartFile = &.{},

    pub fn deinit(self: *SavedMultipart) void {
        for (self.fields) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        freeSlice(self.allocator, self.fields);
        for (self.files) |file| {
            self.allocator.free(file.name);
            self.allocator.free(file.filename);
            self.allocator.free(file.path);
            if (file.content_type) |content_type| self.allocator.free(content_type);
        }
        freeSlice(self.allocator, self.files);
        self.* = undefined;
    }
};

pub const SaveMultipartError = anyerror;

pub const BodyState = body_mod.BodyState;
pub const BodyReader = body_mod.BodyReader;

pub const RawRequest = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    method_name: []const u8,
    path: []const u8,
    query_string: []const u8 = "",
    body_bytes: []const u8 = "",
    headers: []const Header = &.{},
    raw_ctx: ?*const anyopaque = null,

    pub fn target(self: RawRequest, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        if (self.query_string.len == 0) return try allocator.dupe(u8, self.path);
        return try std.fmt.allocPrint(allocator, "{s}?{s}", .{ self.path, self.query_string });
    }

    pub fn bodyStream(self: RawRequest) BodyStream {
        return .{ .bytes = self.body_bytes };
    }

    pub fn bodyBytes(self: RawRequest) []const u8 {
        return self.body_bytes;
    }

    pub fn raw(self: RawRequest, comptime T: type) ?*const T {
        const ptr = self.raw_ctx orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn deinit(self: *RawRequest) void {
        self.allocator.free(self.method_name);
        self.allocator.free(self.path);
        self.allocator.free(self.query_string);
        self.allocator.free(self.body_bytes);
        for (self.headers) |header_entry| {
            self.allocator.free(header_entry.name);
            self.allocator.free(header_entry.value);
        }
        freeSlice(self.allocator, self.headers);
        self.* = undefined;
    }
};

pub const ParsedBodyEntry = struct {
    key: []const u8,
    values: [][]const u8,
    array_like: bool = false,
};

pub const ParsedBodyField = struct {
    values: []const []const u8,
    array_like: bool = false,

    pub fn value(self: ParsedBodyField) ?[]const u8 {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn all(self: ParsedBodyField) []const []const u8 {
        return self.values;
    }

    pub fn isArray(self: ParsedBodyField) bool {
        return self.array_like or self.values.len > 1;
    }
};

pub const ParsedBody = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedBodyEntry = &.{},
    dot: bool = false,

    pub fn get(self: ParsedBody, name: []const u8) ?ParsedBodyField {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, name)) {
                return .{
                    .values = entry.values,
                    .array_like = entry.array_like,
                };
            }
        }
        return null;
    }

    pub fn value(self: ParsedBody, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn values(self: ParsedBody, name: []const u8) ?[]const []const u8 {
        return if (self.get(name)) |field| field.values else null;
    }

    pub fn entriesSlice(self: ParsedBody) []const ParsedBodyEntry {
        return self.entries;
    }

    pub fn group(self: ParsedBody, name: []const u8) std.mem.Allocator.Error!ParsedBody {
        if (!self.dot) {
            return .{
                .allocator = self.allocator,
            };
        }

        return try cloneParsedBodyGroup(self.allocator, self.entries, name, self.dot);
    }

    pub fn deinit(self: *ParsedBody) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            freeStringValues(self.allocator, entry.values);
            self.allocator.free(entry.values);
        }
        freeSlice(self.allocator, self.entries);
        self.entries = &.{};
    }
};

pub const DecodedQueryValues = struct {
    allocator: std.mem.Allocator,
    values: []const []const u8 = &.{},

    pub fn value(self: DecodedQueryValues) ?[]const u8 {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn all(self: DecodedQueryValues) []const []const u8 {
        return self.values;
    }

    pub fn deinit(self: *DecodedQueryValues) void {
        freeStringValues(self.allocator, self.values);
        freeSlice(self.allocator, self.values);
        self.values = &.{};
    }
};

pub const ParsedHeaderEntry = struct {
    name: []const u8,
    values: [][]const u8,
};

pub const ParsedHeaderField = struct {
    values: []const []const u8,

    pub fn value(self: ParsedHeaderField) ?[]const u8 {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn all(self: ParsedHeaderField) []const []const u8 {
        return self.values;
    }

    pub fn isArray(self: ParsedHeaderField) bool {
        return self.values.len > 1;
    }
};

pub const ParsedHeaders = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedHeaderEntry = &.{},

    pub fn get(self: ParsedHeaders, name: []const u8) ?ParsedHeaderField {
        for (self.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return .{
                    .values = entry.values,
                };
            }
        }
        return null;
    }

    pub fn value(self: ParsedHeaders, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn values(self: ParsedHeaders, name: []const u8) ?[]const []const u8 {
        return if (self.get(name)) |field| field.values else null;
    }

    pub fn entriesSlice(self: ParsedHeaders) []const ParsedHeaderEntry {
        return self.entries;
    }

    pub fn deinit(self: *ParsedHeaders) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            freeStringValues(self.allocator, entry.values);
            self.allocator.free(entry.values);
        }
        freeSlice(self.allocator, self.entries);
        self.entries = &.{};
    }
};

pub const ParsedMultipartFile = struct {
    filename: []const u8,
    content_type: ?[]const u8 = null,
    content: []const u8,
};

pub const ParsedMultipartFileEntry = struct {
    key: []const u8,
    files: []ParsedMultipartFile,
    array_like: bool = false,
};

pub const ParsedMultipartFileField = struct {
    files: []const ParsedMultipartFile,
    array_like: bool = false,

    pub fn value(self: ParsedMultipartFileField) ?ParsedMultipartFile {
        if (self.files.len == 0) return null;
        return self.files[self.files.len - 1];
    }

    pub fn all(self: ParsedMultipartFileField) []const ParsedMultipartFile {
        return self.files;
    }

    pub fn isArray(self: ParsedMultipartFileField) bool {
        return self.array_like or self.files.len > 1;
    }
};

pub const ParsedMultipartFiles = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedMultipartFileEntry = &.{},

    pub fn get(self: ParsedMultipartFiles, name: []const u8) ?ParsedMultipartFileField {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, name)) {
                return .{
                    .files = entry.files,
                    .array_like = entry.array_like,
                };
            }
        }
        return null;
    }

    pub fn file(self: ParsedMultipartFiles, name: []const u8) ?ParsedMultipartFile {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn files(self: ParsedMultipartFiles, name: []const u8) ?[]const ParsedMultipartFile {
        return if (self.get(name)) |field| field.files else null;
    }

    pub fn entriesSlice(self: ParsedMultipartFiles) []const ParsedMultipartFileEntry {
        return self.entries;
    }

    pub fn deinit(self: *ParsedMultipartFiles) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            for (entry.files) |multipart_file| {
                self.allocator.free(multipart_file.filename);
                if (multipart_file.content_type) |content_type| self.allocator.free(content_type);
                self.allocator.free(multipart_file.content);
            }
            self.allocator.free(entry.files);
        }
        freeSlice(self.allocator, self.entries);
        self.entries = &.{};
    }
};

pub const ParsedMultipart = struct {
    fields: ParsedBody,
    files: ParsedMultipartFiles,

    pub fn init(allocator: std.mem.Allocator) ParsedMultipart {
        return .{
            .fields = .{ .allocator = allocator },
            .files = .{ .allocator = allocator },
        };
    }

    pub fn get(self: ParsedMultipart, name: []const u8) ?ParsedBodyField {
        return self.fields.get(name);
    }

    pub fn value(self: ParsedMultipart, name: []const u8) ?[]const u8 {
        return self.fields.value(name);
    }

    pub fn values(self: ParsedMultipart, name: []const u8) ?[]const []const u8 {
        return self.fields.values(name);
    }

    pub fn getFile(self: ParsedMultipart, name: []const u8) ?ParsedMultipartFileField {
        return self.files.get(name);
    }

    pub fn file(self: ParsedMultipart, name: []const u8) ?ParsedMultipartFile {
        return self.files.file(name);
    }

    pub fn fileValues(self: ParsedMultipart, name: []const u8) ?[]const ParsedMultipartFile {
        return self.files.files(name);
    }

    pub fn group(self: ParsedMultipart, name: []const u8) std.mem.Allocator.Error!ParsedMultipart {
        if (!self.fields.dot) {
            return init(self.fields.allocator);
        }

        return .{
            .fields = try cloneParsedBodyGroup(self.fields.allocator, self.fields.entries, name, self.fields.dot),
            .files = try cloneParsedMultipartFileGroup(self.files.allocator, self.files.entries, name),
        };
    }

    pub fn deinit(self: *ParsedMultipart) void {
        self.fields.deinit();
        self.files.deinit();
    }
};

pub const ParsedFormData = ParsedMultipart;
pub const ParsedFormFile = ParsedMultipartFile;
pub const ParsedFormFiles = ParsedMultipartFiles;
pub const ParsedFormFileEntry = ParsedMultipartFileEntry;
pub const ParsedFormFileField = ParsedMultipartFileField;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    method_name: []const u8,
    path: []const u8,
    query_string: []const u8 = "",
    body_bytes: []const u8 = "",
    cookies_raw: []const u8 = "",
    header_list: []const Header = &.{},
    header_lookup_ctx: ?*const anyopaque = null,
    header_lookup_fn: ?HeaderLookupFn = null,
    headers_collect_fn: ?HeadersCollectFn = null,
    params: []const Param = &.{},
    route_path: ?[]const u8 = null,
    base_route_path: ?[]const u8 = null,
    context_state: ?*anyopaque = null,
    raw_ctx: ?*const anyopaque = null,
    env_ctx: ?*anyopaque = null,
    conn_info: ConnInfo = .{},
    /// Live `std.Io` handle for the server that received this request.
    /// Populated in production by `server.zig`; `null` in test paths that
    /// call `App.handle` directly without a server. Handlers can reach it
    /// via `Context.io()` to do real file I/O, outbound client calls, etc.
    server_io: ?std.Io = null,
    body_state: ?*BodyState = null,
    abort_flag: ?*std.atomic.Value(bool) = null,
    /// Monotonic deadline propagated by the server. Handlers can observe it
    /// through `Request.isAborted()` / `Context.isAborted()`.
    deadline_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, method: std.http.Method, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .method_name = @tagName(method),
            .path = path,
        };
    }

    pub fn initCustom(allocator: std.mem.Allocator, method_name: []const u8, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = methodFromName(method_name) orelse .GET,
            .method_name = method_name,
            .path = path,
        };
    }

    pub fn setMethodName(self: *Request, method_name: []const u8) void {
        self.method_name = method_name;
        if (methodFromName(method_name)) |method| self.method = method;
    }

    pub fn contextState(self: Request) ?*anyopaque {
        return self.context_state;
    }

    pub fn methodName(self: Request) []const u8 {
        return if (self.method_name.len > 0) self.method_name else @tagName(self.method);
    }

    pub fn routePath(self: Request) ?[]const u8 {
        return self.route_path;
    }

    pub fn basePath(self: Request) ?[]const u8 {
        return self.base_route_path;
    }

    pub fn baseRoutePath(self: Request) ?[]const u8 {
        return self.base_route_path;
    }

    pub fn raw(self: Request, comptime T: type) ?*const T {
        const ptr = self.raw_ctx orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn env(self: Request, comptime T: type) ?*T {
        const ptr = self.env_ctx orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn connInfo(self: Request) ConnInfo {
        return self.conn_info;
    }

    pub fn target(self: Request, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        if (self.query_string.len == 0) return try allocator.dupe(u8, self.path);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.path);
        try out.append(allocator, '?');
        try out.appendSlice(allocator, self.query_string);
        return try out.toOwnedSlice(allocator);
    }

    pub fn url(self: Request, allocator: std.mem.Allocator, scheme_override: ?[]const u8) std.mem.Allocator.Error![]const u8 {
        const scheme = scheme_override orelse self.header("x-forwarded-proto") orelse "http";
        const host = self.header("host") orelse "localhost";

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, scheme);
        try out.appendSlice(allocator, "://");
        try out.appendSlice(allocator, host);
        try out.appendSlice(allocator, self.path);
        if (self.query_string.len > 0) {
            try out.append(allocator, '?');
            try out.appendSlice(allocator, self.query_string);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn bodyStream(self: Request) BodyStream {
        return .{ .bytes = self.body_bytes };
    }

    pub fn bodyReader(self: Request) BodyReader {
        if (self.body_state) |state| {
            return .{ .source = .{ .live = state } };
        }
        return .{ .source = .{ .buffered = .{ .bytes = self.body_bytes } } };
    }

    pub fn hasStreamingBody(self: Request) bool {
        return self.body_state != null;
    }

    pub fn isAborted(self: Request) bool {
        if (self.abort_flag) |flag| {
            if (flag.load(.acquire)) return true;
        }
        if (self.deadline_ns) |deadline_ns| {
            if (time.deadlineExceeded(deadline_ns)) return true;
        }
        if (self.body_state) |state| return state.isAborted();
        return false;
    }

    pub fn abort(self: Request) void {
        if (self.abort_flag) |flag| flag.store(true, .release);
        if (self.body_state) |state| state.markAborted();
    }

    pub fn textAlloc(self: Request, allocator: std.mem.Allocator, max_bytes: usize) (BodyReadError || std.mem.Allocator.Error)![]u8 {
        var reader = self.bodyReader();
        return try reader.readAllAlloc(allocator, max_bytes);
    }

    pub fn arrayBufferAlloc(self: Request, allocator: std.mem.Allocator, max_bytes: usize) (BodyReadError || std.mem.Allocator.Error)![]u8 {
        return try self.textAlloc(allocator, max_bytes);
    }

    pub fn saveBodyToFile(self: Request, path: []const u8, options: SaveBodyOptions) SaveBodyError!usize {
        const io = self.server_io orelse return error.ServerIoUnavailable;
        return try self.saveBodyToFileIo(io, path, options);
    }

    pub fn saveBodyToFileIo(self: Request, io: std.Io, path: []const u8, options: SaveBodyOptions) SaveBodyError!usize {
        const buffer_size = @max(options.buffer_size, 1);
        const file_buffer = try self.allocator.alloc(u8, buffer_size);
        defer self.allocator.free(file_buffer);

        var file = try std.Io.Dir.cwd().createFile(io, path, options.create_options);
        var file_open = true;
        defer if (file_open) file.close(io);
        errdefer {
            if (file_open) {
                file.close(io);
                file_open = false;
            }
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
        }

        var file_writer = std.Io.File.Writer.init(file, io, file_buffer);
        var reader = self.bodyReader();
        const written = try reader.streamToLimit(&file_writer.interface, options.max_bytes);
        try file_writer.end();
        return written;
    }

    pub fn saveMultipartToDir(self: Request, dir_path: []const u8, options: SaveMultipartOptions) SaveMultipartError!SavedMultipart {
        const io = self.server_io orelse return error.ServerIoUnavailable;
        return try self.saveMultipartToDirIo(io, dir_path, options);
    }

    pub fn saveMultipartToDirIo(self: Request, io: std.Io, dir_path: []const u8, options: SaveMultipartOptions) SaveMultipartError!SavedMultipart {
        const raw_content_type = self.header("content-type") orelse return error.MissingMultipartBoundary;
        const boundary = extractMultipartBoundary(raw_content_type) orelse return error.MissingMultipartBoundary;
        var reader = self.bodyReader();
        return try parseMultipartStreaming(self.allocator, io, &reader, dir_path, boundary, options);
    }

    pub fn cloneRawRequest(self: Request, allocator: std.mem.Allocator) std.mem.Allocator.Error!RawRequest {
        const collected = try self.collectAllHeaders();
        defer if (collected.owns_slice) self.allocator.free(collected.headers);

        var owned_headers = try allocator.alloc(Header, collected.headers.len);
        errdefer allocator.free(owned_headers);

        var copied: usize = 0;
        errdefer {
            for (owned_headers[0..copied]) |header_entry| {
                allocator.free(header_entry.name);
                allocator.free(header_entry.value);
            }
        }

        for (collected.headers, 0..) |header_entry, index| {
            const owned_name = try allocator.dupe(u8, header_entry.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, header_entry.value);
            owned_headers[index] = .{
                .name = owned_name,
                .value = owned_value,
            };
            copied += 1;
        }

        const owned_method_name = try allocator.dupe(u8, self.methodName());
        errdefer allocator.free(owned_method_name);
        const owned_path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(owned_path);
        const owned_query_string = try allocator.dupe(u8, self.query_string);
        errdefer allocator.free(owned_query_string);
        const owned_body = try allocator.dupe(u8, self.body_bytes);
        errdefer allocator.free(owned_body);

        return .{
            .allocator = allocator,
            .method = self.method,
            .method_name = owned_method_name,
            .path = owned_path,
            .query_string = owned_query_string,
            .body_bytes = owned_body,
            .headers = owned_headers,
            .raw_ctx = self.raw_ctx,
        };
    }

    pub fn param(self: Request, name_or_mode: anytype) ParamResultType(@TypeOf(name_or_mode)) {
        const NameType = @TypeOf(name_or_mode);

        if (comptime isStringLike(NameType)) {
            return self.paramValue(name_or_mode);
        }

        if (NameType == @TypeOf(.enum_literal)) {
            if (name_or_mode != .all) {
                @compileError("Request.param only supports .all for aggregate param access.");
            }
            return self.parseParams(.{});
        }

        @compileError("Request.param accepts a param name string or .all.");
    }

    fn paramValue(self: Request, name: []const u8) ?[]const u8 {
        for (self.params) |entry| {
            if (std.mem.eql(u8, entry.key, name)) return entry.value;
        }
        return null;
    }

    pub fn paramInt(self: Request, comptime T: type, name: []const u8) !T {
        const value = self.paramValue(name) orelse return error.MissingParam;
        return parseScalar(T, value, error.InvalidParam);
    }

    pub fn paramBool(self: Request, name: []const u8) !bool {
        const value = self.paramValue(name) orelse return error.MissingParam;
        return parseScalar(bool, value, error.InvalidParam);
    }

    pub fn paramEnum(self: Request, comptime T: type, name: []const u8) !T {
        const value = self.paramValue(name) orelse return error.MissingParam;
        return parseScalar(T, value, error.InvalidParam);
    }

    pub fn paramsSlice(self: Request) []const Param {
        return self.params;
    }

    pub fn parseParams(self: Request, param_options: ParseBodyOptions) std.mem.Allocator.Error!ParsedBody {
        if (self.params.len == 0) {
            return .{
                .allocator = self.allocator,
                .dot = param_options.dot,
            };
        }

        var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
        errdefer {
            deinitParsedBodyEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }

        for (self.params) |param_entry| {
            const key = try self.allocator.dupe(u8, param_entry.key);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, param_entry.value);
            errdefer self.allocator.free(value);

            try appendParsedBodyEntry(self.allocator, &entries, key, value, param_options);
        }

        return .{
            .allocator = self.allocator,
            .dot = param_options.dot,
            .entries = try entries.toOwnedSlice(self.allocator),
        };
    }

    pub fn queryParam(self: Request, name: []const u8) ?[]const u8 {
        var index: usize = 0;
        while (index < self.query_string.len) {
            const pair_start = index;
            var eq_index: ?usize = null;
            while (index < self.query_string.len and self.query_string[index] != '&') : (index += 1) {
                if (self.query_string[index] == '=' and eq_index == null) eq_index = index;
            }

            const pair_end = index;
            if (eq_index) |eq| {
                if (eq - pair_start == name.len and std.mem.eql(u8, self.query_string[pair_start..eq], name)) {
                    return self.query_string[eq + 1 .. pair_end];
                }
            } else if (pair_end - pair_start == name.len and std.mem.eql(u8, self.query_string[pair_start..pair_end], name)) {
                return "";
            }

            if (index < self.query_string.len) index += 1;
        }
        return null;
    }

    pub fn queryDecoded(self: Request, name: []const u8) FormError!?[]const u8 {
        var parsed = try self.parseQuery(.{});
        defer parsed.deinit();
        const value = parsed.value(name) orelse return null;
        return try self.allocator.dupe(u8, value);
    }

    pub fn queryParamDecoded(self: Request, name: []const u8) FormError!?[]const u8 {
        return self.queryDecoded(name);
    }

    pub fn queriesDecoded(self: Request, name: []const u8) FormError!DecodedQueryValues {
        var parsed = try self.parseQuery(.{
            .all = true,
        });
        defer parsed.deinit();

        const field = parsed.get(name) orelse return .{
            .allocator = self.allocator,
        };
        const parsed_values = field.all();
        if (parsed_values.len == 0) return .{
            .allocator = self.allocator,
        };

        const values = try self.allocator.alloc([]const u8, parsed_values.len);
        errdefer self.allocator.free(values);
        var copied: usize = 0;
        errdefer {
            for (values[0..copied]) |value| self.allocator.free(value);
        }

        for (parsed_values, 0..) |value, index| {
            values[index] = try self.allocator.dupe(u8, value);
            copied += 1;
        }

        return .{
            .allocator = self.allocator,
            .values = values,
        };
    }

    pub fn query(self: Request, name_or_mode: anytype) QueryResultType(@TypeOf(name_or_mode)) {
        const NameType = @TypeOf(name_or_mode);

        if (comptime isStringLike(NameType)) {
            return self.queryParam(name_or_mode);
        }

        if (NameType == @TypeOf(.enum_literal)) {
            if (name_or_mode != .all) {
                @compileError("Request.query only supports .all for aggregate query access.");
            }
            return self.parseQuery(.{});
        }

        @compileError("Request.query accepts a query name string or .all.");
    }

    pub fn queryAll(self: Request) FormError!ParsedBody {
        return self.parseQuery(.{});
    }

    pub fn queryAllWithOptions(self: Request, query_options: ParseBodyOptions) FormError!ParsedBody {
        return self.parseQuery(query_options);
    }

    pub fn queryDecodedAll(self: Request) FormError!ParsedBody {
        return self.queryAll();
    }

    pub fn queryInt(self: Request, comptime T: type, name: []const u8, options: anytype) !T {
        return self.queryScalar(T, name, options);
    }

    pub fn queryBool(self: Request, name: []const u8, options: anytype) !bool {
        return self.queryScalar(bool, name, options);
    }

    pub fn queryEnum(self: Request, comptime T: type, name: []const u8, options: anytype) !T {
        return self.queryScalar(T, name, options);
    }

    fn queryScalar(self: Request, comptime T: type, name: []const u8, options: anytype) !T {
        const value = try self.queryDecodedValue(name, options);
        if (value) |bytes| {
            defer self.allocator.free(bytes);
            return parseScalar(T, bytes, error.InvalidQuery);
        }
        if (comptime hasField(@TypeOf(options), "default")) {
            return options.default;
        }
        return error.MissingQuery;
    }

    fn queryDecodedValue(self: Request, name: []const u8, options: anytype) !?[]const u8 {
        const value = self.queryDecoded(name) catch return error.InvalidQuery;
        if (value != null) return value;

        if (comptime hasField(@TypeOf(options), "alias")) {
            return self.queryDecoded(options.alias) catch return error.InvalidQuery;
        }

        return null;
    }

    pub fn parseQuery(self: Request, query_options: ParseBodyOptions) FormError!ParsedBody {
        if (self.query_string.len == 0) {
            return .{
                .allocator = self.allocator,
                .dot = query_options.dot,
            };
        }

        return try parseUrlEncodedPairs(self.allocator, self.query_string, query_options);
    }

    pub fn queries(self: Request, name: []const u8) ![]const []const u8 {
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        var index: usize = 0;
        while (index < self.query_string.len) {
            const pair_start = index;
            var eq_index: ?usize = null;
            while (index < self.query_string.len and self.query_string[index] != '&') : (index += 1) {
                if (self.query_string[index] == '=' and eq_index == null) eq_index = index;
            }

            const pair_end = index;
            if (eq_index) |eq| {
                if (eq - pair_start == name.len and std.mem.eql(u8, self.query_string[pair_start..eq], name)) {
                    try values.append(self.allocator, self.query_string[eq + 1 .. pair_end]);
                }
            } else if (pair_end - pair_start == name.len and std.mem.eql(u8, self.query_string[pair_start..pair_end], name)) {
                try values.append(self.allocator, "");
            }

            if (index < self.query_string.len) index += 1;
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    pub fn header(self: Request, name_or_mode: anytype) HeaderResultType(@TypeOf(name_or_mode)) {
        const NameType = @TypeOf(name_or_mode);

        if (comptime isStringLike(NameType)) {
            comptime if (isEmptyStringLiteral(NameType)) {
                @compileError("Use req.header(.all) to fetch all headers.");
            };

            const name: []const u8 = name_or_mode;
            return self.headerValue(name);
        }

        if (NameType == @TypeOf(.enum_literal)) {
            if (name_or_mode != .all) {
                @compileError("Request.header only supports .all for aggregate header access.");
            }
            return self.parseHeaders();
        }

        @compileError("Request.header accepts a header name string or .all.");
    }

    pub fn headersSlice(self: Request) []const Header {
        if (self.header_list.len > 0) return self.header_list;
        if (self.headers_collect_fn) |collect| {
            return collect(self.header_lookup_ctx.?, self.allocator) catch &.{};
        }
        return self.header_list;
    }

    pub fn headerValues(self: Request, name: []const u8) std.mem.Allocator.Error![]const []const u8 {
        const collected = try self.collectAllHeaders();
        defer if (collected.owns_slice) self.allocator.free(collected.headers);

        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        for (collected.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                try values.append(self.allocator, entry.value);
            }
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    pub fn parseHeaders(self: Request) std.mem.Allocator.Error!ParsedHeaders {
        const collected = try self.collectAllHeaders();
        defer if (collected.owns_slice) self.allocator.free(collected.headers);

        if (collected.headers.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        var entries: std.ArrayListUnmanaged(ParsedHeaderEntry) = .empty;
        errdefer {
            deinitParsedHeaderEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }

        for (collected.headers) |header_entry| {
            const normalized_name = try normalizeHeaderName(self.allocator, header_entry.name);
            errdefer self.allocator.free(normalized_name);
            const value = try self.allocator.dupe(u8, header_entry.value);
            errdefer self.allocator.free(value);

            try appendParsedHeaderEntry(self.allocator, &entries, normalized_name, value);
        }

        return .{
            .allocator = self.allocator,
            .entries = try entries.toOwnedSlice(self.allocator),
        };
    }

    pub fn contentType(self: Request) ?[]const u8 {
        return contentTypeInfo(self).value;
    }

    pub fn hasContentType(self: Request, value: []const u8) bool {
        const info = contentTypeInfo(self);
        return info.matches(value);
    }

    pub fn cookie(self: Request, name_or_mode: anytype) CookieResultType(@TypeOf(name_or_mode)) {
        const NameType = @TypeOf(name_or_mode);

        if (comptime isStringLike(NameType)) {
            return self.cookieValue(name_or_mode);
        }

        if (NameType == @TypeOf(.enum_literal)) {
            if (name_or_mode != .all) {
                @compileError("Request.cookie only supports .all for aggregate cookie access.");
            }
            return self.cookies();
        }

        @compileError("Request.cookie accepts a cookie name string or .all.");
    }

    fn cookieValue(self: Request, name: []const u8) ?[]const u8 {
        const raw_cookies = if (self.cookies_raw.len > 0)
            self.cookies_raw
        else
            self.header("cookie") orelse "";

        var index: usize = 0;
        while (index < raw_cookies.len) {
            while (index < raw_cookies.len and raw_cookies[index] == ' ') : (index += 1) {}
            const pair_start = index;
            var eq_index: ?usize = null;
            while (index < raw_cookies.len and raw_cookies[index] != ';') : (index += 1) {
                if (raw_cookies[index] == '=' and eq_index == null) eq_index = index;
            }

            const pair_end = index;
            if (eq_index) |eq| {
                if (eq - pair_start == name.len and std.mem.eql(u8, raw_cookies[pair_start..eq], name)) {
                    return raw_cookies[eq + 1 .. pair_end];
                }
            }

            if (index < raw_cookies.len) index += 1;
        }
        return null;
    }

    pub fn cookies(self: Request) std.mem.Allocator.Error!ParsedBody {
        const raw_cookies = if (self.cookies_raw.len > 0)
            self.cookies_raw
        else
            self.header("cookie") orelse "";

        if (raw_cookies.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        return try parseCookiePairs(self.allocator, raw_cookies);
    }

    pub fn text(self: Request) []const u8 {
        return self.body_bytes;
    }

    pub fn arrayBuffer(self: Request) []const u8 {
        return self.body_bytes;
    }

    pub fn blob(self: Request) Blob {
        return .{
            .data = self.body_bytes,
            .content_type = self.contentType(),
        };
    }

    pub fn bodyBytes(self: Request) []const u8 {
        return self.body_bytes;
    }

    pub fn jsonParsed(self: Request, comptime T: type) !?std.json.Parsed(T) {
        if (self.body_bytes.len == 0 and self.body_state != null) return error.LiveBodyUnavailable;
        if (self.body_bytes.len == 0) return null;
        const content_type = contentTypeInfo(self);
        if (content_type.value != null and !content_type.isJson()) {
            return error.UnsupportedContentType;
        }
        return try std.json.parseFromSlice(T, self.allocator, self.body_bytes, .{
            .ignore_unknown_fields = true,
        });
    }

    pub fn json(self: Request, comptime T: type) !T {
        if (self.body_bytes.len == 0 and self.body_state != null) return error.InvalidRequestBody;
        if (self.body_bytes.len == 0) return error.EmptyRequestBody;
        const content_type = contentTypeInfo(self);
        if (content_type.value != null and !content_type.isJson()) {
            return error.UnsupportedRequestBody;
        }
        return std.json.parseFromSliceLeaky(T, self.allocator, self.body_bytes, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidRequestBody;
    }

    pub fn formData(self: Request) ParseBodyError!ParsedFormData {
        return try self.parseBody(.{});
    }

    pub fn parseBody(self: Request, body_options: ParseBodyOptions) ParseBodyError!ParsedFormData {
        if (self.body_bytes.len == 0 and self.body_state != null) return error.LiveBodyUnavailable;
        if (self.body_bytes.len == 0) {
            var parsed = ParsedFormData.init(self.allocator);
            parsed.fields.dot = body_options.dot;
            return parsed;
        }
        const content_type = contentTypeInfo(self);
        if (content_type.kind == .form_urlencoded) {
            return try parseUrlEncodedFormData(self.allocator, self.body_bytes, body_options);
        }
        if (content_type.kind == .multipart_form_data) {
            const raw_content_type = content_type.raw orelse return error.MissingMultipartBoundary;
            return try parseMultipartForm(self.allocator, raw_content_type, self.body_bytes, body_options);
        } else {
            return error.UnsupportedContentType;
        }
    }

    const CollectedHeaders = struct {
        headers: []const Header = &.{},
        owns_slice: bool = false,
    };

    fn collectAllHeaders(self: Request) std.mem.Allocator.Error!CollectedHeaders {
        if (self.header_list.len > 0) {
            return .{
                .headers = self.header_list,
            };
        }
        if (self.headers_collect_fn) |collect| {
            const collected = try collect(self.header_lookup_ctx.?, self.allocator);
            return .{
                .headers = collected,
                .owns_slice = collected.len > 0,
            };
        }
        return .{};
    }

    fn headerValue(self: Request, name: []const u8) ?[]const u8 {
        for (self.header_list) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        if (self.header_lookup_fn) |lookup| {
            return lookup(self.header_lookup_ctx.?, name);
        }
        return null;
    }
};

pub fn methodFromName(name: []const u8) ?std.http.Method {
    inline for (std.meta.fields(std.http.Method)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @field(std.http.Method, field.name);
        }
    }
    return null;
}

fn HeaderResultType(comptime NameType: type) type {
    if (comptime isStringLike(NameType)) return ?[]const u8;
    if (NameType == @TypeOf(.enum_literal)) return std.mem.Allocator.Error!ParsedHeaders;
    @compileError("Request.header accepts a header name string or .all.");
}

fn ParamResultType(comptime NameType: type) type {
    if (comptime isStringLike(NameType)) return ?[]const u8;
    if (NameType == @TypeOf(.enum_literal)) return std.mem.Allocator.Error!ParsedBody;
    @compileError("Request.param accepts a param name string or .all.");
}

fn QueryResultType(comptime NameType: type) type {
    if (comptime isStringLike(NameType)) return ?[]const u8;
    if (NameType == @TypeOf(.enum_literal)) return FormError!ParsedBody;
    @compileError("Request.query accepts a query name string or .all.");
}

fn CookieResultType(comptime NameType: type) type {
    if (comptime isStringLike(NameType)) return ?[]const u8;
    if (NameType == @TypeOf(.enum_literal)) return std.mem.Allocator.Error!ParsedBody;
    @compileError("Request.cookie accepts a cookie name string or .all.");
}

const ContentTypeKind = enum {
    missing,
    json,
    form_urlencoded,
    multipart_form_data,
    other,
};

const ContentTypeInfo = struct {
    raw: ?[]const u8 = null,
    value: ?[]const u8 = null,
    kind: ContentTypeKind = .missing,

    fn matches(self: ContentTypeInfo, value: []const u8) bool {
        const content_type = self.value orelse return false;
        return std.ascii.eqlIgnoreCase(content_type, value);
    }

    fn isJson(self: ContentTypeInfo) bool {
        return self.kind == .json;
    }
};

fn contentTypeInfo(self: Request) ContentTypeInfo {
    const raw_content_type = self.header("content-type") orelse return .{};
    const semi = std.mem.indexOfScalar(u8, raw_content_type, ';') orelse raw_content_type.len;
    const content_type = std.mem.trim(u8, raw_content_type[0..semi], " \t");

    const kind: ContentTypeKind = if (isJsonContentType(content_type))
        .json
    else if (std.ascii.eqlIgnoreCase(content_type, "application/x-www-form-urlencoded"))
        .form_urlencoded
    else if (std.ascii.eqlIgnoreCase(content_type, "multipart/form-data"))
        .multipart_form_data
    else
        .other;

    return .{
        .raw = raw_content_type,
        .value = content_type,
        .kind = kind,
    };
}

fn isJsonContentType(content_type: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(content_type, "application/json")) return true;
    if (std.ascii.eqlIgnoreCase(content_type, "text/json")) return true;

    return std.ascii.startsWithIgnoreCase(content_type, "application/") and
        std.ascii.endsWithIgnoreCase(content_type, "+json");
}

fn isStringLike(comptime T: type) bool {
    return core_meta.isStringLike(T);
}

fn freeSlice(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}

fn freeStringValues(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, name),
        else => false,
    };
}

fn parseScalar(comptime T: type, value: []const u8, invalid_error: anyerror) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10) catch return invalid_error,
        .bool => parseBool(value) orelse return invalid_error,
        .@"enum" => std.meta.stringToEnum(T, value) orelse return invalid_error,
        else => @compileError("request scalar helpers support int, bool, and enum types."),
    };
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or
        std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    return null;
}

fn isEmptyStringLiteral(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8 and array.len == 0,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8 and array.len == 0,
        else => false,
    };
}

fn decodeFormComponent(allocator: std.mem.Allocator, input: []const u8) FormError![]const u8 {
    if (input.len == 0) return try allocator.alloc(u8, 0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const c = input[index];
        switch (c) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (index + 2 >= input.len) return error.InvalidPercentEncoding;
                const hi = std.fmt.charToDigit(input[index + 1], 16) catch return error.InvalidPercentEncoding;
                const lo = std.fmt.charToDigit(input[index + 2], 16) catch return error.InvalidPercentEncoding;
                try out.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
                index += 2;
            },
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn appendParsedBodyEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedBodyEntry),
    key: []const u8,
    value: []const u8,
    body_options: ParseBodyOptions,
) std.mem.Allocator.Error!void {
    const collect_all_values = body_options.all or std.mem.endsWith(u8, key, "[]");

    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;

        allocator.free(key);

        if (collect_all_values) {
            const new_values = try allocator.alloc([]const u8, entry.values.len + 1);
            @memcpy(new_values[0..entry.values.len], entry.values);
            new_values[entry.values.len] = value;
            allocator.free(entry.values);
            entry.values = new_values;
            entry.array_like = true;
            return;
        }

        allocator.free(entry.values[entry.values.len - 1]);
        entry.values[entry.values.len - 1] = value;
        return;
    }

    const values = try allocator.alloc([]const u8, 1);
    values[0] = value;
    try entries.append(allocator, .{
        .key = key,
        .values = values,
        .array_like = std.mem.endsWith(u8, key, "[]"),
    });
}

fn cloneParsedBodyGroup(
    allocator: std.mem.Allocator,
    entries: []const ParsedBodyEntry,
    name: []const u8,
    dot: bool,
) std.mem.Allocator.Error!ParsedBody {
    var prefix_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix_buffer.deinit(allocator);
    try prefix_buffer.appendSlice(allocator, name);
    try prefix_buffer.append(allocator, '.');

    var grouped_entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, grouped_entries.items);
        grouped_entries.deinit(allocator);
    }

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, prefix_buffer.items)) continue;

        const child_key = try allocator.dupe(u8, entry.key[prefix_buffer.items.len..]);
        errdefer allocator.free(child_key);
        const values = try allocator.alloc([]const u8, entry.values.len);
        var filled_values: usize = 0;
        errdefer {
            for (values[0..filled_values]) |value| allocator.free(value);
            allocator.free(values);
        }

        for (entry.values, 0..) |value, index| {
            values[index] = try allocator.dupe(u8, value);
            filled_values = index + 1;
        }

        try grouped_entries.append(allocator, .{
            .key = child_key,
            .values = values,
            .array_like = entry.array_like,
        });
    }

    return .{
        .allocator = allocator,
        .entries = try grouped_entries.toOwnedSlice(allocator),
        .dot = dot,
    };
}

fn deinitParsedBodyEntries(allocator: std.mem.Allocator, entries: []const ParsedBodyEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        for (entry.values) |entry_value| {
            allocator.free(entry_value);
        }
        allocator.free(entry.values);
    }
}

fn deinitParsedHeaderEntries(allocator: std.mem.Allocator, entries: []const ParsedHeaderEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        for (entry.values) |entry_value| {
            allocator.free(entry_value);
        }
        allocator.free(entry.values);
    }
}

fn deinitParsedMultipartFileEntries(allocator: std.mem.Allocator, entries: []const ParsedMultipartFileEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        for (entry.files) |multipart_file| {
            allocator.free(multipart_file.filename);
            if (multipart_file.content_type) |content_type| allocator.free(content_type);
            allocator.free(multipart_file.content);
        }
        allocator.free(entry.files);
    }
}

fn normalizeHeaderName(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try allocator.dupe(u8, name);
    for (out) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
    return out;
}

fn appendParsedHeaderEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedHeaderEntry),
    name: []const u8,
    value: []const u8,
) std.mem.Allocator.Error!void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;

        allocator.free(name);

        const new_values = try allocator.alloc([]const u8, entry.values.len + 1);
        @memcpy(new_values[0..entry.values.len], entry.values);
        new_values[entry.values.len] = value;
        allocator.free(entry.values);
        entry.values = new_values;
        return;
    }

    const values = try allocator.alloc([]const u8, 1);
    values[0] = value;
    try entries.append(allocator, .{
        .name = name,
        .values = values,
    });
}

fn parseUrlEncodedBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedBody {
    return try parseUrlEncodedPairs(allocator, body, body_options);
}

fn parseUrlEncodedFormData(
    allocator: std.mem.Allocator,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedFormData {
    return .{
        .fields = try parseUrlEncodedPairs(allocator, body, body_options),
        .files = .{ .allocator = allocator },
    };
}

fn parseUrlEncodedPairs(
    allocator: std.mem.Allocator,
    input: []const u8,
    body_options: ParseBodyOptions,
) FormError!ParsedBody {
    var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, entries.items);
        entries.deinit(allocator);
    }

    var rest = input;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const pair = rest[0..amp];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key_raw = pair[0..eq];
        const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try decodeFormComponent(allocator, key_raw);
        errdefer allocator.free(key);
        const value = try decodeFormComponent(allocator, value_raw);
        errdefer allocator.free(value);

        try appendParsedBodyEntry(allocator, &entries, key, value, body_options);
        rest = if (amp < rest.len) rest[amp + 1 ..] else "";
    }

    return .{
        .allocator = allocator,
        .dot = body_options.dot,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseCookiePairs(
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!ParsedBody {
    var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, entries.items);
        entries.deinit(allocator);
    }

    var rest = input;
    while (rest.len > 0) {
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const pair = rest[0..semi];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try allocator.dupe(u8, pair[0..eq]);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, if (eq < pair.len) pair[eq + 1 ..] else "");
        errdefer allocator.free(value);

        try appendParsedBodyEntry(allocator, &entries, key, value, .{});
        rest = if (semi < rest.len) rest[semi + 1 ..] else "";
    }

    return .{
        .allocator = allocator,
        .dot = false,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseMultipartForm(
    allocator: std.mem.Allocator,
    raw_content_type: []const u8,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedFormData {
    const boundary = extractMultipartBoundary(raw_content_type) orelse return error.MissingMultipartBoundary;
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);

    var field_entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    var file_entries: std.ArrayListUnmanaged(ParsedMultipartFileEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, field_entries.items);
        field_entries.deinit(allocator);
        deinitParsedMultipartFileEntries(allocator, file_entries.items);
        file_entries.deinit(allocator);
    }

    if (!std.mem.startsWith(u8, body, delimiter)) return error.InvalidMultipartBody;
    var cursor: usize = delimiter.len;

    while (true) {
        const rest = body[cursor..];
        if (std.mem.startsWith(u8, rest, "--")) {
            const tail = rest[2..];
            if (tail.len == 0 or std.mem.eql(u8, tail, "\r\n")) {
                break;
            }
            return error.InvalidMultipartBody;
        }
        if (!std.mem.startsWith(u8, rest, "\r\n")) return error.InvalidMultipartBody;

        const part_start = cursor + 2;
        const boundary_match = findNextMultipartBoundary(body, delimiter, part_start) orelse return error.InvalidMultipartBody;
        const part = body[part_start..boundary_match.part_end];
        cursor = boundary_match.after;

        const parsed_part = try parseMultipartPart(part);

        if (parsed_part.filename) |filename| {
            const key = try allocator.dupe(u8, parsed_part.name);
            errdefer allocator.free(key);
            const owned_filename = try allocator.dupe(u8, filename);
            errdefer allocator.free(owned_filename);
            const owned_content = try allocator.dupe(u8, parsed_part.value);
            errdefer allocator.free(owned_content);
            const owned_content_type = if (parsed_part.content_type) |content_type|
                try allocator.dupe(u8, content_type)
            else
                null;
            errdefer if (owned_content_type) |content_type| allocator.free(content_type);

            try appendParsedMultipartFileEntry(allocator, &file_entries, key, .{
                .filename = owned_filename,
                .content_type = owned_content_type,
                .content = owned_content,
            });
        } else {
            const key = try allocator.dupe(u8, parsed_part.name);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, parsed_part.value);
            errdefer allocator.free(value);
            try appendParsedBodyEntry(allocator, &field_entries, key, value, body_options);
        }

        if (boundary_match.final) {
            const tail = body[cursor..];
            if (tail.len != 0 and !std.mem.eql(u8, tail, "\r\n")) return error.InvalidMultipartBody;
            break;
        }
    }

    return .{
        .fields = .{
            .allocator = allocator,
            .dot = body_options.dot,
            .entries = try field_entries.toOwnedSlice(allocator),
        },
        .files = .{
            .allocator = allocator,
            .entries = try file_entries.toOwnedSlice(allocator),
        },
    };
}

const ParsedMultipartPart = struct {
    name: []const u8,
    value: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

const MultipartBoundaryMatch = struct {
    part_end: usize,
    after: usize,
    final: bool,
};

fn findNextMultipartBoundary(body: []const u8, delimiter: []const u8, start: usize) ?MultipartBoundaryMatch {
    var search_index = start;
    while (search_index < body.len) {
        const rel = std.mem.indexOf(u8, body[search_index..], "\r\n") orelse return null;
        const boundary_prefix = search_index + rel;
        const delimiter_start = boundary_prefix + 2;
        if (delimiter_start + delimiter.len > body.len) return null;
        if (!std.mem.startsWith(u8, body[delimiter_start..], delimiter)) {
            search_index = delimiter_start;
            continue;
        }

        const tail_index = delimiter_start + delimiter.len;
        const tail = body[tail_index..];
        if (std.mem.startsWith(u8, tail, "--")) {
            const after_final = tail[2..];
            if (after_final.len == 0 or std.mem.startsWith(u8, after_final, "\r\n")) {
                return .{
                    .part_end = boundary_prefix,
                    .after = tail_index + 2,
                    .final = true,
                };
            }
        }
        if (std.mem.startsWith(u8, tail, "\r\n")) {
            return .{
                .part_end = boundary_prefix,
                .after = tail_index,
                .final = false,
            };
        }

        search_index = tail_index;
    }
    return null;
}

fn parseMultipartPart(part: []const u8) ParseBodyError!ParsedMultipartPart {
    const separator_index = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return error.InvalidMultipartBody;
    const headers_block = part[0..separator_index];
    const value = part[separator_index + 4 ..];

    var disposition_value: ?[]const u8 = null;
    var content_type_value: ?[]const u8 = null;
    var rest = headers_block;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidMultipartBody;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
            disposition_value = header_value;
        } else if (http_names.isContentType(header_name)) {
            content_type_value = header_value;
        }
        rest = if (line_end < rest.len) rest[line_end + 2 ..] else "";
    }

    const disposition = disposition_value orelse return error.InvalidMultipartBody;
    if (!std.ascii.startsWithIgnoreCase(disposition, "form-data")) return error.InvalidMultipartBody;

    return .{
        .name = extractDispositionParameter(disposition, "name") orelse return error.InvalidMultipartBody,
        .value = value,
        .filename = extractDispositionParameter(disposition, "filename"),
        .content_type = content_type_value,
    };
}

fn appendParsedMultipartFileEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedMultipartFileEntry),
    key: []const u8,
    file: ParsedMultipartFile,
) std.mem.Allocator.Error!void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;

        allocator.free(key);

        const new_files = try allocator.alloc(ParsedMultipartFile, entry.files.len + 1);
        @memcpy(new_files[0..entry.files.len], entry.files);
        new_files[entry.files.len] = file;
        allocator.free(entry.files);
        entry.files = new_files;
        entry.array_like = true;
        return;
    }

    const files = try allocator.alloc(ParsedMultipartFile, 1);
    files[0] = file;
    try entries.append(allocator, .{
        .key = key,
        .files = files,
        .array_like = std.mem.endsWith(u8, key, "[]"),
    });
}

fn cloneParsedMultipartFileGroup(
    allocator: std.mem.Allocator,
    entries: []const ParsedMultipartFileEntry,
    name: []const u8,
) std.mem.Allocator.Error!ParsedMultipartFiles {
    var prefix_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix_buffer.deinit(allocator);
    try prefix_buffer.appendSlice(allocator, name);
    try prefix_buffer.append(allocator, '.');

    var grouped_entries: std.ArrayListUnmanaged(ParsedMultipartFileEntry) = .empty;
    errdefer {
        deinitParsedMultipartFileEntries(allocator, grouped_entries.items);
        grouped_entries.deinit(allocator);
    }

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, prefix_buffer.items)) continue;

        const child_key = try allocator.dupe(u8, entry.key[prefix_buffer.items.len..]);
        errdefer allocator.free(child_key);

        const files = try allocator.alloc(ParsedMultipartFile, entry.files.len);
        var filled_files: usize = 0;
        errdefer {
            for (files[0..filled_files]) |file| {
                allocator.free(file.filename);
                if (file.content_type) |content_type| allocator.free(content_type);
                allocator.free(file.content);
            }
            allocator.free(files);
        }

        for (entry.files, 0..) |file, index| {
            files[index] = .{
                .filename = try allocator.dupe(u8, file.filename),
                .content_type = if (file.content_type) |content_type|
                    try allocator.dupe(u8, content_type)
                else
                    null,
                .content = try allocator.dupe(u8, file.content),
            };
            filled_files = index + 1;
        }

        try grouped_entries.append(allocator, .{
            .key = child_key,
            .files = files,
            .array_like = entry.array_like,
        });
    }

    return .{
        .allocator = allocator,
        .entries = try grouped_entries.toOwnedSlice(allocator),
    };
}

fn extractMultipartBoundary(raw_content_type: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, raw_content_type, ';');
    _ = parts.next();

    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (!std.ascii.startsWithIgnoreCase(part, "boundary=")) continue;

        const value = part["boundary=".len..];
        if (value.len == 0) return null;
        if (value[0] == '"' and value.len >= 2 and value[value.len - 1] == '"') {
            return value[1 .. value.len - 1];
        }
        return value;
    }

    return null;
}

fn extractDispositionParameter(disposition: []const u8, name: []const u8) ?[]const u8 {
    var index = std.mem.indexOfScalar(u8, disposition, ';') orelse return null;
    index += 1;

    while (index < disposition.len) {
        while (index < disposition.len and (disposition[index] == ';' or disposition[index] == ' ' or disposition[index] == '\t')) index += 1;
        const param_start = index;
        while (index < disposition.len and disposition[index] != '=' and disposition[index] != ';') index += 1;
        if (index >= disposition.len or disposition[index] != '=') {
            while (index < disposition.len and disposition[index] != ';') index += 1;
            continue;
        }

        const param_name = std.mem.trim(u8, disposition[param_start..index], " \t");
        index += 1;
        while (index < disposition.len and (disposition[index] == ' ' or disposition[index] == '\t')) index += 1;

        const value_start, const value_end = if (index < disposition.len and disposition[index] == '"') quoted: {
            index += 1;
            const start = index;
            while (index < disposition.len) : (index += 1) {
                if (disposition[index] == '\\') {
                    if (index + 1 < disposition.len) index += 1;
                    continue;
                }
                if (disposition[index] == '"') {
                    const end = index;
                    index += 1;
                    while (index < disposition.len and disposition[index] != ';') index += 1;
                    break :quoted .{ start, end };
                }
            }
            return null;
        } else unquoted: {
            const start = index;
            while (index < disposition.len and disposition[index] != ';') index += 1;
            const end = std.mem.trimEnd(u8, disposition[start..index], " \t").len + start;
            break :unquoted .{ start, end };
        };

        if (std.ascii.eqlIgnoreCase(param_name, name)) {
            return disposition[value_start..value_end];
        }
    }
    return null;
}

const MultipartBoundary = enum {
    none,
    next,
    done,
};

const MultipartPartMeta = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,

    fn deinit(self: *MultipartPartMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.filename) |filename| allocator.free(filename);
        if (self.content_type) |content_type| allocator.free(content_type);
        self.* = undefined;
    }
};

const MultipartLineReader = struct {
    allocator: std.mem.Allocator,
    reader: *BodyReader,
    max_line_bytes: usize,

    fn readLine(self: *MultipartLineReader) SaveMultipartError!?[]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            var byte: [1]u8 = undefined;
            const n = try self.reader.read(&byte);
            if (n == 0) {
                if (out.items.len == 0) return null;
                return try out.toOwnedSlice(self.allocator);
            }
            if (out.items.len >= self.max_line_bytes) return error.MultipartLineTooLarge;
            try out.append(self.allocator, byte[0]);
            if (byte[0] == '\n') return try out.toOwnedSlice(self.allocator);
        }
    }
};

fn parseMultipartStreaming(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *BodyReader,
    dir_path: []const u8,
    boundary: []const u8,
    options: SaveMultipartOptions,
) SaveMultipartError!SavedMultipart {
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    const part_delimiter = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
    defer allocator.free(part_delimiter);

    var line_reader = MultipartLineReader{
        .allocator = allocator,
        .reader = reader,
        .max_line_bytes = @max(options.max_line_bytes, delimiter.len + 8),
    };

    var fields: std.ArrayListUnmanaged(SavedMultipartField) = .empty;
    var files: std.ArrayListUnmanaged(SavedMultipartFile) = .empty;
    errdefer {
        deinitSavedMultipartFields(allocator, fields.items);
        fields.deinit(allocator);
        deinitSavedMultipartFiles(allocator, files.items);
        files.deinit(allocator);
    }

    try consumeMultipartPreamble(&line_reader, delimiter);

    var file_index: usize = 0;
    while (true) {
        var meta = try readMultipartPartMeta(allocator, &line_reader);
        defer meta.deinit(allocator);

        const boundary_state = if (meta.filename) |filename| blk: {
            const saved = try saveMultipartFilePart(
                allocator,
                io,
                &line_reader,
                part_delimiter,
                dir_path,
                file_index,
                meta.name,
                filename,
                meta.content_type,
                options,
            );
            file_index += 1;
            const saved_file = saved.saved();
            files.append(allocator, saved_file) catch |err| {
                deinitSavedMultipartFile(allocator, saved_file);
                return err;
            };
            break :blk saved.boundary;
        } else blk: {
            const saved = try readMultipartFieldPart(
                allocator,
                &line_reader,
                part_delimiter,
                meta.name,
                options,
            );
            fields.append(allocator, saved.field) catch |err| {
                deinitSavedMultipartField(allocator, saved.field);
                return err;
            };
            break :blk saved.boundary;
        };

        if (boundary_state == .done) break;
        if (boundary_state != .next) return error.InvalidMultipartBody;
    }

    return .{
        .allocator = allocator,
        .fields = try fields.toOwnedSlice(allocator),
        .files = try files.toOwnedSlice(allocator),
    };
}

fn consumeMultipartPreamble(line_reader: *MultipartLineReader, delimiter: []const u8) SaveMultipartError!void {
    while (try line_reader.readLine()) |line| {
        defer line_reader.allocator.free(line);
        switch (multipartBoundaryKind(line, delimiter)) {
            .next => return,
            .done => return,
            .none => {},
        }
    }
    return error.InvalidMultipartBody;
}

fn readMultipartPartMeta(allocator: std.mem.Allocator, line_reader: *MultipartLineReader) SaveMultipartError!MultipartPartMeta {
    var disposition_value: ?[]u8 = null;
    var content_type_value: ?[]u8 = null;
    errdefer {
        if (disposition_value) |value| allocator.free(value);
        if (content_type_value) |value| allocator.free(value);
    }

    while (try line_reader.readLine()) |raw_line| {
        defer allocator.free(raw_line);
        const line = trimLineEnding(raw_line);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidMultipartBody;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
            if (disposition_value) |value| allocator.free(value);
            disposition_value = try allocator.dupe(u8, header_value);
        } else if (http_names.isContentType(header_name)) {
            if (content_type_value) |value| allocator.free(value);
            content_type_value = try allocator.dupe(u8, header_value);
        }
    } else {
        return error.InvalidMultipartBody;
    }

    const disposition = disposition_value orelse return error.InvalidMultipartBody;
    defer allocator.free(disposition);
    if (!std.ascii.startsWithIgnoreCase(disposition, "form-data")) return error.InvalidMultipartBody;

    const name = try allocator.dupe(u8, extractDispositionParameter(disposition, "name") orelse return error.InvalidMultipartBody);
    errdefer allocator.free(name);
    const filename = if (extractDispositionParameter(disposition, "filename")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (filename) |value| allocator.free(value);

    const content_type = content_type_value;
    content_type_value = null;

    return .{
        .name = name,
        .filename = filename,
        .content_type = content_type,
    };
}

const SavedFieldWithBoundary = struct {
    field: SavedMultipartField,
    boundary: MultipartBoundary,
};

fn readMultipartFieldPart(
    allocator: std.mem.Allocator,
    line_reader: *MultipartLineReader,
    delimiter: []const u8,
    name: []const u8,
    options: SaveMultipartOptions,
) SaveMultipartError!SavedFieldWithBoundary {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    var value: std.ArrayListUnmanaged(u8) = .empty;
    errdefer value.deinit(allocator);

    var emit_ctx = FieldEmitCtx{
        .allocator = allocator,
        .out = &value,
        .limit = options.max_field_bytes,
    };
    const boundary = try scanMultipartPart(allocator, line_reader.reader, delimiter, &emit_ctx, emitFieldBytes);
    return .{
        .field = .{
            .name = owned_name,
            .value = try value.toOwnedSlice(allocator),
        },
        .boundary = boundary,
    };
}

const SavedFileWithBoundary = struct {
    name: []const u8,
    filename: []const u8,
    path: []const u8,
    content_type: ?[]const u8 = null,
    size: usize = 0,
    boundary: MultipartBoundary,

    fn saved(self: SavedFileWithBoundary) SavedMultipartFile {
        return .{
            .name = self.name,
            .filename = self.filename,
            .path = self.path,
            .content_type = self.content_type,
            .size = self.size,
        };
    }
};

fn saveMultipartFilePart(
    allocator: std.mem.Allocator,
    io: std.Io,
    line_reader: *MultipartLineReader,
    delimiter: []const u8,
    dir_path: []const u8,
    file_index: usize,
    name: []const u8,
    filename: []const u8,
    content_type: ?[]const u8,
    options: SaveMultipartOptions,
) SaveMultipartError!SavedFileWithBoundary {
    const safe_name = try sanitizeMultipartFilename(allocator, filename);
    defer allocator.free(safe_name);
    const path = try multipartUploadPath(allocator, dir_path, file_index, safe_name);
    errdefer allocator.free(path);

    const file_buffer = try allocator.alloc(u8, @max(options.file_buffer_size, 1));
    defer allocator.free(file_buffer);

    var file = try std.Io.Dir.cwd().createFile(io, path, options.create_options);
    var file_open = true;
    defer if (file_open) file.close(io);
    var file_writer = std.Io.File.Writer.init(file, io, file_buffer);
    var writer_ended = false;
    errdefer {
        if (!writer_ended) file_writer.end() catch {};
        if (file_open) {
            file.close(io);
            file_open = false;
        }
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var size: usize = 0;
    var emit_ctx = FileEmitCtx{
        .writer = &file_writer.interface,
        .written = &size,
        .limit = options.max_file_bytes,
    };
    const boundary = try scanMultipartPart(allocator, line_reader.reader, delimiter, &emit_ctx, emitFileBytes);
    try file_writer.end();
    writer_ended = true;

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_filename = try allocator.dupe(u8, filename);
    errdefer allocator.free(owned_filename);
    const owned_content_type = if (content_type) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_content_type) |value| allocator.free(value);

    return .{
        .name = owned_name,
        .filename = owned_filename,
        .path = path,
        .content_type = owned_content_type,
        .size = size,
        .boundary = boundary,
    };
}

const FieldEmitCtx = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    limit: usize,
};

fn emitFieldBytes(ctx: *anyopaque, bytes: []const u8) SaveMultipartError!void {
    const emit_ctx: *FieldEmitCtx = @ptrCast(@alignCast(ctx));
    try appendLimited(emit_ctx.allocator, emit_ctx.out, bytes, emit_ctx.limit, error.MultipartFieldTooLarge);
}

const FileEmitCtx = struct {
    writer: *std.Io.Writer,
    written: *usize,
    limit: usize,
};

fn emitFileBytes(ctx: *anyopaque, bytes: []const u8) SaveMultipartError!void {
    const emit_ctx: *FileEmitCtx = @ptrCast(@alignCast(ctx));
    try writeLimited(emit_ctx.writer, bytes, emit_ctx.written, emit_ctx.limit);
}

fn scanMultipartPart(
    allocator: std.mem.Allocator,
    reader: *BodyReader,
    delimiter: []const u8,
    emit_ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, bytes: []const u8) SaveMultipartError!void,
) SaveMultipartError!MultipartBoundary {
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(allocator);

    var reprocess: ?u8 = null;
    while (true) {
        const byte = if (reprocess) |value| blk: {
            reprocess = null;
            break :blk value;
        } else (try readMultipartByte(reader)) orelse return error.InvalidMultipartBody;

        try pending.append(allocator, byte);
        while (pending.items.len > 0 and !isPrefix(pending.items, delimiter)) {
            try emit_fn(emit_ctx, pending.items[0..1]);
            removeFirstByte(&pending);
        }

        if (pending.items.len == delimiter.len) {
            const tail_first = (try readMultipartByte(reader)) orelse return error.InvalidMultipartBody;
            if (tail_first == '-') {
                const tail_second = (try readMultipartByte(reader)) orelse return error.InvalidMultipartBody;
                if (tail_second == '-') return .done;

                try emit_fn(emit_ctx, pending.items);
                pending.clearRetainingCapacity();
                try emit_fn(emit_ctx, "-");
                reprocess = tail_second;
                continue;
            }
            if (tail_first == '\r') {
                const tail_second = (try readMultipartByte(reader)) orelse return error.InvalidMultipartBody;
                if (tail_second == '\n') return .next;

                try emit_fn(emit_ctx, pending.items);
                pending.clearRetainingCapacity();
                try emit_fn(emit_ctx, "\r");
                reprocess = tail_second;
                continue;
            }

            try emit_fn(emit_ctx, pending.items);
            pending.clearRetainingCapacity();
            reprocess = tail_first;
        }
    }
}

fn readMultipartByte(reader: *BodyReader) SaveMultipartError!?u8 {
    var byte: [1]u8 = undefined;
    const n = try reader.read(&byte);
    if (n == 0) return null;
    return byte[0];
}

fn isPrefix(candidate: []const u8, pattern: []const u8) bool {
    return candidate.len <= pattern.len and std.mem.eql(u8, candidate, pattern[0..candidate.len]);
}

fn removeFirstByte(pending: *std.ArrayListUnmanaged(u8)) void {
    if (pending.items.len <= 1) {
        pending.items.len = 0;
        return;
    }
    std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - 1], pending.items[1..]);
    pending.items.len -= 1;
}

fn appendLimited(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
    limit: usize,
    err: anyerror,
) SaveMultipartError!void {
    if (out.items.len > limit or bytes.len > limit - out.items.len) return err;
    try out.appendSlice(allocator, bytes);
}

fn writeLimited(writer: *std.Io.Writer, bytes: []const u8, written: *usize, limit: usize) SaveMultipartError!void {
    if (written.* > limit or bytes.len > limit - written.*) return error.MultipartFileTooLarge;
    try writer.writeAll(bytes);
    written.* += bytes.len;
}

fn multipartBoundaryKind(line: []const u8, delimiter: []const u8) MultipartBoundary {
    const trimmed = trimLineEnding(line);
    if (!std.mem.startsWith(u8, trimmed, delimiter)) return .none;
    const tail = trimmed[delimiter.len..];
    if (tail.len == 0) return .next;
    if (std.mem.eql(u8, tail, "--")) return .done;
    return .none;
}

fn trimLineEnding(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r\n")) return line[0 .. line.len - 2];
    if (std.mem.endsWith(u8, line, "\n")) return line[0 .. line.len - 1];
    return line;
}

fn sanitizeMultipartFilename(allocator: std.mem.Allocator, filename: []const u8) std.mem.Allocator.Error![]const u8 {
    var basename = filename;
    if (std.mem.lastIndexOfScalar(u8, basename, '/')) |index| basename = basename[index + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, basename, '\\')) |index| basename = basename[index + 1 ..];
    if (basename.len == 0) basename = "upload";

    const out = try allocator.alloc(u8, basename.len);
    for (basename, 0..) |byte, index| {
        out[index] = switch (byte) {
            0...31, 127, ':', '*', '?', '"', '<', '>', '|', '/', '\\' => '_',
            else => byte,
        };
    }
    return out;
}

fn multipartUploadPath(allocator: std.mem.Allocator, dir_path: []const u8, file_index: usize, filename: []const u8) std.mem.Allocator.Error![]const u8 {
    if (dir_path.len == 0 or std.mem.eql(u8, dir_path, ".")) {
        return try std.fmt.allocPrint(allocator, "{d}-{s}", .{ file_index, filename });
    }
    return try std.fmt.allocPrint(allocator, "{s}/{d}-{s}", .{ dir_path, file_index, filename });
}

fn deinitSavedMultipartFields(allocator: std.mem.Allocator, fields: []SavedMultipartField) void {
    for (fields) |field| {
        deinitSavedMultipartField(allocator, field);
    }
}

fn deinitSavedMultipartField(allocator: std.mem.Allocator, field: SavedMultipartField) void {
    allocator.free(field.name);
    allocator.free(field.value);
}

fn deinitSavedMultipartFiles(allocator: std.mem.Allocator, files: []SavedMultipartFile) void {
    for (files) |file| {
        deinitSavedMultipartFile(allocator, file);
    }
}

fn deinitSavedMultipartFile(allocator: std.mem.Allocator, file: SavedMultipartFile) void {
    allocator.free(file.name);
    allocator.free(file.filename);
    allocator.free(file.path);
    if (file.content_type) |content_type| allocator.free(content_type);
}

test "request queryParam returns first matching value" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=zig&page=2&q=ignored";

    try std.testing.expectEqualStrings("zig", req.queryParam("q").?);
    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
    try std.testing.expect(req.queryParam("missing") == null);
}

test "request parseParams returns an aggregated params view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/users/42");
    req.params = &.{
        .{ .key = "id", .value = "41" },
        .{ .key = "id", .value = "42" },
        .{ .key = "tag[]", .value = "zig" },
        .{ .key = "tag[]", .value = "router" },
        .{ .key = "slug", .value = "readme" },
    };

    var parsed = try req.parseParams(.{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("42", parsed.value("id").?);
    try std.testing.expect(!parsed.get("id").?.isArray());
    try std.testing.expectEqualStrings("readme", parsed.value("slug").?);

    const tags = parsed.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
    try std.testing.expect(parsed.get("tag[]").?.isArray());
}

test "request parseParams all collects repeated keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.params = &.{
        .{ .key = "tag", .value = "zig" },
        .{ .key = "tag", .value = "web" },
        .{ .key = "tag", .value = "router" },
    };

    var parsed = try req.parseParams(.{
        .all = true,
    });
    defer parsed.deinit();

    const tags = parsed.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web", tags[1]);
    try std.testing.expectEqualStrings("router", tags[2]);
    try std.testing.expect(parsed.get("tag").?.isArray());
    try std.testing.expectEqualStrings("router", parsed.value("tag").?);
}

test "request cookie parses raw cookie header" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.cookies_raw = "session=abc; theme=dark";

    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}

test "request header lookup is case-insensitive" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-request-id", .value = "req-123" },
    };

    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("req-123", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("missing") == null);
}

test "request headerValues collects repeated case-insensitive matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.header_list = &.{
        .{ .name = "x-tag", .value = "zig" },
        .{ .name = "X-Tag", .value = "router" },
        .{ .name = "x-request-id", .value = "req-123" },
    };

    const values = try req.headerValues("x-tag");
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("router", values[1]);
}

test "request header .all returns a case-insensitive aggregated header view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.header_list = &.{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Set-Cookie", .value = "a=1" },
        .{ .name = "set-cookie", .value = "b=2" },
        .{ .name = "X-Mode", .value = "test" },
    };

    var parsed = try req.header(.all);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("application/json; charset=utf-8", parsed.value("content-type").?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", parsed.value("Content-Type").?);
    try std.testing.expectEqualStrings("test", parsed.value("x-mode").?);

    const cookies = parsed.values("set-cookie").?;
    try std.testing.expectEqual(@as(usize, 2), cookies.len);
    try std.testing.expectEqualStrings("a=1", cookies[0]);
    try std.testing.expectEqualStrings("b=2", cookies[1]);
    try std.testing.expect(parsed.get("set-cookie").?.isArray());

    try std.testing.expectEqualStrings("content-type", parsed.entriesSlice()[0].name);
}

test "request cookie falls back to cookie header" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.header_list = &.{
        .{ .name = "cookie", .value = "session=abc; theme=dark" },
    };

    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}

test "request cookies returns an aggregated cookie view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.cookies_raw = "session=abc; theme=dark; empty=; session=override";

    var parsed = try req.cookies();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("override", parsed.value("session").?);
    try std.testing.expectEqualStrings("dark", parsed.value("theme").?);
    try std.testing.expectEqualStrings("", parsed.value("empty").?);
}

test "request queries returns all matching values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "tag=zig&tag=web&tag&tag=router";

    const values = try req.queries("tag");
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web", values[1]);
    try std.testing.expectEqualStrings("", values[2]);
    try std.testing.expectEqualStrings("router", values[3]);
}

test "request decoded query helpers return owned decoded values" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=hello+world&tag=zig%20web&tag=router&encoded%20key=value%21";

    const q = (try req.queryDecoded("q")).?;
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("hello world", q);

    const encoded_key = (try req.queryParamDecoded("encoded key")).?;
    defer std.testing.allocator.free(encoded_key);
    try std.testing.expectEqualStrings("value!", encoded_key);

    var tags = try req.queriesDecoded("tag");
    defer tags.deinit();
    try std.testing.expectEqual(@as(usize, 2), tags.all().len);
    try std.testing.expectEqualStrings("zig web", tags.all()[0]);
    try std.testing.expectEqualStrings("router", tags.value().?);
}

test "request parseQuery returns an aggregated query view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "q=hello+world&tag=zig&tag=router&list%5B%5D=a&list%5B%5D=b&flag";

    var parsed = try req.parseQuery(.{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello world", parsed.value("q").?);
    try std.testing.expectEqualStrings("router", parsed.value("tag").?);
    try std.testing.expectEqualStrings("", parsed.value("flag").?);
    try std.testing.expect(!parsed.get("tag").?.isArray());

    const list_values = parsed.values("list[]").?;
    try std.testing.expectEqual(@as(usize, 2), list_values.len);
    try std.testing.expectEqualStrings("a", list_values[0]);
    try std.testing.expectEqualStrings("b", list_values[1]);
    try std.testing.expect(parsed.get("list[]").?.isArray());
}

test "request queryAll mirrors Hono no-argument aggregate query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "q=hello+world&tag=zig&tag=web";

    var query_all = try req.queryAll();
    defer query_all.deinit();
    try std.testing.expectEqualStrings("hello world", query_all.value("q").?);
    try std.testing.expectEqualStrings("web", query_all.value("tag").?);

    var decoded_all = try req.queryDecodedAll();
    defer decoded_all.deinit();
    try std.testing.expectEqualStrings("hello world", decoded_all.value("q").?);

    var collected = try req.queryAllWithOptions(.{
        .all = true,
    });
    defer collected.deinit();
    try std.testing.expectEqual(@as(usize, 2), collected.values("tag").?.len);
}

test "request parseQuery all collects repeated keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "tag=zig&tag=web&tag=router";

    var parsed = try req.parseQuery(.{
        .all = true,
    });
    defer parsed.deinit();

    const values = parsed.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web", values[1]);
    try std.testing.expectEqualStrings("router", values[2]);
    try std.testing.expect(parsed.get("tag").?.isArray());
}

test "request json parses typed payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.body_bytes = "{\"title\":\"hello\"}";

    const parsed = try req.json(struct { title: []const u8 });
    try std.testing.expectEqualStrings("hello", parsed.title);
}

test "request body helpers mirror Hono body readers" {
    var req = Request.init(std.testing.allocator, .POST, "/upload");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/octet-stream" },
    };
    req.body_bytes = "abc";

    try std.testing.expectEqualStrings("abc", req.text());
    try std.testing.expectEqualStrings("abc", req.arrayBuffer());

    const blob_value = req.blob();
    try std.testing.expectEqualStrings("abc", blob_value.data);
    try std.testing.expectEqualStrings("application/octet-stream", blob_value.content_type.?);
}

test "request bodyReader replays buffered bodies and enforces caller limits" {
    var req = Request.init(std.testing.allocator, .POST, "/upload");
    req.body_bytes = "abcdef";

    var reader = req.bodyReader();
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&buf));
    try std.testing.expectEqualStrings("ab", &buf);

    const remaining = try reader.readAllAlloc(std.testing.allocator, 4);
    defer std.testing.allocator.free(remaining);
    try std.testing.expectEqualStrings("cdef", remaining);

    var too_small = req.bodyReader();
    try std.testing.expectError(error.BodyTooLarge, too_small.readAllAlloc(std.testing.allocator, 5));
}

test "request live bodyReader reports limit aborts" {
    var io_reader = std.Io.Reader.fixed("abcdef");
    var aborted: std.atomic.Value(bool) = .init(false);
    var state = BodyState.init(&io_reader, 3, &aborted);
    var reader = BodyReader{ .source = .{ .live = &state } };

    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try reader.read(&buf));
    try std.testing.expectEqualStrings("abc", &buf);
    try std.testing.expectError(error.BodyTooLarge, reader.read(&buf));
    try std.testing.expect(reader.isAborted());
    try std.testing.expect(aborted.load(.acquire));
    try std.testing.expect(state.limit_exceeded);
}

test "request json and parseBody reject live bodies without buffering" {
    var io_reader = std.Io.Reader.fixed("{\"title\":\"hello\"}");
    var aborted: std.atomic.Value(bool) = .init(false);
    var state = BodyState.init(&io_reader, 1024, &aborted);

    var req = Request.init(std.testing.allocator, .POST, "/posts");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
    };
    req.body_state = &state;

    try std.testing.expectError(error.InvalidRequestBody, req.json(struct { title: []const u8 }));
    try std.testing.expectError(error.LiveBodyUnavailable, req.jsonParsed(struct { title: []const u8 }));
    try std.testing.expectError(error.LiveBodyUnavailable, req.parseBody(.{}));
}

test "request json accepts application json and vendor json media types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/problem+json; charset=utf-8" },
    };
    req.body_bytes = "{\"title\":\"hello\"}";

    const parsed = try req.json(struct { title: []const u8 });
    try std.testing.expectEqualStrings("hello", parsed.title);
}

test "request json and jsonParsed reject non-json content types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.header_list = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    };
    req.body_bytes = "{\"title\":\"hello\"}";

    try std.testing.expectError(error.UnsupportedRequestBody, req.json(struct { title: []const u8 }));
    try std.testing.expectError(error.UnsupportedContentType, req.jsonParsed(struct { title: []const u8 }));
}

test "request json maps business parse errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Body = struct {
        title: []const u8,
    };

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
    };
    req.body_bytes = "{\"title\":\"hello\"}";

    const body_value = try req.json(Body);
    try std.testing.expectEqualStrings("hello", body_value.title);

    var bad_req = Request.init(arena.allocator(), .POST, "/posts");
    bad_req.header_list = req.header_list;
    bad_req.body_bytes = "{";
    try std.testing.expectError(error.InvalidRequestBody, bad_req.json(Body));

    var wrong_type = Request.init(arena.allocator(), .POST, "/posts");
    wrong_type.header_list = &.{
        .{ .name = "content-type", .value = "text/plain" },
    };
    wrong_type.body_bytes = "{\"title\":\"hello\"}";
    try std.testing.expectError(error.UnsupportedRequestBody, wrong_type.json(Body));
}

test "request typed params and query helpers parse scalars" {
    const Sort = enum { asc, desc };

    var req = Request.init(std.testing.allocator, .GET, "/users/42");
    req.params = &.{
        .{ .key = "id", .value = "42" },
        .{ .key = "active", .value = "true" },
        .{ .key = "sort", .value = "desc" },
    };
    req.query_string = "page_size=20&enabled=1&sort=asc";

    try std.testing.expectEqual(@as(u64, 42), try req.paramInt(u64, "id"));
    try std.testing.expectEqual(true, try req.paramBool("active"));
    try std.testing.expectEqual(Sort.desc, try req.paramEnum(Sort, "sort"));
    try std.testing.expectEqual(@as(u64, 20), try req.queryInt(u64, "pageSize", .{ .alias = "page_size", .default = 10 }));
    try std.testing.expectEqual(true, try req.queryBool("enabled", .{}));
    try std.testing.expectEqual(Sort.asc, try req.queryEnum(Sort, "sort", .{}));
    try std.testing.expectEqual(@as(u64, 10), try req.queryInt(u64, "missing", .{ .default = 10 }));
    try std.testing.expectError(error.MissingQuery, req.queryInt(u64, "missing", .{}));
}

test "request contentType ignores parameters" {
    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };

    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", req.contentType().?);
    try std.testing.expect(req.hasContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(!req.hasContentType("application/json"));
}

test "request parseBody keeps the last scalar value and preserves array-like keys" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };
    parsed_req.body_bytes = "title=hello&title=updated&tag%5B%5D=zig&tag%5B%5D=router&empty";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("updated", body.value("title").?);
    try std.testing.expect(body.get("title").?.isArray() == false);

    const tags = body.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
    try std.testing.expect(body.get("tag[]").?.isArray());

    try std.testing.expectEqualStrings("", body.value("empty").?);
}

test "request formData is an alias for default parseBody" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    parsed_req.body_bytes = "title=hello";

    var body = try parsed_req.formData();
    defer body.deinit();

    try std.testing.expectEqualStrings("hello", body.value("title").?);
}

test "request parseBody all collects repeated scalar fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    parsed_req.body_bytes = "tag=zig&tag=web+toolkit&tag=router";

    var body = try parsed_req.parseBody(.{
        .all = true,
    });
    defer body.deinit();

    const tags = body.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web toolkit", tags[1]);
    try std.testing.expectEqualStrings("router", tags[2]);
    try std.testing.expect(body.get("tag").?.isArray());
    try std.testing.expectEqualStrings("router", body.value("tag").?);
}

test "request parseBody rejects unsupported content types" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
    };
    parsed_req.body_bytes = "{\"title\":\"hello\"}";

    try std.testing.expectError(error.UnsupportedContentType, parsed_req.parseBody(.{}));
}

test "request parseBody rejects invalid percent encoding" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    parsed_req.body_bytes = "name=%ZZ";

    try std.testing.expectError(error.InvalidPercentEncoding, parsed_req.parseBody(.{}));
}

test "request parseBody parses multipart text fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag[]\"\r\n\r\n" ++
        "zig\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag[]\"\r\n\r\n" ++
        "router\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello world", body.value("title").?);
    const tags = body.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
}

test "request parseBody multipart all collects repeated fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=\"zono-boundary\"" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" ++
        "zig\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" ++
        "web toolkit\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{
        .all = true,
    });
    defer body.deinit();

    const tags = body.values("tag").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web toolkit", tags[1]);
}

test "request parseBody multipart returns files directly" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello world", body.value("title").?);

    const avatar = body.file("avatar").?;
    try std.testing.expectEqualStrings("a.txt", avatar.filename);
    try std.testing.expectEqualStrings("text/plain", avatar.content_type.?);
    try std.testing.expectEqualStrings("hello", avatar.content);
}

test "request parseBody multipart ignores boundary-like bytes in content" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"body\"\r\n\r\n" ++
        "hello\r\n--zono-boundary-not-a-delimiter\r\nworld\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello\r\n--zono-boundary-not-a-delimiter\r\nworld", body.value("body").?);
}

test "request parseBody multipart ignores false final boundary in content" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"body\"\r\n\r\n" ++
        "hello\r\n--zono-boundary--not-final\r\nworld\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello\r\n--zono-boundary--not-final\r\nworld", body.value("body").?);
}

test "request parseBody multipart keeps semicolons inside quoted filenames" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a;b.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--zono-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    const avatar = body.file("avatar").?;
    try std.testing.expectEqualStrings("a;b.txt", avatar.filename);
}

test "request saveMultipartToDirIo streams files to disk" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    const expected_path = "0-stream.txt";
    std.Io.Dir.cwd().deleteFile(io, expected_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, expected_path) catch {};

    var req = Request.init(std.testing.allocator, .POST, "/upload");
    req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"stream.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "file body\nsecond line\r\n" ++
        "--zono-boundary--\r\n";

    var saved = try req.saveMultipartToDirIo(io, ".", .{});
    defer saved.deinit();

    try std.testing.expectEqual(@as(usize, 1), saved.fields.len);
    try std.testing.expectEqualStrings("title", saved.fields[0].name);
    try std.testing.expectEqualStrings("hello", saved.fields[0].value);
    try std.testing.expectEqual(@as(usize, 1), saved.files.len);
    try std.testing.expectEqualStrings("avatar", saved.files[0].name);
    try std.testing.expectEqualStrings("stream.txt", saved.files[0].filename);
    try std.testing.expectEqualStrings("text/plain", saved.files[0].content_type.?);
    try std.testing.expectEqualStrings(expected_path, saved.files[0].path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, saved.files[0].path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("file body\nsecond line", bytes);
}

test "request saveBodyToFileIo removes partial files on write failure" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    const path = "zono-partial-body-test.tmp";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var req = Request.init(std.testing.allocator, .POST, "/upload");
    req.body_bytes = "abcdef";

    try std.testing.expectError(error.BodyTooLarge, req.saveBodyToFileIo(io, path, .{ .max_bytes = 3 }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, path, .{}));
}

test "request saveMultipartToDirIo scans binary parts without line limits" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    const expected_path = "0-binary.bin";
    std.Io.Dir.cwd().deleteFile(io, expected_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, expected_path) catch {};

    const payload =
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    var req = Request.init(std.testing.allocator, .POST, "/upload");
    req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"blob\"; filename=\"binary.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++
        payload ++
        "\r\n--zono-boundary--\r\n";

    var saved = try req.saveMultipartToDirIo(io, ".", .{
        .max_line_bytes = 128,
    });
    defer saved.deinit();

    try std.testing.expectEqual(@as(usize, 1), saved.files.len);
    try std.testing.expectEqual(@as(usize, payload.len), saved.files[0].size);
    try std.testing.expectEqualStrings(expected_path, saved.files[0].path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, saved.files[0].path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(payload, bytes);
}

test "request parseBody rejects malformed multipart boundaries" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    parsed_req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n";

    try std.testing.expectError(error.InvalidMultipartBody, parsed_req.parseBody(.{}));
}

test "request param .all returns an aggregated params view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/users/42");
    req.params = &.{
        .{ .key = "id", .value = "42" },
        .{ .key = "tag[]", .value = "zig" },
        .{ .key = "tag[]", .value = "router" },
    };

    var parsed = try req.param(.all);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("42", parsed.value("id").?);
    try std.testing.expectEqual(@as(usize, 2), parsed.values("tag[]").?.len);
}

test "request query .all returns a parsed query view" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=zig&tag=router&tag=web";

    var parsed = try req.query(.all);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zig", parsed.value("q").?);
    try std.testing.expectEqualStrings("web", parsed.value("tag").?);
}

test "request cookie .all returns an aggregated cookie view" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.cookies_raw = "session=abc; theme=dark";

    var parsed = try req.cookie(.all);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("abc", parsed.value("session").?);
    try std.testing.expectEqualStrings("dark", parsed.value("theme").?);
}

test "request builds target and url from path query and host" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=zig";
    req.header_list = &.{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "x-forwarded-proto", .value = "https" },
    };

    const target_value = try req.target(std.testing.allocator);
    defer std.testing.allocator.free(target_value);
    try std.testing.expectEqualStrings("/search?q=zig", target_value);

    const url_value = try req.url(std.testing.allocator, null);
    defer std.testing.allocator.free(url_value);
    try std.testing.expectEqualStrings("https://example.com/search?q=zig", url_value);
}

test "request cloneRawRequest keeps replayable body and headers" {
    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.query_string = "a=1";
    req.body_bytes = "payload";
    req.header_list = &.{
        .{ .name = "content-type", .value = "text/plain" },
    };

    _ = req.text();
    var raw_req = try req.cloneRawRequest(std.testing.allocator);
    defer raw_req.deinit();

    try std.testing.expectEqualStrings("POST", raw_req.method_name);
    try std.testing.expectEqualStrings("/submit", raw_req.path);
    try std.testing.expectEqualStrings("payload", raw_req.body_bytes);
    try std.testing.expectEqualStrings("content-type", raw_req.headers[0].name);

    var stream = raw_req.bodyStream();
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), stream.read(&buffer));
    try std.testing.expectEqualStrings("payl", &buffer);
    try std.testing.expectEqualStrings("oad", stream.readAll());
}

test "request parseQuery dot groups nested keys" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "user.name=hyird&user.role=admin";

    var parsed = try req.parseQuery(.{
        .dot = true,
    });
    defer parsed.deinit();

    var user = try parsed.group("user");
    defer user.deinit();

    try std.testing.expectEqualStrings("hyird", user.value("name").?);
    try std.testing.expectEqualStrings("admin", user.value("role").?);
}

test "request parseBody dot groups nested fields and files" {
    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zono-boundary" },
    };
    req.body_bytes =
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"user.name\"\r\n\r\n" ++
        "hyird\r\n" ++
        "--zono-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"user.avatar\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--zono-boundary--\r\n";

    var parsed = try req.parseBody(.{
        .dot = true,
    });
    defer parsed.deinit();

    var user = try parsed.group("user");
    defer user.deinit();

    try std.testing.expectEqualStrings("hyird", user.value("name").?);
    const avatar = user.file("avatar").?;
    try std.testing.expectEqualStrings("a.txt", avatar.filename);
    try std.testing.expectEqualStrings("hello", avatar.content);
}

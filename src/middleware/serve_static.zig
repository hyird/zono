const std = @import("std");
const app_mod = @import("../app/app.zig");
const Context = @import("../core/context.zig").Context;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const http_method = @import("../core/http_method.zig");

pub const Options = struct {
    root: []const u8 = ".",
    prefix: []const u8 = "",
    index: []const u8 = "index.html",
    max_file_bytes: u64 = 64 * 1024 * 1024,
    fallthrough: bool = true,
    cache_control: ?[]const u8 = null,
    spa_fallback: ?[]const u8 = null,
    spa_fallback_cache_control: ?[]const u8 = null,
    html_accept_required: bool = true,
    extensionless_only: bool = true,
};

const MiddlewareFn = fn (c: *Context, next: Context.Next) Response;

pub fn serveStatic(comptime static_options: Options) MiddlewareFn {
    validateStaticOptions(static_options);

    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            if (!isStaticMethod(c.req.methodName())) {
                next.run();
                return c.takeResponse();
            }

            var fallback_io_impl = std.Io.Threaded.init_single_threaded;
            const io = c.io() orelse fallback_io_impl.io();

            const static_response = prepareStaticRequest(c, io, c.req.path, static_options) catch |err| switch (err) {
                error.StaticPrefixMismatch, error.UnsafeStaticPath => {
                    if (static_options.fallthrough) {
                        next.run();
                        return c.takeResponse();
                    }
                    return c.notFound();
                },
                else => return staticErrorResponse(c, err),
            };
            if (static_response) |res| return res;

            if (static_options.spa_fallback == null) {
                if (static_options.fallthrough) {
                    next.run();
                    return c.takeResponse();
                }
                return c.notFound();
            }

            if (!static_options.fallthrough) {
                if (shouldServeSpaFallback(c, .not_found, static_options)) {
                    return serveSpaFallback(c, io, static_options);
                }
                return c.notFound();
            }

            next.run();
            var downstream = c.takeResponse();
            if (!shouldServeSpaFallback(c, downstream.status, static_options)) return downstream;
            downstream.deinit();
            return serveSpaFallback(c, io, static_options);
        }
    }.run;
}

const StaticError = error{
    StaticPrefixMismatch,
    UnsafeStaticPath,
    FileNotFound,
    FileTooLarge,
    StatFailed,
    OutOfMemory,
};

const ResolvedPath = struct {
    path: []u8,
    try_index: bool = false,

    fn deinit(self: *ResolvedPath, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const PreparedResponse = struct {
    response: Response,
};

const ByteRange = struct {
    start: u64,
    end: u64,

    fn length(self: ByteRange) u64 {
        return self.end - self.start + 1;
    }
};

const RangeDecision = union(enum) {
    ignore,
    unsatisfiable,
    range: ByteRange,
};

fn prepareStaticRequest(
    c: *Context,
    io: std.Io,
    request_path: []const u8,
    comptime static_options: Options,
) StaticError!?Response {
    var candidate = try resolvePath(c.req.allocator, request_path, static_options);
    defer candidate.deinit(c.req.allocator);

    const prepared = prepareFileResponse(c, io, candidate.path, static_options) catch |err| switch (err) {
        error.FileNotFound => {
            if (candidate.try_index) {
                const index_path = try appendIndexPath(c.req.allocator, candidate.path, static_options.index);
                defer c.req.allocator.free(index_path);
                const index_prepared = prepareFileResponse(c, io, index_path, static_options) catch |index_err| switch (index_err) {
                    error.FileNotFound => return null,
                    else => return index_err,
                };
                return index_prepared.response;
            }
            return null;
        },
        else => return err,
    };
    return prepared.response;
}

fn serveSpaFallback(c: *Context, io: std.Io, comptime static_options: Options) Response {
    const fallback = static_options.spa_fallback orelse unreachable;
    const index_options = comptime optionsWithCacheControl(static_options, static_options.spa_fallback_cache_control);
    const fallback_path = joinStaticPath(c.req.allocator, static_options.root, fallback) catch
        return response_mod.internalError("serveStatic SPA fallback allocation failed");
    defer c.req.allocator.free(fallback_path);

    const prepared = prepareFileResponse(c, io, fallback_path, index_options) catch |err| switch (err) {
        error.FileNotFound => return c.notFound(),
        else => return staticErrorResponse(c, err),
    };
    return prepared.response;
}

fn resolvePath(allocator: std.mem.Allocator, request_path: []const u8, comptime static_options: Options) StaticError!ResolvedPath {
    const relative_raw = stripPrefix(request_path, static_options.prefix) orelse return error.StaticPrefixMismatch;
    const decoded_owned = try decodePath(allocator, relative_raw);
    defer allocator.free(decoded_owned);
    var decoded = decoded_owned;

    while (decoded.len > 0 and decoded[0] == '/') decoded = decoded[1..];
    if (!safeRelativePath(decoded)) return error.UnsafeStaticPath;

    const use_index = decoded.len == 0 or decoded[decoded.len - 1] == '/';
    const relative = if (use_index)
        try appendIndexPath(allocator, decoded, static_options.index)
    else
        try allocator.dupe(u8, decoded);
    defer allocator.free(relative);

    return .{
        .path = try joinStaticPath(allocator, static_options.root, relative),
        .try_index = !use_index and static_options.index.len != 0,
    };
}

fn stripPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) return path;
    if (std.mem.eql(u8, path, prefix)) return "";
    if (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/') {
        return path[prefix.len + 1 ..];
    }
    return null;
}

fn prepareFileResponse(
    c: *Context,
    io: std.Io,
    path: []u8,
    comptime static_options: Options,
) StaticError!PreparedResponse {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    const stat = file.stat(io) catch return error.StatFailed;
    const file_size = stat.size;
    if (file_size > static_options.max_file_bytes) return error.FileTooLarge;

    const etag = try makeEtag(c.req.allocator, path, stat);
    defer c.req.allocator.free(etag);
    const last_modified = try formatHttpDate(c.req.allocator, stat.mtime);
    defer c.req.allocator.free(last_modified);

    if (c.req.header("if-none-match")) |incoming| {
        if (etagMatches(incoming, etag)) {
            return .{ .response = try notModifiedResponse(c.req.allocator, etag, last_modified, static_options.cache_control) };
        }
    } else if (c.req.header("if-modified-since")) |incoming| {
        if (modifiedSinceSatisfied(incoming, stat.mtime)) {
            return .{ .response = try notModifiedResponse(c.req.allocator, etag, last_modified, static_options.cache_control) };
        }
    }

    const content_type = mimeType(path);
    const range_decision = rangeDecision(c, file_size, etag, last_modified);
    switch (range_decision) {
        .unsatisfiable => {
            const content_range = try makeUnsatisfiedContentRange(c.req.allocator, file_size);
            defer c.req.allocator.free(content_range);

            var res = Response{
                .status = .range_not_satisfiable,
                .content_type = "",
            };
            try res.ensureOwned(c.req.allocator);
            _ = res.header("Accept-Ranges", "bytes");
            _ = res.header("Content-Range", content_range);
            _ = res.header("ETag", etag);
            _ = res.header("Last-Modified", last_modified);
            if (static_options.cache_control) |cache_control| {
                _ = res.header("Cache-Control", cache_control);
            }
            return .{ .response = res };
        },
        else => {},
    }

    const owned_path = try c.req.allocator.dupe(u8, path);
    errdefer c.req.allocator.free(owned_path);

    const range = switch (range_decision) {
        .range => |value| value,
        else => null,
    };
    var res = response_mod.file(owned_path, content_type, .{
        .status = if (range != null) .partial_content else .ok,
        .max_bytes = static_options.max_file_bytes,
        .head_only = http_method.isHead(c.req.methodName()),
        .offset = if (range) |r| r.start else 0,
        .length = if (range) |r| r.length() else file_size,
        .known_size = file_size,
    });
    res.body_kind.file.path_owner = c.req.allocator;
    try res.ensureOwned(c.req.allocator);
    _ = res.header("Accept-Ranges", "bytes");
    _ = res.header("ETag", etag);
    _ = res.header("Last-Modified", last_modified);
    if (range) |r| {
        const content_range = try makeContentRange(c.req.allocator, r, file_size);
        defer c.req.allocator.free(content_range);
        _ = res.header("Content-Range", content_range);
    }
    if (static_options.cache_control) |cache_control| {
        _ = res.header("Cache-Control", cache_control);
    }
    return .{
        .response = res,
    };
}

fn notModifiedResponse(
    allocator: std.mem.Allocator,
    etag: []const u8,
    last_modified: []const u8,
    cache_control: ?[]const u8,
) std.mem.Allocator.Error!Response {
    var res = Response{
        .status = .not_modified,
        .content_type = "",
    };
    try res.ensureOwned(allocator);
    _ = res.header("Accept-Ranges", "bytes");
    _ = res.header("ETag", etag);
    _ = res.header("Last-Modified", last_modified);
    if (cache_control) |value| {
        _ = res.header("Cache-Control", value);
    }
    return res;
}

fn staticErrorResponse(c: *Context, err: StaticError) Response {
    return switch (err) {
        error.FileTooLarge => c.text(.{ "File Too Large", .payload_too_large }),
        error.StatFailed => response_mod.internalError("serveStatic stat failed"),
        else => response_mod.internalError("serveStatic failed"),
    };
}

fn appendIndexPath(allocator: std.mem.Allocator, path: []const u8, index: []const u8) std.mem.Allocator.Error![]u8 {
    if (index.len == 0) return try allocator.dupe(u8, path);
    if (path.len == 0) return try allocator.dupe(u8, index);
    if (path[path.len - 1] == '/') return try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, index });
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, index });
}

fn joinStaticPath(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) std.mem.Allocator.Error![]u8 {
    if (relative.len == 0) return try allocator.dupe(u8, root);
    if (root.len == 0 or std.mem.eql(u8, root, ".")) return try allocator.dupe(u8, relative);
    if (root[root.len - 1] == '/' or root[root.len - 1] == '\\') {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, relative });
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative });
}

fn decodePath(allocator: std.mem.Allocator, raw: []const u8) (std.mem.Allocator.Error || error{UnsafeStaticPath})![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '%') {
            try out.append(allocator, raw[index]);
            index += 1;
            continue;
        }

        if (index + 2 >= raw.len) return error.UnsafeStaticPath;
        const hi = std.fmt.charToDigit(raw[index + 1], 16) catch return error.UnsafeStaticPath;
        const lo = std.fmt.charToDigit(raw[index + 2], 16) catch return error.UnsafeStaticPath;
        try out.append(allocator, @intCast(hi * 16 + lo));
        index += 3;
    }

    return try out.toOwnedSlice(allocator);
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn validateStaticOptions(comptime static_options: Options) void {
    if (static_options.spa_fallback) |fallback| {
        if (!safeRelativePath(fallback)) {
            @compileError("serveStatic .spa_fallback must be a safe relative path under .root");
        }
    }
}

fn optionsWithCacheControl(comptime static_options: Options, comptime cache_control: ?[]const u8) Options {
    var options = static_options;
    options.cache_control = cache_control;
    options.spa_fallback = null;
    return options;
}

fn isStaticMethod(method_name: []const u8) bool {
    return http_method.isGetOrHead(method_name);
}

fn shouldServeSpaFallback(c: *Context, status: std.http.Status, comptime static_options: Options) bool {
    if (status != .not_found) return false;
    if (stripPrefix(c.req.path, static_options.prefix) == null) return false;
    if (static_options.extensionless_only and requestPathHasExtension(c.req.path)) return false;
    if (static_options.html_accept_required and !acceptsHtml(c.req.header("accept"))) return false;
    return true;
}

fn acceptsHtml(accept_header: ?[]const u8) bool {
    const header = accept_header orelse return true;
    var iter = std.mem.splitScalar(u8, header, ',');
    while (iter.next()) |part| {
        const media = std.mem.trim(u8, part[0 .. std.mem.indexOfScalar(u8, part, ';') orelse part.len], " \t");
        if (std.ascii.eqlIgnoreCase(media, "text/html") or
            std.ascii.eqlIgnoreCase(media, "application/xhtml+xml"))
        {
            return true;
        }
    }
    return false;
}

fn requestPathHasExtension(path: []const u8) bool {
    var normalized = path;
    while (normalized.len > 1 and normalized[normalized.len - 1] == '/') {
        normalized = normalized[0 .. normalized.len - 1];
    }
    return extension(normalized).len != 0;
}

fn makeEtag(allocator: std.mem.Allocator, path: []const u8, stat: std.Io.File.Stat) std.mem.Allocator.Error![]u8 {
    const path_hash = std.hash.Wyhash.hash(0, path);
    return try std.fmt.allocPrint(
        allocator,
        "W/\"{x}-{x}-{x}-{x}-{x}\"",
        .{ path_hash, stat.size, stat.mtime.nanoseconds, stat.ctime.nanoseconds, stat.inode },
    );
}

fn etagMatches(header_value: []const u8, etag: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |candidate_raw| {
        const candidate = std.mem.trim(u8, candidate_raw, " \t");
        if (std.mem.eql(u8, candidate, "*")) return true;
        if (std.mem.eql(u8, candidate, etag)) return true;
        if (std.mem.startsWith(u8, candidate, "W/") and std.mem.eql(u8, candidate[2..], etag)) return true;
        if (std.mem.startsWith(u8, etag, "W/") and std.mem.eql(u8, candidate, etag[2..])) return true;
    }
    return false;
}

fn modifiedSinceSatisfied(header_value: []const u8, mtime: std.Io.Timestamp) bool {
    const since = parseHttpDateSeconds(header_value) orelse return false;
    return since >= timestampSeconds(mtime);
}

fn timestampSeconds(timestamp: std.Io.Timestamp) u64 {
    const seconds = timestamp.toSeconds();
    if (seconds <= 0) return 0;
    return @intCast(seconds);
}

fn rangeDecision(c: *Context, file_size: u64, etag: []const u8, last_modified: []const u8) RangeDecision {
    const range_header = c.req.header("range") orelse return .ignore;
    if (!ifRangeAllowsRange(c.req.header("if-range"), etag, last_modified)) return .ignore;
    return parseRangeHeader(range_header, file_size);
}

fn ifRangeAllowsRange(if_range: ?[]const u8, etag: []const u8, last_modified: []const u8) bool {
    const value = std.mem.trim(u8, if_range orelse return true, " \t");
    if (value.len == 0) return true;
    if (etagMatches(value, etag)) return true;
    return std.mem.eql(u8, value, last_modified);
}

fn parseRangeHeader(header_value: []const u8, file_size: u64) RangeDecision {
    const trimmed = std.mem.trim(u8, header_value, " \t");
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return .ignore;
    const spec = std.mem.trim(u8, trimmed["bytes=".len..], " \t");
    if (spec.len == 0 or std.mem.indexOfScalar(u8, spec, ',') != null) return .ignore;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;
    const start_raw = std.mem.trim(u8, spec[0..dash], " \t");
    const end_raw = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    if (start_raw.len == 0) {
        if (end_raw.len == 0) return .ignore;
        const suffix_len = std.fmt.parseInt(u64, end_raw, 10) catch return .ignore;
        if (suffix_len == 0) return .unsatisfiable;
        if (file_size == 0) return .unsatisfiable;
        const start = if (suffix_len >= file_size) 0 else file_size - suffix_len;
        return .{ .range = .{ .start = start, .end = file_size - 1 } };
    }

    const start = std.fmt.parseInt(u64, start_raw, 10) catch return .ignore;
    if (file_size == 0 or start >= file_size) return .unsatisfiable;

    const end = if (end_raw.len == 0)
        file_size - 1
    else
        std.fmt.parseInt(u64, end_raw, 10) catch return .ignore;
    if (end < start) return .unsatisfiable;

    return .{ .range = .{
        .start = start,
        .end = @min(end, file_size - 1),
    } };
}

fn makeContentRange(allocator: std.mem.Allocator, range: ByteRange, file_size: u64) std.mem.Allocator.Error![]u8 {
    return try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ range.start, range.end, file_size });
}

fn makeUnsatisfiedContentRange(allocator: std.mem.Allocator, file_size: u64) std.mem.Allocator.Error![]u8 {
    return try std.fmt.allocPrint(allocator, "bytes */{d}", .{file_size});
}

fn formatHttpDate(allocator: std.mem.Allocator, timestamp: std.Io.Timestamp) std.mem.Allocator.Error![]u8 {
    const seconds = timestampSeconds(timestamp);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const weekday = weekdayName(@intCast((epoch_day.day + 4) % 7));

    return try std.fmt.allocPrint(
        allocator,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekday,
            month_day.day_index + 1,
            monthName(month_day.month),
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn parseHttpDateSeconds(header_value: []const u8) ?u64 {
    const value = std.mem.trim(u8, header_value, " \t");
    if (value.len != 29) return null;
    if (value[3] != ',' or value[4] != ' ' or value[7] != ' ' or value[11] != ' ' or
        value[16] != ' ' or value[19] != ':' or value[22] != ':' or value[25] != ' ')
    {
        return null;
    }
    if (!std.mem.eql(u8, value[26..29], "GMT")) return null;

    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const month = monthFromName(value[8..11]) orelse return null;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return null;

    if (year < std.time.epoch.epoch_year or day == 0 or hour > 23 or minute > 59 or second > 59) return null;
    const days_in_month = std.time.epoch.getDaysInMonth(year, month);
    if (day > days_in_month) return null;

    var days: u64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }
    var m: std.time.epoch.Month = .jan;
    while (@intFromEnum(m) < @intFromEnum(month)) : (m = @enumFromInt(@intFromEnum(m) + 1)) {
        days += std.time.epoch.getDaysInMonth(year, m);
    }
    days += day - 1;

    return days * std.time.epoch.secs_per_day +
        @as(u64, hour) * 3600 +
        @as(u64, minute) * 60 +
        second;
}

fn weekdayName(index: u3) []const u8 {
    return switch (index) {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        7 => unreachable,
    };
}

fn monthName(month: std.time.epoch.Month) []const u8 {
    return switch (month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

fn monthFromName(name: []const u8) ?std.time.epoch.Month {
    if (std.mem.eql(u8, name, "Jan")) return .jan;
    if (std.mem.eql(u8, name, "Feb")) return .feb;
    if (std.mem.eql(u8, name, "Mar")) return .mar;
    if (std.mem.eql(u8, name, "Apr")) return .apr;
    if (std.mem.eql(u8, name, "May")) return .may;
    if (std.mem.eql(u8, name, "Jun")) return .jun;
    if (std.mem.eql(u8, name, "Jul")) return .jul;
    if (std.mem.eql(u8, name, "Aug")) return .aug;
    if (std.mem.eql(u8, name, "Sep")) return .sep;
    if (std.mem.eql(u8, name, "Oct")) return .oct;
    if (std.mem.eql(u8, name, "Nov")) return .nov;
    if (std.mem.eql(u8, name, "Dec")) return .dec;
    return null;
}

fn mimeType(path: []const u8) []const u8 {
    const ext = extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application/pdf";
    return "application/octet-stream";
}

fn extension(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const start = if (slash == 0 and (path.len == 0 or path[0] != '/')) 0 else slash + 1;
    const dot = std.mem.lastIndexOfScalar(u8, path[start..], '.') orelse return "";
    return path[start + dot ..];
}

test "serveStatic rejects unsafe relative paths" {
    try std.testing.expect(!safeRelativePath("../secret"));
    try std.testing.expect(!safeRelativePath("a/../secret"));
    try std.testing.expect(!safeRelativePath("C:/secret"));
    try std.testing.expect(safeRelativePath("assets/app.js"));
}

test "serveStatic resolves prefix and index" {
    var resolved = try resolvePath(std.testing.allocator, "/static/", .{
        .root = "public",
        .prefix = "/static",
    });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("public/index.html", resolved.path);

    var file = try resolvePath(std.testing.allocator, "/static/css/app.css", .{
        .root = "public",
        .prefix = "/static",
    });
    defer file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("public/css/app.css", file.path);
}

test "serveStatic serves files through app.request" {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file_path = ".zig-cache/zono-serve-static-test.txt";

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    var file_buffer: [64]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &file_buffer);
    try writer.interface.writeAll("static-ok");
    try writer.end();
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{
        .root = ".zig-cache",
        .prefix = "/assets",
    }));

    var res = try app.request(std.testing.allocator, "/assets/zono-serve-static-test.txt", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("static-ok", res.bodyBytes());
    try std.testing.expect(res.headerValue("etag") != null);
    try std.testing.expect(res.headerValue("last-modified") != null);
    try std.testing.expectEqualStrings("bytes", res.headerValue("accept-ranges").?);
}

test "serveStatic handles conditional and range requests" {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file_path = ".zig-cache/zono-serve-static-range.txt";

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    var file_buffer: [64]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &file_buffer);
    try writer.interface.writeAll("static-ok");
    try writer.end();
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{
        .root = ".zig-cache",
        .prefix = "/assets",
    }));

    var full = try app.request(std.testing.allocator, "/assets/zono-serve-static-range.txt", .{});
    defer full.deinit();
    const last_modified = full.headerValue("last-modified").?;

    var not_modified = try app.request(std.testing.allocator, "/assets/zono-serve-static-range.txt", .{
        .headers = &.{.{ .name = "If-Modified-Since", .value = last_modified }},
    });
    defer not_modified.deinit();
    try std.testing.expectEqual(std.http.Status.not_modified, not_modified.status);
    try std.testing.expectEqualStrings("", not_modified.bodyBytes());

    var partial = try app.request(std.testing.allocator, "/assets/zono-serve-static-range.txt", .{
        .headers = &.{.{ .name = "Range", .value = "bytes=2-5" }},
    });
    defer partial.deinit();
    try std.testing.expectEqual(std.http.Status.partial_content, partial.status);
    try std.testing.expectEqualStrings("atic", partial.bodyBytes());
    try std.testing.expectEqualStrings("bytes 2-5/9", partial.headerValue("content-range").?);

    var suffix = try app.request(std.testing.allocator, "/assets/zono-serve-static-range.txt", .{
        .headers = &.{.{ .name = "Range", .value = "bytes=-2" }},
    });
    defer suffix.deinit();
    try std.testing.expectEqual(std.http.Status.partial_content, suffix.status);
    try std.testing.expectEqualStrings("ok", suffix.bodyBytes());
    try std.testing.expectEqualStrings("bytes 7-8/9", suffix.headerValue("content-range").?);

    var unsatisfied = try app.request(std.testing.allocator, "/assets/zono-serve-static-range.txt", .{
        .headers = &.{.{ .name = "Range", .value = "bytes=99-100" }},
    });
    defer unsatisfied.deinit();
    try std.testing.expectEqual(std.http.Status.range_not_satisfiable, unsatisfied.status);
    try std.testing.expectEqualStrings("bytes */9", unsatisfied.headerValue("content-range").?);
}

test "serveStatic supports SPA history fallback" {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const index_path = ".zig-cache/zono-spa-index.html";
    const asset_path = ".zig-cache/zono-spa-app.js";

    var index_file = try std.Io.Dir.cwd().createFile(io, index_path, .{});
    var index_buffer: [64]u8 = undefined;
    var index_writer = std.Io.File.Writer.init(index_file, io, &index_buffer);
    try index_writer.interface.writeAll("<html>spa</html>");
    try index_writer.end();
    index_file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};

    var asset_file = try std.Io.Dir.cwd().createFile(io, asset_path, .{});
    var asset_buffer: [64]u8 = undefined;
    var asset_writer = std.Io.File.Writer.init(asset_file, io, &asset_buffer);
    try asset_writer.interface.writeAll("console.log('spa')");
    try asset_writer.end();
    asset_file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, asset_path) catch {};

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{
        .root = ".zig-cache",
        .cache_control = "public, max-age=31536000, immutable",
        .spa_fallback = "zono-spa-index.html",
        .spa_fallback_cache_control = "no-cache",
    }));
    try app.get("/api/users", struct {
        fn run(c: *Context) Response {
            return c.text("api");
        }
    }.run);

    var asset = try app.request(std.testing.allocator, "/zono-spa-app.js", .{});
    defer asset.deinit();
    try std.testing.expectEqualStrings("console.log('spa')", asset.bodyBytes());
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", asset.headerValue("cache-control").?);

    var api = try app.request(std.testing.allocator, "/api/users", .{
        .headers = &.{.{ .name = "accept", .value = "text/html" }},
    });
    defer api.deinit();
    try std.testing.expectEqualStrings("api", api.bodyBytes());

    var page = try app.request(std.testing.allocator, "/dashboard/settings", .{
        .headers = &.{.{ .name = "accept", .value = "text/html" }},
    });
    defer page.deinit();
    try std.testing.expectEqual(std.http.Status.ok, page.status);
    try std.testing.expectEqualStrings("<html>spa</html>", page.bodyBytes());
    try std.testing.expectEqualStrings("no-cache", page.headerValue("cache-control").?);

    var missing_asset = try app.request(std.testing.allocator, "/missing.js", .{
        .headers = &.{.{ .name = "accept", .value = "text/html" }},
    });
    defer missing_asset.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, missing_asset.status);

    var json_navigation = try app.request(std.testing.allocator, "/dashboard", .{
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer json_navigation.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, json_navigation.status);
}

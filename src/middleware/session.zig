const std = @import("std");
const app_mod = @import("../app/app.zig");
const Context = @import("../core/context.zig").Context;
const Response = @import("../response/response.zig").Response;
const response_mod = @import("../response/response.zig");
const core_meta = @import("../core/meta.zig");
const time = @import("../core/time.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const context_key = "zono.session";
pub const manager_context_key = "zono.session_manager";

pub const Options = struct {
    cookie_name: []const u8 = "ZONO_SESSION",
    context_key: []const u8 = context_key,
    manager_context_key: []const u8 = manager_context_key,
    max_age_seconds: u64 = 3600,
    gc_interval_seconds: u64 = 300,
    max_sessions: usize = 100_000,
    path: []const u8 = "/",
    domain: ?[]const u8 = null,
    http_only: bool = true,
    secure: bool = true,
    same_site: ?response_mod.SameSite = .lax,
    priority: ?response_mod.CookiePriority = null,
    partitioned: bool = false,
    /// Optional HMAC-SHA256 secret. When set, the cookie value becomes
    /// `<session-id>.<signature>` and unsigned/tampered cookies are ignored.
    signing_secret: ?[]const u8 = null,
};

const ValueEntry = struct {
    value: *anyopaque,
    type_name: []const u8,
    deinit_fn: *const fn (allocator: std.mem.Allocator, value: *anyopaque) void,
};

const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

var fallback_counter = std.atomic.Value(u64).init(0);

pub const Session = struct {
    allocator: std.mem.Allocator,
    id_value: []u8,
    old_id_values: std.ArrayListUnmanaged([]u8) = .empty,
    values: std.StringHashMapUnmanaged(ValueEntry) = .empty,
    lock_value: SpinLock = .{},
    expires_at_seconds: u64,
    dirty: bool = false,
    active_refs: usize = 0,
    retired: bool = false,
    retired_next: ?*Session = null,

    pub fn id(self: *Session) []const u8 {
        return self.id_value;
    }

    pub fn set(self: *Session, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        try putValue(self.allocator, &self.values, key, value);
        self.dirty = true;
    }

    pub fn get(self: *Session, comptime T: type, key: []const u8) ?T {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        return getValue(T, &self.values, key);
    }

    pub fn contains(self: *Session, key: []const u8) bool {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        return self.values.contains(key);
    }

    pub fn delete(self: *Session, key: []const u8) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        if (self.values.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            removed.value.deinit_fn(self.allocator, removed.value.value);
            self.dirty = true;
        }
    }

    pub fn clear(self: *Session) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        deinitValues(self.allocator, &self.values);
        self.dirty = true;
    }

    fn init(allocator: std.mem.Allocator, id_value: []u8, expires_at_seconds: u64) Session {
        return .{
            .allocator = allocator,
            .id_value = id_value,
            .expires_at_seconds = expires_at_seconds,
        };
    }

    fn deinit(self: *Session) void {
        const allocator = self.allocator;
        deinitValues(allocator, &self.values);
        for (self.old_id_values.items) |old_id| allocator.free(old_id);
        self.old_id_values.deinit(allocator);
        allocator.free(self.id_value);
        self.* = undefined;
    }

    fn isExpired(self: *Session, now_seconds: u64) bool {
        return now_seconds >= self.expires_at_seconds;
    }

    fn touch(self: *Session, now_seconds: u64, options: Options) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        self.expires_at_seconds = now_seconds + options.max_age_seconds;
    }

    fn isDirty(self: *Session) bool {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        return self.dirty;
    }

    fn markClean(self: *Session) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        self.dirty = false;
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    options: Options = .{},
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    retired_sessions: ?*Session = null,
    lock_value: SpinLock = .{},
    last_gc_seconds: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) SessionManager {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            destroySession(self.allocator, entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
        self.sessions = .empty;

        while (self.retired_sessions) |session_ptr| {
            self.retired_sessions = session_ptr.retired_next;
            destroySession(self.allocator, session_ptr);
        }
    }

    pub fn find(self: *SessionManager, id_value: []const u8) ?*Session {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        return self.findLocked(id_value, true);
    }

    fn findRetained(self: *SessionManager, id_value: []const u8) ?*Session {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        return self.findLocked(id_value, true);
    }

    fn findLocked(self: *SessionManager, id_value: []const u8, comptime retained: bool) ?*Session {
        const now = time.nowSeconds();
        const session_ptr = self.sessions.get(id_value) orelse return null;
        if (session_ptr.isExpired(now)) {
            _ = self.sessions.remove(id_value);
            retireSession(self, session_ptr);
            return null;
        }

        session_ptr.touch(now, self.options);
        if (retained) retainSession(session_ptr);
        return session_ptr;
    }

    pub fn findCookie(self: *SessionManager, cookie_value: []const u8) ?*Session {
        const id_value = verifySessionCookie(self.options, cookie_value) orelse return null;
        return self.find(id_value);
    }

    fn findCookieRetained(self: *SessionManager, cookie_value: []const u8) ?*Session {
        const id_value = verifySessionCookie(self.options, cookie_value) orelse return null;
        return self.findRetained(id_value);
    }

    pub fn create(self: *SessionManager, io: ?std.Io) std.mem.Allocator.Error!?*Session {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        return try self.createLocked(io, true);
    }

    fn createRetained(self: *SessionManager, io: ?std.Io) std.mem.Allocator.Error!?*Session {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        return try self.createLocked(io, true);
    }

    fn createLocked(self: *SessionManager, io: ?std.Io, comptime retained: bool) std.mem.Allocator.Error!?*Session {
        const now = time.nowSeconds();
        if (shouldGc(self, now)) gcLocked(self, now);
        if (self.options.max_sessions != 0 and self.sessions.count() >= self.options.max_sessions) {
            gcLocked(self, now);
            if (self.sessions.count() >= self.options.max_sessions) return null;
        }

        var id_value = try generateId(self.allocator, io);
        var id_value_transferred = false;
        errdefer if (!id_value_transferred) self.allocator.free(id_value);
        while (self.sessions.contains(id_value)) {
            self.allocator.free(id_value);
            id_value = try generateId(self.allocator, io);
        }

        const session_ptr = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session_ptr);
        session_ptr.* = Session.init(self.allocator, id_value, now + self.options.max_age_seconds);
        id_value_transferred = true;
        errdefer session_ptr.deinit();

        try self.sessions.put(self.allocator, session_ptr.id_value, session_ptr);
        if (retained) retainSession(session_ptr);
        return session_ptr;
    }

    pub fn release(self: *SessionManager, session_ptr: *Session) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        if (session_ptr.active_refs > 0) session_ptr.active_refs -= 1;
        if (session_ptr.active_refs == 0) clearOldSessionIds(self.allocator, session_ptr);
        if (session_ptr.retired and session_ptr.active_refs == 0) {
            unlinkRetiredSession(self, session_ptr);
            destroySession(self.allocator, session_ptr);
        }
    }

    pub fn isActive(self: *SessionManager, session_ptr: *Session) bool {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        return !session_ptr.retired;
    }

    pub fn destroy(self: *SessionManager, id_value: []const u8) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        if (self.sessions.fetchRemove(id_value)) |removed| {
            retireSession(self, removed.value);
        }
    }

    pub fn regenerate(self: *SessionManager, old_id: []const u8, io: ?std.Io) std.mem.Allocator.Error!?*Session {
        self.lock_value.lock();
        defer self.lock_value.unlock();

        const session_ptr = self.sessions.get(old_id) orelse return null;
        var new_id = try generateId(self.allocator, io);
        var new_id_transferred = false;
        errdefer if (!new_id_transferred) self.allocator.free(new_id);
        while (self.sessions.contains(new_id)) {
            self.allocator.free(new_id);
            new_id = try generateId(self.allocator, io);
        }

        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        if (session_ptr.active_refs > 1) {
            try session_ptr.old_id_values.append(self.allocator, session_ptr.id_value);
            _ = self.sessions.remove(old_id);
        } else {
            _ = self.sessions.remove(old_id);
            self.allocator.free(session_ptr.id_value);
        }
        session_ptr.id_value = new_id;
        new_id_transferred = true;
        session_ptr.dirty = true;
        session_ptr.touch(time.nowSeconds(), self.options);
        try self.sessions.put(self.allocator, session_ptr.id_value, session_ptr);
        retainSession(session_ptr);
        return session_ptr;
    }

    pub fn gc(self: *SessionManager) void {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        gcLocked(self, time.nowSeconds());
    }

    pub fn count(self: *SessionManager) usize {
        self.lock_value.lock();
        defer self.lock_value.unlock();
        return self.sessions.count();
    }

    fn shouldGc(self: *SessionManager, now_seconds: u64) bool {
        return self.options.gc_interval_seconds == 0 or
            self.last_gc_seconds == 0 or
            now_seconds >= self.last_gc_seconds + self.options.gc_interval_seconds;
    }

    fn gcLocked(self: *SessionManager, now_seconds: u64) void {
        self.last_gc_seconds = now_seconds;

        var expired_sessions: std.ArrayListUnmanaged(*Session) = .empty;
        defer expired_sessions.deinit(self.allocator);

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            const session_ptr = entry.value_ptr.*;
            if (!session_ptr.isExpired(now_seconds)) continue;
            expired_sessions.append(self.allocator, session_ptr) catch break;
        }

        for (expired_sessions.items) |session_ptr| {
            _ = self.sessions.remove(session_ptr.id_value);
            retireSession(self, session_ptr);
        }
    }
};

const MiddlewareFn = fn (c: *Context, next: Context.Next) Response;

pub fn session(comptime session_options: Options) MiddlewareFn {
    return struct {
        var manager: SessionManager = .{
            .options = session_options,
        };

        fn run(c: *Context, next: Context.Next) Response {
            return runSession(c, next, &manager);
        }
    }.run;
}

pub fn sessionWithManager(comptime manager: *SessionManager) MiddlewareFn {
    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            return runSession(c, next, manager);
        }
    }.run;
}

fn runSession(c: *Context, next: Context.Next, manager: *SessionManager) Response {
    const session_options = manager.options;
    const incoming_id = c.req.cookie(session_options.cookie_name);
    var created = false;
    const session_ptr = if (incoming_id) |cookie_value|
        manager.findCookieRetained(cookie_value) orelse createdSession(c, manager, &created)
    else
        createdSession(c, manager, &created);

    const active_session = session_ptr orelse {
        return c.text(.{ "Service Unavailable: session store full", .service_unavailable });
    };

    c.set(session_options.context_key, active_session) catch
        return releaseAndInternalError(manager, active_session, "session context allocation failed");
    c.set(session_options.manager_context_key, manager) catch
        return releaseAndInternalError(manager, active_session, "session manager context allocation failed");

    next.run();
    var res = c.takeResponse();
    if ((created or active_session.isDirty()) and manager.isActive(active_session)) {
        const cookie_value = sessionCookieValue(c.req.allocator, session_options, active_session.id()) catch {
            res.deinit();
            manager.release(active_session);
            return response_mod.internalError("session cookie allocation failed");
        };
        defer if (session_options.signing_secret != null) c.req.allocator.free(cookie_value);

        res.cookie(c.req.allocator, session_options.cookie_name, cookie_value, cookieOptions(session_options)) catch {
            res.deinit();
            manager.release(active_session);
            return response_mod.internalError("session cookie allocation failed");
        };
        active_session.markClean();
    }
    attachSessionRelease(c, &res, manager, active_session) catch {
        res.deinit();
        manager.release(active_session);
        return response_mod.internalError("session release scope allocation failed");
    };
    return res;
}

const SessionReleaseScope = struct {
    manager: *SessionManager,
    session_ptr: *Session,
    allocator: std.mem.Allocator,
};

fn attachSessionRelease(c: *Context, res: *Response, manager: *SessionManager, session_ptr: *Session) std.mem.Allocator.Error!void {
    const scope = try c.req.allocator.create(SessionReleaseScope);
    errdefer c.req.allocator.destroy(scope);
    scope.* = .{
        .manager = manager,
        .session_ptr = session_ptr,
        .allocator = c.req.allocator,
    };
    try res.attachScope(c.req.allocator, scope, releaseSessionScope);
}

fn releaseSessionScope(raw_scope: *anyopaque) void {
    const scope: *SessionReleaseScope = @ptrCast(@alignCast(raw_scope));
    const allocator = scope.allocator;
    scope.manager.release(scope.session_ptr);
    allocator.destroy(scope);
}

fn releaseAndInternalError(manager: *SessionManager, session_ptr: *Session, message: []const u8) Response {
    manager.release(session_ptr);
    return response_mod.internalError(message);
}

fn createdSession(c: *Context, manager: *SessionManager, created: *bool) ?*Session {
    const session_ptr = manager.createRetained(c.io()) catch return null;
    if (session_ptr != null) created.* = true;
    return session_ptr;
}

fn cookieOptions(options: Options) response_mod.CookieOptions {
    return .{
        .path = options.path,
        .domain = options.domain,
        .http_only = options.http_only,
        .secure = options.secure,
        .same_site = options.same_site,
        .max_age = options.max_age_seconds,
        .priority = options.priority,
        .partitioned = options.partitioned,
    };
}

fn sessionCookieValue(allocator: std.mem.Allocator, options: Options, id_value: []const u8) std.mem.Allocator.Error![]const u8 {
    if (options.signing_secret == null) return id_value;
    return try signSessionId(allocator, options, id_value);
}

fn signSessionId(allocator: std.mem.Allocator, options: Options, id_value: []const u8) std.mem.Allocator.Error![]const u8 {
    const secret = options.signing_secret orelse return try allocator.dupe(u8, id_value);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, id_value, secret);
    const signature = std.fmt.bytesToHex(&mac, .lower);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ id_value, &signature });
}

fn verifySessionCookie(options: Options, cookie_value: []const u8) ?[]const u8 {
    const secret = options.signing_secret orelse return cookie_value;
    const dot = std.mem.lastIndexOfScalar(u8, cookie_value, '.') orelse return null;
    const id_value = cookie_value[0..dot];
    const signature = cookie_value[dot + 1 ..];
    if (id_value.len == 0 or signature.len != HmacSha256.mac_length * 2) return null;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, id_value, secret);
    const expected = std.fmt.bytesToHex(&mac, .lower);

    var provided: [HmacSha256.mac_length * 2]u8 = undefined;
    @memcpy(&provided, signature);
    if (!std.crypto.timing_safe.eql(@TypeOf(expected), expected, provided)) return null;
    return id_value;
}

fn destroySession(allocator: std.mem.Allocator, session_ptr: *Session) void {
    session_ptr.deinit();
    allocator.destroy(session_ptr);
}

fn retireSession(manager: *SessionManager, session_ptr: *Session) void {
    session_ptr.retired = true;
    if (session_ptr.active_refs == 0) {
        destroySession(manager.allocator, session_ptr);
        return;
    }
    session_ptr.retired_next = manager.retired_sessions;
    manager.retired_sessions = session_ptr;
}

fn retainSession(session_ptr: *Session) void {
    session_ptr.active_refs += 1;
}

fn clearOldSessionIds(allocator: std.mem.Allocator, session_ptr: *Session) void {
    for (session_ptr.old_id_values.items) |old_id| allocator.free(old_id);
    session_ptr.old_id_values.deinit(allocator);
    session_ptr.old_id_values = .empty;
}

fn unlinkRetiredSession(manager: *SessionManager, session_ptr: *Session) void {
    var current = &manager.retired_sessions;
    while (current.*) |candidate| {
        if (candidate == session_ptr) {
            current.* = candidate.retired_next;
            candidate.retired_next = null;
            return;
        }
        current = &candidate.retired_next;
    }
}

fn generateId(allocator: std.mem.Allocator, io: ?std.Io) std.mem.Allocator.Error![]u8 {
    var bytes: [16]u8 = undefined;
    if (io) |live_io| {
        live_io.randomSecure(&bytes) catch {
            live_io.random(&bytes);
        };
    } else {
        const counter = fallback_counter.fetchAdd(1, .acq_rel);
        var seed_words = [_]u64{ time.nowSeconds(), counter };
        const seed = std.hash.Wyhash.hash(counter, std.mem.asBytes(&seed_words));
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(&bytes);
    }

    const encoded = std.fmt.bytesToHex(&bytes, .lower);
    return try allocator.dupe(u8, &encoded);
}

fn putValue(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(ValueEntry),
    key: []const u8,
    value: anytype,
) std.mem.Allocator.Error!void {
    const ValueType = @TypeOf(value);
    const StoreType = if (comptime isStringLike(ValueType)) []const u8 else ValueType;

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    const stored_value = try allocator.create(StoreType);
    errdefer allocator.destroy(stored_value);

    if (comptime isStringLike(ValueType)) {
        stored_value.* = try allocator.dupe(u8, value);
    } else {
        stored_value.* = value;
    }
    errdefer if (comptime isStringLike(ValueType)) allocator.free(stored_value.*);

    const entry: ValueEntry = .{
        .value = @ptrCast(stored_value),
        .type_name = @typeName(StoreType),
        .deinit_fn = deinitValueFn(StoreType, isStringLike(ValueType)),
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

fn getValue(comptime T: type, map: *const std.StringHashMapUnmanaged(ValueEntry), key: []const u8) ?T {
    const entry = map.get(key) orelse return null;
    if (!std.mem.eql(u8, entry.type_name, @typeName(T))) return null;
    const typed_value: *const T = @ptrCast(@alignCast(entry.value));
    return typed_value.*;
}

fn deinitValues(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(ValueEntry)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit_fn(allocator, entry.value_ptr.value);
    }
    map.deinit(allocator);
    map.* = .empty;
}

fn deinitValueFn(comptime T: type, comptime free_slice: bool) *const fn (allocator: std.mem.Allocator, value: *anyopaque) void {
    return struct {
        fn run(allocator: std.mem.Allocator, value: *anyopaque) void {
            const typed_value: *T = @ptrCast(@alignCast(value));
            if (free_slice) allocator.free(typed_value.*);
            allocator.destroy(typed_value);
        }
    }.run;
}

fn isStringLike(comptime T: type) bool {
    return core_meta.isStringSliceLike(T);
}

test "session middleware persists values through cookie" {
    const cookie_name = "ZONO_TEST_SESSION";

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(session(.{
        .cookie_name = cookie_name,
        .context_key = "test.session",
        .secure = false,
    }));
    try app.get("/set", struct {
        fn run(c: *Context) !Response {
            const s = c.get(*Session, "test.session").?;
            try s.set("user", "alice");
            return c.text("set");
        }
    }.run);
    try app.get("/get", struct {
        fn run(c: *Context) Response {
            const s = c.get(*Session, "test.session").?;
            return c.text(s.get([]const u8, "user") orelse "missing");
        }
    }.run);

    var first = try app.request(std.testing.allocator, "/set", .{});
    defer first.deinit();
    const set_cookie = first.headerValue("set-cookie").?;
    const cookie_header = set_cookie[0 .. std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len];

    var second = try app.request(std.testing.allocator, "/get", .{
        .headers = &.{.{ .name = "cookie", .value = cookie_header }},
    });
    defer second.deinit();

    try std.testing.expectEqualStrings("alice", second.bodyBytes());
}

test "session middleware signs and rejects tampered cookies" {
    const cookie_name = "ZONO_SIGNED_SESSION";

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(session(.{
        .cookie_name = cookie_name,
        .context_key = "signed.session",
        .secure = false,
        .signing_secret = "test-secret",
    }));
    try app.get("/set", struct {
        fn run(c: *Context) !Response {
            const s = c.get(*Session, "signed.session").?;
            try s.set("user", "alice");
            return c.text("set");
        }
    }.run);
    try app.get("/get", struct {
        fn run(c: *Context) Response {
            const s = c.get(*Session, "signed.session").?;
            return c.text(s.get([]const u8, "user") orelse "missing");
        }
    }.run);

    var first = try app.request(std.testing.allocator, "/set", .{});
    defer first.deinit();
    const set_cookie = first.headerValue("set-cookie").?;
    const cookie_header = set_cookie[0 .. std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len];
    try std.testing.expect(std.mem.indexOfScalar(u8, cookie_header, '.') != null);

    var second = try app.request(std.testing.allocator, "/get", .{
        .headers = &.{.{ .name = "cookie", .value = cookie_header }},
    });
    defer second.deinit();
    try std.testing.expectEqualStrings("alice", second.bodyBytes());

    const tampered = try std.testing.allocator.dupe(u8, cookie_header);
    defer std.testing.allocator.free(tampered);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == '0') '1' else '0';

    var third = try app.request(std.testing.allocator, "/get", .{
        .headers = &.{.{ .name = "cookie", .value = tampered }},
    });
    defer third.deinit();
    try std.testing.expectEqualStrings("missing", third.bodyBytes());
}

test "session middleware can use an explicit manager" {
    const Shared = struct {
        var manager = SessionManager.init(std.testing.allocator, .{
            .cookie_name = "ZONO_MANAGED_SESSION",
            .context_key = "managed.session",
            .secure = false,
        });
    };
    defer Shared.manager.deinit();

    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(sessionWithManager(&Shared.manager));
    try app.get("/count", struct {
        fn run(c: *Context) !Response {
            const s = c.get(*Session, "managed.session").?;
            const count = (s.get(u32, "count") orelse 0) + 1;
            try s.set("count", count);
            return c.text("ok");
        }
    }.run);

    var first = try app.request(std.testing.allocator, "/count", .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), Shared.manager.count());

    const set_cookie = first.headerValue("set-cookie").?;
    const cookie_header = set_cookie[0 .. std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len];
    var second = try app.request(std.testing.allocator, "/count", .{
        .headers = &.{.{ .name = "cookie", .value = cookie_header }},
    });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), Shared.manager.count());
}

test "session manager enforces max sessions" {
    var manager = SessionManager.init(std.testing.allocator, .{
        .max_sessions = 1,
        .secure = false,
    });
    defer manager.deinit();

    const first = (try manager.create(null)).?;
    defer manager.release(first);
    try std.testing.expect(first.id().len > 0);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqual(@as(?*Session, null), try manager.create(null));
}

test "session manager regenerates and destroys sessions" {
    var manager = SessionManager.init(std.testing.allocator, .{
        .secure = false,
    });
    defer manager.deinit();

    const first = (try manager.create(null)).?;
    defer manager.release(first);
    try first.set("role", "admin");

    const old_id = try std.testing.allocator.dupe(u8, first.id());
    defer std.testing.allocator.free(old_id);

    const regenerated = (try manager.regenerate(old_id, null)).?;
    defer manager.release(regenerated);
    try std.testing.expectEqual(first, regenerated);
    try std.testing.expect(!std.mem.eql(u8, old_id, regenerated.id()));
    try std.testing.expectEqualStrings("admin", regenerated.get([]const u8, "role").?);
    try std.testing.expectEqual(@as(usize, 1), manager.count());

    manager.destroy(regenerated.id());
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "session manager expires sessions lazily" {
    var manager = SessionManager.init(std.testing.allocator, .{
        .max_age_seconds = 0,
        .secure = false,
    });
    defer manager.deinit();

    const first = (try manager.create(null)).?;
    defer manager.release(first);
    const id_copy = try std.testing.allocator.dupe(u8, first.id());
    defer std.testing.allocator.free(id_copy);

    try std.testing.expectEqual(@as(?*Session, null), manager.find(id_copy));
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "session manager gc removes multiple expired sessions" {
    var manager = SessionManager.init(std.testing.allocator, .{
        .max_age_seconds = 0,
        .gc_interval_seconds = 3600,
        .secure = false,
    });
    defer manager.deinit();

    var created: [3]*Session = undefined;
    for (&created) |*slot| {
        slot.* = (try manager.create(null)).?;
    }
    try std.testing.expectEqual(@as(usize, 3), manager.count());

    for (created) |session_ptr| manager.release(session_ptr);
    manager.gc();
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

const std = @import("std");
const zio = @import("zio");

pub fn nowNanoseconds() u64 {
    return zio.Timestamp.now(.monotonic).toNanoseconds();
}

pub fn nowSeconds() u64 {
    return @intCast(zio.Timestamp.now(.realtime).toSeconds());
}

pub fn deadlineFromNowMs(timeout_ms: u64) ?u64 {
    if (timeout_ms == 0) return null;
    const now = nowNanoseconds();
    const delta = std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch return std.math.maxInt(u64);
    return std.math.add(u64, now, delta) catch std.math.maxInt(u64);
}

pub fn deadlineExceeded(deadline_ns: ?u64) bool {
    const deadline = deadline_ns orelse return false;
    return nowNanoseconds() >= deadline;
}

pub fn remainingDeadlineMs(deadline_ns: ?u64) u64 {
    const deadline = deadline_ns orelse return 0;
    const now = nowNanoseconds();
    if (now >= deadline) return 1;
    const remaining_ns = deadline - now;
    return @max(1, std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1);
}

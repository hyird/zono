const std = @import("std");

const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
pub fn parseAuthSwitch(packet: []const u8) !struct { plugin_name: []const u8, seed: []const u8 } {
    if (packet.len < 2 or packet[0] != 0xfe) return error.ProtocolError;
    var reader = Io.Reader.fixed(packet[1..]);
    const plugin_name = try reader.takeSentinel(0);
    var seed = reader.buffered();
    if (seed.len > 0 and seed[seed.len - 1] == 0) seed = seed[0 .. seed.len - 1];
    return .{ .plugin_name = plugin_name, .seed = seed };
}

pub fn buildAuthResponse(plugin_name: []const u8, password: []const u8, seed: []const u8, out: []u8) !usize {
    if (password.len == 0) return 0;

    if (std.mem.eql(u8, plugin_name, "mysql_native_password")) {
        if (out.len < Sha1.digest_length) return error.BufferTooSmall;
        mysqlNativePassword(password, seed, out[0..Sha1.digest_length]);
        return Sha1.digest_length;
    }

    if (std.mem.eql(u8, plugin_name, "caching_sha2_password")) {
        if (out.len < Sha256.digest_length) return error.BufferTooSmall;
        cachingSha2Password(password, seed, out[0..Sha256.digest_length]);
        return Sha256.digest_length;
    }

    return error.UnsupportedAuthentication;
}

pub fn mysqlNativePassword(password: []const u8, seed: []const u8, out: []u8) void {
    var stage1: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(password, &stage1, .{});

    var stage2: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(&stage1, &stage2, .{});

    var hasher = Sha1.init(.{});
    hasher.update(seed);
    hasher.update(&stage2);
    var digest: [Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);

    for (out[0..Sha1.digest_length], 0..) |*byte, index| {
        byte.* = stage1[index] ^ digest[index];
    }
}

pub fn cachingSha2Password(password: []const u8, seed: []const u8, out: []u8) void {
    var stage1: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(password, &stage1, .{});

    var stage2: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&stage1, &stage2, .{});

    var stage3: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&stage2, &stage3, .{});

    var hasher = Sha256.init(.{});
    hasher.update(&stage3);
    hasher.update(seed);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    for (out[0..Sha256.digest_length], 0..) |*byte, index| {
        byte.* = stage1[index] ^ digest[index];
    }
}

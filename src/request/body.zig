const std = @import("std");

pub const BodyStream = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn read(self: *BodyStream, out: []u8) usize {
        if (self.index >= self.bytes.len or out.len == 0) return 0;
        const count = @min(out.len, self.bytes.len - self.index);
        @memcpy(out[0..count], self.bytes[self.index .. self.index + count]);
        self.index += count;
        return count;
    }

    pub fn readAll(self: *BodyStream) []const u8 {
        const remaining = self.bytes[self.index..];
        self.index = self.bytes.len;
        return remaining;
    }

    pub fn reset(self: *BodyStream) void {
        self.index = 0;
    }
};

pub const BodyReadError = std.Io.Reader.ShortError || error{
    BodyTooLarge,
};

pub const BodyStreamError = BodyReadError || std.Io.Writer.Error;

pub const BodyState = struct {
    reader: *std.Io.Reader,
    max_bytes: usize,
    bytes_read: usize = 0,
    done: bool = false,
    limit_exceeded: bool = false,
    abort_flag: ?*std.atomic.Value(bool) = null,

    pub fn init(reader: *std.Io.Reader, max_bytes: usize, abort_flag: ?*std.atomic.Value(bool)) BodyState {
        return .{
            .reader = reader,
            .max_bytes = max_bytes,
            .abort_flag = abort_flag,
        };
    }

    pub fn isAborted(self: *const BodyState) bool {
        if (self.abort_flag) |flag| return flag.load(.acquire);
        return false;
    }

    pub fn markAborted(self: *BodyState) void {
        if (self.abort_flag) |flag| flag.store(true, .release);
    }

    fn read(self: *BodyState, out: []u8) BodyReadError!usize {
        if (self.done or out.len == 0) return 0;
        if (self.bytes_read >= self.max_bytes) {
            var probe: [1]u8 = undefined;
            const n = self.reader.readSliceShort(&probe) catch |err| {
                self.markAborted();
                return err;
            };
            if (n == 0) {
                self.done = true;
                return 0;
            }
            self.limit_exceeded = true;
            self.markAborted();
            return error.BodyTooLarge;
        }

        const remaining = self.max_bytes - self.bytes_read;
        const dest = out[0..@min(out.len, remaining)];
        const n = self.reader.readSliceShort(dest) catch |err| {
            self.markAborted();
            return err;
        };
        self.bytes_read += n;
        if (n == 0) self.done = true;
        return n;
    }

    pub fn discardRemaining(self: *BodyState) BodyReadError!usize {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) return total;
            total += n;
        }
    }
};

pub const BodyReader = struct {
    source: union(enum) {
        buffered: BodyStream,
        live: *BodyState,
    },

    pub fn isAborted(self: *const BodyReader) bool {
        return switch (self.source) {
            .buffered => false,
            .live => |state| state.isAborted(),
        };
    }

    pub fn read(self: *BodyReader, out: []u8) BodyReadError!usize {
        return switch (self.source) {
            .buffered => |*stream| stream.read(out),
            .live => |state| state.read(out),
        };
    }

    pub fn readAllAlloc(self: *BodyReader, allocator: std.mem.Allocator, max_bytes: usize) (BodyReadError || std.mem.Allocator.Error)![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) return try out.toOwnedSlice(allocator);
            if (out.items.len > max_bytes or n > max_bytes - out.items.len) return error.BodyTooLarge;
            try out.appendSlice(allocator, buf[0..n]);
        }
    }

    pub fn streamTo(self: *BodyReader, writer: *std.Io.Writer) BodyStreamError!usize {
        return try self.streamToLimit(writer, null);
    }

    pub fn streamToLimit(self: *BodyReader, writer: *std.Io.Writer, max_bytes: ?usize) BodyStreamError!usize {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) return total;
            if (max_bytes) |limit| {
                if (total > limit or n > limit - total) return error.BodyTooLarge;
            }
            try writer.writeAll(buf[0..n]);
            total += n;
        }
    }
};

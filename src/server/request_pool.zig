const std = @import("std");

pub const RequestPool = struct {
    arena: std.heap.ArenaAllocator,
    retain_bytes: usize,

    pub fn init(child_allocator: std.mem.Allocator, retain_bytes: usize) RequestPool {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .retain_bytes = retain_bytes,
        };
    }

    pub fn deinit(self: *RequestPool) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *RequestPool) std.mem.Allocator {
        _ = if (self.retain_bytes == 0)
            self.arena.reset(.free_all)
        else
            self.arena.reset(.{ .retain_with_limit = self.retain_bytes });
        return self.arena.allocator();
    }
};

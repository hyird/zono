const std = @import("std");

pub const HeaderStore = struct {
    const inline_capacity = 6;
    pub const AppendBorrowedError = std.mem.Allocator.Error || error{MissingOverflowAllocator};

    inline_items: [inline_capacity]std.http.Header = undefined,
    inline_len: u8 = 0,
    overflow: std.ArrayListUnmanaged(std.http.Header) = .empty,
    overflow_allocator: ?std.mem.Allocator = null,

    pub fn items(self: *const HeaderStore) []const std.http.Header {
        if (self.overflow_allocator != null) return self.overflow.items;
        return self.inline_items[0..self.inline_len];
    }

    pub fn mutableItems(self: *HeaderStore) []std.http.Header {
        if (self.overflow_allocator != null) return self.overflow.items;
        return self.inline_items[0..self.inline_len];
    }

    pub fn append(
        self: *HeaderStore,
        allocator: std.mem.Allocator,
        header: std.http.Header,
    ) std.mem.Allocator.Error!void {
        if (self.overflow_allocator) |list_allocator| {
            try self.overflow.append(list_allocator, header);
            return;
        }

        if (self.inline_len < inline_capacity) {
            self.inline_items[self.inline_len] = header;
            self.inline_len += 1;
            return;
        }

        var overflow: std.ArrayListUnmanaged(std.http.Header) = .empty;
        errdefer overflow.deinit(allocator);
        try overflow.appendSlice(allocator, self.inline_items[0..self.inline_len]);
        try overflow.append(allocator, header);
        self.overflow = overflow;
        self.overflow_allocator = allocator;
        self.inline_len = 0;
    }

    pub fn appendBorrowed(
        self: *HeaderStore,
        allocator: ?std.mem.Allocator,
        header: std.http.Header,
    ) AppendBorrowedError!void {
        if (self.overflow_allocator) |list_allocator| {
            try self.overflow.append(list_allocator, header);
            return;
        }

        if (self.inline_len < inline_capacity) {
            self.inline_items[self.inline_len] = header;
            self.inline_len += 1;
            return;
        }

        const list_allocator = allocator orelse return error.MissingOverflowAllocator;
        try self.append(list_allocator, header);
    }

    pub fn swapRemove(self: *HeaderStore, index: usize) std.http.Header {
        if (self.overflow_allocator != null) {
            return self.overflow.swapRemove(index);
        }

        const entry = self.inline_items[index];
        self.inline_len -= 1;
        self.inline_items[index] = self.inline_items[self.inline_len];
        return entry;
    }

    pub fn replaceWithOwnedOverflow(
        self: *HeaderStore,
        allocator: std.mem.Allocator,
        owned_headers: std.ArrayListUnmanaged(std.http.Header),
    ) void {
        if (self.overflow_allocator) |list_allocator| {
            self.overflow.deinit(list_allocator);
        }
        self.overflow = owned_headers;
        self.inline_len = 0;
        self.overflow_allocator = if (owned_headers.items.len > 0) allocator else null;
    }

    pub fn deinit(self: *HeaderStore) void {
        if (self.overflow_allocator) |allocator| {
            self.overflow.deinit(allocator);
        }
        self.* = .{};
    }

    pub fn usesOverflow(self: *const HeaderStore) bool {
        return self.overflow_allocator != null;
    }
};

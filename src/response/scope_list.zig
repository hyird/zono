const std = @import("std");

pub const ScopeList = struct {
    head: ?*Node = null,

    const Node = struct {
        allocator: std.mem.Allocator,
        ptr: *anyopaque,
        deinit_fn: *const fn (scope: *anyopaque) void,
        next: ?*Node = null,
    };

    pub fn attach(
        self: *ScopeList,
        node_allocator: std.mem.Allocator,
        scope_ptr: *anyopaque,
        scope_deinit: *const fn (scope: *anyopaque) void,
    ) std.mem.Allocator.Error!void {
        const node = try node_allocator.create(Node);
        node.* = .{
            .allocator = node_allocator,
            .ptr = scope_ptr,
            .deinit_fn = scope_deinit,
            .next = self.head,
        };
        self.head = node;
    }

    pub fn deinit(self: *ScopeList) void {
        var scope_iter = self.head;
        self.head = null;
        while (scope_iter) |node| {
            const next = node.next;
            node.deinit_fn(node.ptr);
            node.allocator.destroy(node);
            scope_iter = next;
        }
    }
};

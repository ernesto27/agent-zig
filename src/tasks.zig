const std = @import("std");

pub const Status = enum {
    pending,
    in_progress,
    completed,

    pub fn fromString(s: []const u8) ?Status {
        return std.meta.stringToEnum(Status, s);
    }

    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .completed => "[x]",
        };
    }
};

pub const Task = struct {
    id: []const u8,
    content: []const u8,
    status: Status,
};

pub const Summary = struct {
    completed: usize = 0,
    in_progress: usize = 0,
    pending: usize = 0,
    total: usize = 0,
};

/// Session-scoped, ordered task list the model maintains via `task_write` and
/// the sidebar renders. Owns an arena that holds every task's `id`/`content`
/// plus the backing list; `apply` resets it wholesale so the store never has to
/// reason about which strings it owns.
pub const TaskStore = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Task) = .{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) TaskStore {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Replace the entire list with `incoming`, duping every string into the
    /// store's arena (reset first). Enforces the single in-progress invariant:
    /// if more than one item is `in_progress`, only the last one stays so and
    /// the earlier ones are coerced to `pending`.
    pub fn apply(self: *Self, incoming: []const Task) !void {
        _ = self.arena.reset(.retain_capacity);
        self.items = .{};
        const a = self.arena.allocator();

        var last_in_progress: ?usize = null;
        for (incoming, 0..) |t, i| {
            if (t.status == .in_progress) last_in_progress = i;
        }

        try self.items.ensureTotalCapacity(a, incoming.len);
        for (incoming, 0..) |t, i| {
            const status: Status = if (t.status == .in_progress and i != last_in_progress.?)
                .pending
            else
                t.status;
            self.items.appendAssumeCapacity(.{
                .id = try a.dupe(u8, t.id),
                .content = try a.dupe(u8, t.content),
                .status = status,
            });
        }
    }

    pub fn clear(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
        self.items = .{};
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.items.items.len == 0;
    }

    /// True when the list is non-empty and every task is completed. The sidebar
    /// hides in this state so a finished plan doesn't linger on screen.
    pub fn allCompleted(self: *const Self) bool {
        if (self.items.items.len == 0) return false;
        for (self.items.items) |t| {
            if (t.status != .completed) return false;
        }
        return true;
    }

    pub fn summary(self: *const Self) Summary {
        var s = Summary{ .total = self.items.items.len };
        for (self.items.items) |t| {
            switch (t.status) {
                .completed => s.completed += 1,
                .in_progress => s.in_progress += 1,
                .pending => s.pending += 1,
            }
        }
        return s;
    }
};

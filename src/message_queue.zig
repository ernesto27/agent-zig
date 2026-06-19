const std = @import("std");
const vaxis = @import("vaxis");

/// FIFO queue of message strings. The queue owns its messages: enqueue() dupes
/// the input, dequeue() hands ownership to the caller, deinit() frees the rest.
pub const MessageQueue = struct {
    items: std.ArrayList([]const u8) = .{},

    const Self = @This();

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        for (self.items.items) |msg| alloc.free(msg);
        self.items.deinit(alloc);
    }

    /// Copy `msg` and append it to the back of the queue.
    pub fn enqueue(self: *Self, alloc: std.mem.Allocator, msg: []const u8) !void {
        const owned = try alloc.dupe(u8, msg);
        errdefer alloc.free(owned);
        try self.items.append(alloc, owned);
    }

    /// Remove and return the front message, or null if empty.
    /// Caller takes ownership and must free the returned slice.
    pub fn dequeue(self: *Self) ?[]const u8 {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Free and remove all queued messages, keeping the backing capacity.
    pub fn clear(self: *Self, alloc: std.mem.Allocator) void {
        for (self.items.items) |msg| alloc.free(msg);
        self.items.clearRetainingCapacity();
    }

    /// Return all queued messages in FIFO order. The queue keeps ownership —
    /// the returned slice is a borrowed view valid until the next mutation.
    pub fn getAll(self: *const Self) []const []const u8 {
        return self.items.items;
    }

    /// Render up to `max_rows` queued messages starting at row `top_y`
    /// (one row per message, "Steering:" prefix). No-op when empty.
    pub fn render(self: *const Self, win: vaxis.Window, top_y: u16, max_rows: u16) void {
        const n: u16 = @min(@as(u16, @intCast(self.items.items.len)), max_rows);
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const row: u16 = top_y + i;
            const res = win.printSegment(.{
                .text = "Steering: ",
                .style = .{ .fg = .{ .rgb = .{ 0x9C, 0xE3, 0xEE } } },
            }, .{ .row_offset = row, .col_offset = 1 });
            _ = win.printSegment(.{
                .text = self.items.items[i],
                .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
            }, .{ .row_offset = row, .col_offset = res.col });
        }
    }
};

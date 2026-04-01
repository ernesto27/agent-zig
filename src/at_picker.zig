const std = @import("std");

pub const MAX_RESULTS = 10;
pub const MAX_PATH_LEN = 512;

pub const AtPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8),
    results: std.ArrayList([]u8),
    selected: usize = 0,
    at_start: usize = 0,

    pub fn init() AtPicker {
        return .{
            .query = std.ArrayList(u8){},
            .results = std.ArrayList([]u8){},
        };
    }

    pub fn deinit(self: *AtPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        for (self.results.items) |r| alloc.free(r);
        self.results.deinit(alloc);
    }

    pub fn reset(self: *AtPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        for (self.results.items) |r| alloc.free(r);
        self.results.clearRetainingCapacity();
        self.selected = 0;
        self.at_start = 0;
    }

    pub fn refresh(self: *AtPicker, alloc: std.mem.Allocator) !void {
        for (self.results.items) |r| alloc.free(r);
        self.results.clearRetainingCapacity();
        self.selected = 0;

        var base = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer base.close();

        try walkDir(alloc, base, "", &self.results, self.query.items);
    }

    /// Recursive walker — skips hidden dirs entirely before descending.
    fn walkDir(
        alloc: std.mem.Allocator,
        dir: std.fs.Dir,
        rel_path: []const u8,
        results: *std.ArrayList([]u8),
        query: []const u8,
    ) !void {
        if (results.items.len >= MAX_RESULTS) return;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (results.items.len >= MAX_RESULTS) return;

            // Skip hidden files and directories
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            // Build the full relative path for this entry
            const full_path = if (rel_path.len == 0)
                try alloc.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_path, entry.name });

            switch (entry.kind) {
                .directory => {
                    // Open and recurse — then free the path (only files are stored)
                    var sub = dir.openDir(entry.name, .{ .iterate = true }) catch {
                        alloc.free(full_path);
                        continue;
                    };
                    defer sub.close();
                    try walkDir(alloc, sub, full_path, results, query);
                    alloc.free(full_path);
                },
                .file => {
                    const matches = query.len == 0 or
                        std.mem.containsAtLeast(u8, full_path, 1, query);
                    if (matches) {
                        try results.append(alloc, full_path);
                    } else {
                        alloc.free(full_path);
                    }
                },
                else => alloc.free(full_path),
            }
        }
    }
};

const std = @import("std");

pub const MAX_RESULTS = 10;
pub const MAX_PATH_LEN = 512;

pub const AtPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8),
    results: std.ArrayList([]u8),
    selected: usize = 0,
    at_start: usize = 0,
    picked_files: std.ArrayList([]u8),

    pub fn init() AtPicker {
        return .{
            .query = std.ArrayList(u8){},
            .results = std.ArrayList([]u8){},
            .picked_files = std.ArrayList([]u8){},
        };
    }

    pub fn deinit(self: *AtPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        for (self.results.items) |r| alloc.free(r);
        self.results.deinit(alloc);
        self.clearPicked(alloc);
        self.picked_files.deinit(alloc);
    }

    pub fn reset(self: *AtPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        for (self.results.items) |r| alloc.free(r);
        self.results.clearRetainingCapacity();
        self.selected = 0;
        self.at_start = 0;
    }

    /// Record a confirmed file pick. Dupes the path so caller can reset freely.
    pub fn addPicked(self: *AtPicker, alloc: std.mem.Allocator, path: []const u8) !void {
        const owned = try alloc.dupe(u8, path);
        errdefer alloc.free(owned);
        try self.picked_files.append(alloc, owned);
    }

    /// Free all picked paths and clear the list. Called at message submit.
    pub fn clearPicked(self: *AtPicker, alloc: std.mem.Allocator) void {
        for (self.picked_files.items) |p| alloc.free(p);
        self.picked_files.clearRetainingCapacity();
    }

    /// Returns owned slice of paths still referenced as @path in `input`.
    /// Clears the picked list. Caller owns the slice and each path string.
    pub fn takePicked(self: *AtPicker, alloc: std.mem.Allocator, input: []const u8) [][]u8 {
        var result = std.ArrayList([]u8){};
        for (self.picked_files.items) |path| {
            var buf: [516]u8 = undefined;
            const at_path = std.fmt.bufPrint(&buf, "@{s}", .{path}) catch continue;
            if (std.mem.indexOf(u8, input, at_path) != null) {
                const owned = alloc.dupe(u8, path) catch continue;
                result.append(alloc, owned) catch alloc.free(owned);
            }
        }
        self.clearPicked(alloc);
        return result.toOwnedSlice(alloc) catch &.{};
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

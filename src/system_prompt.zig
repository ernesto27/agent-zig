const std = @import("std");

const log = std.log.scoped(.app);

pub const SystemPrompt = struct {
    content: []const u8 = "",
    agents_md_exists: bool = false,

    pub fn deinit(self: *SystemPrompt, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) {
            allocator.free(self.content);
            self.content = "";
        }
        self.agents_md_exists = false;
    }

    pub fn readContent(self: *SystemPrompt, allocator: std.mem.Allocator) !void {
        try self.readContentFromDir(allocator, std.fs.cwd());
    }

    pub fn readContentFromDir(self: *SystemPrompt, allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
        if (loadOverride(allocator, dir)) |override_content| {
            self.content = override_content;
        } else {
            const base_file = try dir.openFile("src/prompts/system.txt", .{});
            defer base_file.close();
            self.content = try base_file.readToEndAlloc(allocator, 1024 * 1024);
        }

        const agents_file = dir.openFile("AGENTS.md", .{}) catch return;
        defer agents_file.close();

        const agents_content = try agents_file.readToEndAlloc(allocator, 1024 * 1024);
        errdefer allocator.free(agents_content);

        const combined = try std.mem.concat(allocator, u8, &.{ self.content, "\n\n", agents_content });
        allocator.free(self.content);
        allocator.free(agents_content);
        self.content = combined;
        self.agents_md_exists = true;
    }
};

/// Returns null on FileNotFound and on any open/read error (logged).
fn loadOverride(allocator: std.mem.Allocator, dir: std.fs.Dir) ?[]u8 {
    const override_file = dir.openFile("SYSTEM.md", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| {
            log.err("failed to open SYSTEM.md: {} — falling back to built-in prompt", .{e});
            return null;
        },
    };
    defer override_file.close();

    return override_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        log.err("failed to read SYSTEM.md: {} — falling back to built-in prompt", .{err});
        return null;
    };
}

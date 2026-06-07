const std = @import("std");

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
        self.deinit(allocator);

        const base_file = try std.fs.cwd().openFile("src/prompts/system.txt", .{});
        defer base_file.close();
        self.content = try base_file.readToEndAlloc(allocator, 1024 * 1024);

        const agents_file = std.fs.cwd().openFile("AGENTS.md", .{}) catch return;
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

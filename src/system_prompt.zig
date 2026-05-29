const std = @import("std");

pub const SystemPrompt = struct {
    files: []const []const u8 = &.{ "AGENTS.md", "CLAUDE.md" },
    content: []const u8 = "",

    pub fn deinit(self: *SystemPrompt, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) {
            allocator.free(self.content);
            self.content = "";
        }
    }

    pub fn readContent(self: *SystemPrompt, allocator: std.mem.Allocator) !void {
        self.deinit(allocator);

        const fileSystemPromp = try std.fs.cwd().openFile("src/prompts/system.txt", .{});
        defer fileSystemPromp.close();
        self.content = try fileSystemPromp.readToEndAlloc(allocator, 1024 * 1024);

        // 2. Try AGENTS.md or CLAUDE.md in the working directory
        for (self.files) |file_name| {
            const file = std.fs.cwd().openFile(file_name, .{}) catch continue;
            defer file.close();

            const content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
            if (self.content.len == 0) {
                self.content = content;
            } else {
                const new_content = std.mem.concat(allocator, u8, &.{ self.content, "\n\n", content }) catch continue;
                allocator.free(self.content);
                self.content = new_content;
            }
            return;
        }
    }
};

test "readContent sets content" {
    var sp = SystemPrompt{
        .files = &.{ "AGENTS.md", "CLAUDE.md" },
        .content = "",
    };

    try sp.readContent(std.testing.allocator);
    defer sp.deinit(std.testing.allocator);
    try std.testing.expect(sp.content.len > 0);
    std.debug.print("content:\n{s}\n", .{sp.content});
}

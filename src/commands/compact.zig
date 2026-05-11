const std = @import("std");

pub const Compact = struct {
    const template = @embedFile("../prompts/compact.txt");

    pub fn getPrompt(allocator: std.mem.Allocator, session_content: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}\n\nSession transcript:\n<session>\n{s}\n</session>\n",
            .{ template, session_content },
        );
    }
};

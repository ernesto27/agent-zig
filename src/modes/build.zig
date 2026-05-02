const std = @import("std");
const mode_mod = @import("../mode.zig");

pub const BuildMode = struct {
    mode_prompt: []const u8 = @embedFile("../prompts/build_mode.txt"),

    pub fn label(_: BuildMode) []const u8 {
        return " BUILD ";
    }

    pub fn buildSystemPrompt(self: BuildMode, alloc: std.mem.Allocator, base: []const u8) ?[]const u8 {
        if (base.len == 0) return alloc.dupe(u8, self.mode_prompt) catch null;
        return std.mem.concat(alloc, u8, &.{ base, "\n\n", self.mode_prompt }) catch null;
    }

    pub fn isToolAllowed(_: BuildMode, _: []const u8, _: std.json.Value) mode_mod.ToolPolicy {
        return .{ .ok = true, .reason = "" };
    }
};

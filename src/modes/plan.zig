const std = @import("std");
const agent = @import("agent");
const mode_mod = @import("../mode.zig");

pub const PlanMode = struct {
    mode_prompt: []const u8 = @embedFile("../prompts/plan_mode.txt"),

    pub fn label(_: PlanMode) []const u8 {
        return " PLAN ";
    }

    pub fn buildSystemPrompt(self: PlanMode, alloc: std.mem.Allocator, base: []const u8) ?[]const u8 {
        if (base.len == 0) return alloc.dupe(u8, self.mode_prompt) catch null;
        return std.mem.concat(alloc, u8, &.{ base, "\n\n", self.mode_prompt }) catch null;
    }

    pub fn isToolAllowed(_: PlanMode, tool_name: []const u8, input: std.json.Value) mode_mod.ToolPolicy {
        if (std.mem.eql(u8, tool_name, "read_file")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "glob")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "grep")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "web_search")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "web_extract")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "skill")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "skill_resource")) return .{ .ok = true, .reason = "" };

        if (std.mem.eql(u8, tool_name, "write_file")) return .{ .ok = false, .reason = "Plan Mode blocks file writes" };
        if (std.mem.eql(u8, tool_name, "edit_file")) return .{ .ok = false, .reason = "Plan Mode blocks file edits" };

        if (std.mem.eql(u8, tool_name, "bash")) {
            const command = agent.json_helpers.getStringField(input, "command") orelse "";
            if (isSafeBash(command)) return .{ .ok = true, .reason = "" };
            return .{ .ok = false, .reason = "Plan Mode allows only non-mutating shell commands" };
        }

        return .{ .ok = false, .reason = "Tool not allowed in Plan Mode" };
    }

    fn isSafeBash(_: []const u8) bool {
        return false;
    }
};

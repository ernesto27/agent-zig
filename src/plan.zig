const std = @import("std");
const agent = @import("agent");

pub const Plan = struct {
    mode_prompt: []const u8 = @embedFile("prompts/plan_mode.txt"),

    pub const ToolPolicy = struct {
        ok: bool,
        reason: []const u8,
    };

    pub fn buildSystemPrompt(
        self: *const Plan,
        alloc: std.mem.Allocator,
        plan_mode_enabled: bool,
        base_prompt: []const u8,
    ) ?[]const u8 {
        if (plan_mode_enabled) {
            if (base_prompt.len == 0) {
                return alloc.dupe(u8, self.mode_prompt) catch null;
            }
            return std.mem.concat(alloc, u8, &.{ base_prompt, "\n\n", self.mode_prompt }) catch null;
        }

        if (base_prompt.len == 0) return null;
        return alloc.dupe(u8, base_prompt) catch null;
    }

    pub fn isToolAllowed(
        self: *const Plan,
        tool_name: []const u8,
        input: std.json.Value,
    ) ToolPolicy {
        if (std.mem.eql(u8, tool_name, "read_file")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "glob")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "grep")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "web_search")) return .{ .ok = true, .reason = "" };
        if (std.mem.eql(u8, tool_name, "web_extract")) return .{ .ok = true, .reason = "" };

        if (std.mem.eql(u8, tool_name, "write_file")) {
            return .{ .ok = false, .reason = "Plan Mode blocks file writes" };
        }
        if (std.mem.eql(u8, tool_name, "edit_file")) {
            return .{ .ok = false, .reason = "Plan Mode blocks file edits" };
        }
        if (std.mem.eql(u8, tool_name, "bash")) {
            const command = agent.json_helpers.getStringField(input, "command") orelse "";
            if (self.isSafeBash(command)) {
                return .{ .ok = true, .reason = "" };
            }
            return .{ .ok = false, .reason = "Plan Mode allows only non-mutating shell commands" };
        }

        return .{ .ok = false, .reason = "Tool not allowed in Plan Mode" };
    }

    fn isSafeBash(self: *const Plan, command: []const u8) bool {
        _ = self;
        _ = command;
        return false;
    }
};

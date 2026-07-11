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
        const tool = std.meta.stringToEnum(agent.tools.ToolName, tool_name) orelse
            return .{ .ok = false, .reason = "Tool not allowed in Plan Mode" };
        switch (tool) {
            .read_file, .glob, .grep, .web_search, .web_extract, .skill, .skill_resource, .task_write => return .{ .ok = true, .reason = "" },
            .write_file => return .{ .ok = false, .reason = "Plan Mode blocks file writes" },
            .edit_file => return .{ .ok = false, .reason = "Plan Mode blocks file edits" },
            .bash => {
                const command = agent.json_helpers.getStringField(input, "command") orelse "";
                if (isSafeBash(command)) return .{ .ok = true, .reason = "" };
                return .{ .ok = false, .reason = "Plan Mode allows only non-mutating shell commands" };
            },
            .skill_script => return .{ .ok = false, .reason = "Tool not allowed in Plan Mode" },
        }
    }

    fn isSafeBash(_: []const u8) bool {
        return false;
    }
};

// === Tests ===

const testing = std.testing;

test "plan mode allows read-only and research tools" {
    const plan = PlanMode{};
    const allowed = [_][]const u8{
        "read_file", "glob", "grep", "web_search", "web_extract", "skill", "skill_resource",
    };
    for (allowed) |name| {
        try testing.expect(plan.isToolAllowed(name, .null).ok);
    }
}

test "plan mode blocks mutating tools with a reason" {
    const plan = PlanMode{};
    const write = plan.isToolAllowed("write_file", .null);
    try testing.expect(!write.ok);
    try testing.expect(write.reason.len > 0);

    try testing.expect(!plan.isToolAllowed("edit_file", .null).ok);
}

test "plan mode blocks bash even with a command (isSafeBash stub returns false)" {
    const plan = PlanMode{};
    const alloc = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"command":"ls -la"}
    , .{});
    defer parsed.deinit();

    try testing.expect(!plan.isToolAllowed("bash", parsed.value).ok);
}

test "plan mode denies unknown tools by default" {
    const plan = PlanMode{};
    try testing.expect(!plan.isToolAllowed("some_future_tool", .null).ok);
}

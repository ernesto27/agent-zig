const std = @import("std");
const agent = @import("agent");
const mode_mod = @import("../mode.zig");

pub const ShellMode = struct {
    mode_prompt: []const u8 = "",

    pub const CommandResult = struct {
        command: []const u8,
        result: agent.tools.ToolResult,
    };

    pub fn label(_: ShellMode) []const u8 {
        return " SHELL ";
    }

    pub fn buildSystemPrompt(self: ShellMode, alloc: std.mem.Allocator, base: []const u8) ?[]const u8 {
        if (base.len == 0) return alloc.dupe(u8, self.mode_prompt) catch null;
        return std.mem.concat(alloc, u8, &.{ base, "\n\n", self.mode_prompt }) catch null;
    }

    pub fn runCommand(_: ShellMode, alloc: std.mem.Allocator, raw_input: []const u8) !CommandResult {
        const shell_command = if (raw_input.len > 0 and raw_input[0] == '!') raw_input[1..] else raw_input;
        const command = try alloc.dupe(u8, shell_command);
        errdefer alloc.free(command);

        const result = try agent.tools.runBashCommand(alloc, command);
        return .{ .command = command, .result = result };
    }

    pub fn isToolAllowed(_: ShellMode, _: []const u8, _: std.json.Value) mode_mod.ToolPolicy {
        return .{ .ok = true, .reason = "" };
    }
};

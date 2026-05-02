const std = @import("std");
const BuildMode = @import("modes/build.zig").BuildMode;
const PlanMode = @import("modes/plan.zig").PlanMode;

pub const ToolPolicy = struct {
    ok: bool,
    reason: []const u8,
};

pub const Mode = union(enum) {
    build: BuildMode,
    plan: PlanMode,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            inline else => |m| m.label(),
        };
    }

    pub fn buildSystemPrompt(self: Mode, alloc: std.mem.Allocator, base: []const u8) ?[]const u8 {
        return switch (self) {
            inline else => |m| m.buildSystemPrompt(alloc, base),
        };
    }

    pub fn isToolAllowed(self: Mode, tool_name: []const u8, input: std.json.Value) ToolPolicy {
        return switch (self) {
            inline else => |m| m.isToolAllowed(tool_name, input),
        };
    }

    pub fn toggle(self: Mode) Mode {
        return switch (self) {
            .build => .{ .plan = .{} },
            .plan => .{ .build = .{} },
        };
    }
};

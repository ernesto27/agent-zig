const std = @import("std");

pub const Model = struct {
    id: []const u8,
    display: []const u8,
    free: bool = false,
    supports_thinking: bool = false,
};

pub const Provider = struct {
    name: []const u8,
    models: []const Model,
};

pub const providers = [_]Provider{
    .{
        .name = "Anthropic",
        .models = &[_]Model{
            .{ .id = "claude-opus-4-6", .display = "Claude Opus 4.6", .supports_thinking = true },
            .{ .id = "claude-sonnet-4-6", .display = "Claude Sonnet 4.6", .supports_thinking = true },
            .{ .id = "claude-haiku-4-5-20251001", .display = "Claude Haiku 4.5" },
        },
    },
    .{
        .name = "OpenAI",
        .models = &[_]Model{
            .{ .id = "gpt-4o", .display = "GPT-4o" },
            .{ .id = "gpt-4o-mini", .display = "GPT-4o Mini" },
            .{ .id = "o3", .display = "o3" },
            .{ .id = "o4-mini", .display = "o4 Mini" },
        },
    },
};

pub fn findModel(id: []const u8) ?*const Model {
    for (&providers) |*p| {
        for (p.models) |*m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
    }
    return null;
}

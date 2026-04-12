const std = @import("std");

pub const Model = struct {
    id: []const u8,
    display: []const u8,
    free: bool = false,
    supports_thinking: bool = false,
    max_context: u32 = 200_000,
};

pub const FindResult = struct {
    provider: *const Provider,
    model: *const Model,
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
            .{ .id = "gpt-5.4", .display = "GPT-5.4", .supports_thinking = true },
            .{ .id = "gpt-5.4-pro", .display = "GPT-5.4 Pro", .supports_thinking = true },
            .{ .id = "gpt-5.4-mini", .display = "GPT-5.4 Mini", .supports_thinking = true },
            .{ .id = "gpt-5.4-nano", .display = "GPT-5.4 Nano", .supports_thinking = true },
            .{ .id = "gpt-5", .display = "GPT-5", .supports_thinking = true },
            .{ .id = "gpt-5-mini", .display = "GPT-5 Mini", .supports_thinking = true },
        },
    },
};

pub fn findModel(id: []const u8) ?FindResult {
    for (&providers) |*p| {
        for (p.models) |*m| {
            if (std.mem.eql(u8, m.id, id)) return .{ .provider = p, .model = m };
        }
    }
    return null;
}

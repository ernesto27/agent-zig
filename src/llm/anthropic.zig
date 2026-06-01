const std = @import("std");
const message = @import("message.zig");
const config = @import("../config.zig");
const providers = @import("providers.zig");

pub const version = "2023-06-01";

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const message.Message,
    tools: []const message.ToolDefinition,
    system_prompt: ?[]const u8,
    stream: bool,
    effort: config.Effort,
) ![]u8 {
    const model_info = providers.findModel(model);
    const req_body = message.MessagesRequest{
        .model = model,
        .messages = messages,
        .system = system_prompt,
        .stream = stream,
        .tools = tools,
        .effort = effort,
        .supports_thinking = model_info != null and model_info.?.model.supports_thinking,
    };
    return std.json.Stringify.valueAlloc(allocator, req_body, .{});
}

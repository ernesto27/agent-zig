const std = @import("std");

// === Request Types ===

pub const Role = enum {
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const MessagesRequest = struct {
    model: []const u8,
    messages: []const Message,
    max_tokens: u32 = 1024,
    stream: bool = false,
};

// === Response Types ===

pub const ContentBlock = struct {
    type: []const u8,
    text: []const u8,
};

pub const Usage = struct {
    input_tokens: u64,
    output_tokens: u64,
};

pub const MessagesResponse = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    content: []const ContentBlock,
    model: []const u8,
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
    usage: Usage,

    /// Extract the text from the first content block.
    /// Returns null if content is empty or first block is not "text" type.
    pub fn textContent(self: MessagesResponse) ?[]const u8 {
        if (self.content.len == 0) return null;
        if (!std.mem.eql(u8, self.content[0].type, "text")) return null;
        return self.content[0].text;
    }
};

// === SSE Streaming Event Types ===

pub const TextDelta = struct {
    type: []const u8,
    text: []const u8 = "",
};

pub const ContentBlockDeltaEvent = struct {
    type: []const u8,
    index: u32,
    delta: TextDelta,
};

pub const ApiError = struct {
    message: []const u8,
};

pub const ErrorResponse = struct {
    @"error": ApiError,
};

// === Tests ===

test "serialize MessagesRequest to JSON" {
    const alloc = std.testing.allocator;

    const req = MessagesRequest{
        .model = "mock-model",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
        },
    };

    const json_bytes = try std.json.Stringify.valueAlloc(alloc, req, .{});
    defer alloc.free(json_bytes);

    // Verify key fields are present in the JSON output
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"model\":\"mock-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"content\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"max_tokens\":1024") != null);
}

test "parse MessagesResponse from JSON" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{"id":"msg_mock_123","type":"message","role":"assistant",
        \\"content":[{"type":"text","text":"Hello!"}],
        \\"model":"mock-model","stop_reason":"end_turn",
        \\"stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":10}}
    ;

    const parsed = try std.json.parseFromSlice(MessagesResponse, alloc, json_str, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("msg_mock_123", parsed.value.id);
    try std.testing.expectEqualStrings("assistant", parsed.value.role);
    try std.testing.expectEqualStrings("Hello!", parsed.value.textContent().?);
    try std.testing.expectEqual(@as(u64, 5), parsed.value.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 10), parsed.value.usage.output_tokens);
}

test "parse ErrorResponse from JSON" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{"error":{"message":"Invalid JSON"}}
    ;

    const parsed = try std.json.parseFromSlice(ErrorResponse, alloc, json_str, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Invalid JSON", parsed.value.@"error".message);
}

test "textContent returns null for empty content" {
    const resp = MessagesResponse{
        .id = "test",
        .type = "message",
        .role = "assistant",
        .content = &.{},
        .model = "mock",
        .usage = .{ .input_tokens = 0, .output_tokens = 0 },
    };

    try std.testing.expect(resp.textContent() == null);
}

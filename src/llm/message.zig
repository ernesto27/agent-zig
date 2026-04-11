const std = @import("std");

pub const Effort = enum {
    none,
    low,
    medium,
    high,
    max,

    pub fn next(self: Effort) Effort {
        return switch (self) {
            .none => .low,
            .low => .medium,
            .medium => .high,
            .high => .max,
            .max => .none,
        };
    }

    pub fn label(self: Effort) []const u8 {
        return switch (self) {
            .none => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .max => "max",
        };
    }
};

pub const Role = enum {
    user,
    assistant,
};

pub const MessageContent = union(enum) {
    text: []const u8,
    tool_result_blocks: []const ToolResultBlock,
    content_blocks: []const ContentBlock,

    /// Custom serializer: text → "string", blocks → [{...}]
    pub fn jsonStringify(self: MessageContent, jw: anytype) !void {
        switch (self) {
            .text => |t| try jw.write(t),
            .tool_result_blocks => |blocks| {
                try jw.beginArray();
                for (blocks) |block| try jw.write(block);
                try jw.endArray();
            },
            .content_blocks => |blocks| {
                try jw.beginArray();
                for (blocks) |block| try jw.write(block);
                try jw.endArray();
            },
        }
    }
};

pub const Message = struct {
    role: Role,
    content: MessageContent,
};

pub const MessagesRequest = struct {
    model: []const u8,
    messages: []const Message,
    system: ?[]const u8 = null,
    max_tokens: u32 = 8096,
    stream: bool = false,
    tools: []const ToolDefinition = &.{},
    effort: Effort = .none,
    supports_thinking: bool = false,

    /// Custom serializer: omit tools when empty, omit stream when false
    pub fn jsonStringify(self: MessagesRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(self.model);
        try jw.objectField("max_tokens");
        try jw.write(self.max_tokens);
        if (self.system) |s| {
            try jw.objectField("system");
            try jw.write(s);
        }
        try jw.objectField("messages");
        try jw.write(self.messages);
        if (self.stream) {
            try jw.objectField("stream");
            try jw.write(true);
        }
        if (self.tools.len > 0) {
            try jw.objectField("tools");
            try jw.write(self.tools);
        }

        if (self.effort != .none and self.supports_thinking) {
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("adaptive");
            try jw.endObject();
            try jw.objectField("output_config");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write(self.effort.label());
            try jw.endObject();
        }
        try jw.endObject();
    }
};

// === Tool Types ===

pub const ToolInputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value = .null,
    required: []const []const u8 = &.{},
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ToolInputSchema,
};

pub const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

// === Response Types ===

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    // thinking block fields
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    // tool_use block fields
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: std.json.Value = .null,

    /// Only serialize fields relevant to the block type
    pub fn jsonStringify(self: ContentBlock, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        if (std.mem.eql(u8, self.type, "thinking")) {
            if (self.thinking) |t| {
                try jw.objectField("thinking");
                try jw.write(t);
            }
            if (self.signature) |s| {
                try jw.objectField("signature");
                try jw.write(s);
            }
        } else {
            if (self.text) |t| {
                try jw.objectField("text");
                try jw.write(t);
            }
            if (self.id) |id| {
                try jw.objectField("id");
                try jw.write(id);
            }
            if (self.name) |n| {
                try jw.objectField("name");
                try jw.write(n);
            }
            if (self.input != .null) {
                try jw.objectField("input");
                try jw.write(self.input);
            }
        }
        try jw.endObject();
    }
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
            .{ .role = .user, .content = .{ .text = "hello" } },
        },
    };

    const json_bytes = try std.json.Stringify.valueAlloc(alloc, req, .{});
    defer alloc.free(json_bytes);

    // Verify key fields are present in the JSON output
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"model\":\"mock-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"content\":\"hello\"") != null);
    // stream:false is omitted by custom serializer
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"stream\":false") == null);
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

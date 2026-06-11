const std = @import("std");
const anthropic = @import("anthropic.zig");
const message = @import("message.zig");
const config_mod = @import("../config.zig");
const openai = @import("openai.zig");
const gemini = @import("gemini.zig");
const json_helpers = @import("../json_helpers.zig");

const log = std.log.scoped(.llm);

const appendJsonString = json_helpers.appendJsonString;
const appendObjectFieldName = json_helpers.appendObjectFieldName;

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    provider_name: []const u8,
    effort: config_mod.Effort = .none,
};

pub const CancelFn = *const fn (*anyopaque) bool;

pub const Backend = enum { anthropic, openai, gemini };

fn backendFor(name: []const u8) Backend {
    const map = std.StaticStringMap(Backend).initComptime(.{
        .{ "Anthropic", .anthropic },
        .{ "OpenAI", .openai },
        .{ "DeepSeek", .anthropic }, // uses DeepSeek's Anthropic-compatible /anthropic/v1/messages
        .{ "Gemini", .gemini },
    });
    return map.get(name) orelse std.debug.panic("unknown provider: {s}", .{name});
}

pub const StreamBlockType = enum {
    text,
    tool_use,
    thinking,
};

pub const StreamBlock = struct {
    block_type: StreamBlockType,
    text: std.ArrayList(u8) = .{},
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    input_json: std.ArrayList(u8) = .{},
    signature: std.ArrayList(u8) = .{},

    pub fn init(block_type: StreamBlockType) StreamBlock {
        return .{ .block_type = block_type };
    }

    fn deinit(self: *StreamBlock, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.input_json.deinit(allocator);
        self.signature.deinit(allocator);
        if (self.id) |id| allocator.free(id);
        if (self.name) |name| allocator.free(name);
    }
};

pub const StreamAccumulator = struct {
    allocator: std.mem.Allocator,
    id: ?[]u8 = null,
    role: ?[]u8 = null,
    model: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    stop_sequence: ?[]u8 = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    blocks: std.ArrayList(StreamBlock) = .{},

    pub fn init(allocator: std.mem.Allocator) StreamAccumulator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StreamAccumulator) void {
        if (self.id) |id| self.allocator.free(id);
        if (self.role) |role| self.allocator.free(role);
        if (self.model) |model| self.allocator.free(model);
        if (self.stop_reason) |stop_reason| self.allocator.free(stop_reason);
        if (self.stop_sequence) |stop_sequence| self.allocator.free(stop_sequence);
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
    }

    pub fn setOwnedString(self: *StreamAccumulator, target: *?[]u8, value: []const u8) !void {
        if (target.*) |old| self.allocator.free(old);
        target.* = try self.allocator.dupe(u8, value);
    }

    pub fn initBlockAt(self: *StreamAccumulator, index: usize, block_type: StreamBlockType) !*StreamBlock {
        if (index > self.blocks.items.len) return error.InvalidSseEvent;
        if (index == self.blocks.items.len) {
            try self.blocks.append(self.allocator, StreamBlock.init(block_type));
        } else {
            self.blocks.items[index].deinit(self.allocator);
            self.blocks.items[index] = StreamBlock.init(block_type);
        }
        return &self.blocks.items[index];
    }

    pub fn getBlock(self: *StreamAccumulator, index: usize) ?*StreamBlock {
        if (index >= self.blocks.items.len) return null;
        return &self.blocks.items[index];
    }
};

/// Parse `json_bytes` and re-serialize with indentation for readable logging.
/// Returns a new allocation — caller must free. Falls back to duping the
/// original bytes if parsing fails (so the caller can always free the result).
pub fn prettyJson(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{ .ignore_unknown_fields = true });
    const pretty = std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch {
        parsed.deinit();
        return allocator.dupe(u8, json_bytes);
    };
    parsed.deinit();
    return pretty;
}

pub const Client = struct {
    http_client: std.http.Client,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{
            .http_client = std.http.Client{ .allocator = allocator },
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Send messages with streaming. Dispatches to Anthropic or OpenAI path based on provider_name.
    pub fn sendMessageStreaming(
        self: *Client,
        allocator: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const message.ToolDefinition,
        system_prompt: ?[]const u8,
        ctx: *anyopaque,
        on_chunk: *const fn (*anyopaque, []const u8) void,
        on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
        should_cancel: CancelFn,
    ) !std.json.Parsed(message.MessagesResponse) {
        return switch (backendFor(self.config.provider_name)) {
            .openai => openai.sendMessageStreaming(self, allocator, messages, tools, system_prompt, ctx, on_chunk, on_thinking_chunk, should_cancel),
            .gemini => gemini.sendMessageStreaming(self, allocator, messages, tools, system_prompt, ctx, on_chunk, on_thinking_chunk, should_cancel),
            .anthropic => anthropic.sendMessageStreaming(self, allocator, messages, tools, system_prompt, ctx, on_chunk, on_thinking_chunk, should_cancel),
        };
    }
};

pub fn buildStreamedResponseJson(allocator: std.mem.Allocator, stream: *const StreamAccumulator) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    try appendObjectFieldName(allocator, &out, "id");
    try appendJsonString(allocator, &out, stream.id orelse "");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "type");
    try appendJsonString(allocator, &out, "message");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "role");
    try appendJsonString(allocator, &out, stream.role orelse "assistant");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "content");
    try out.append(allocator, '[');

    for (stream.blocks.items, 0..) |block, idx| {
        if (idx > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try appendObjectFieldName(allocator, &out, "type");
        try appendJsonString(allocator, &out, switch (block.block_type) {
            .text => "text",
            .tool_use => "tool_use",
            .thinking => "thinking",
        });

        switch (block.block_type) {
            .text => {
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "text");
                try appendJsonString(allocator, &out, block.text.items);
            },
            .thinking => {
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "thinking");
                try appendJsonString(allocator, &out, block.text.items);
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "signature");
                try appendJsonString(allocator, &out, block.signature.items);
            },
            .tool_use => {
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "id");
                try appendJsonString(allocator, &out, block.id orelse "");
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "name");
                try appendJsonString(allocator, &out, block.name orelse "");
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "input");
                try out.appendSlice(allocator, if (block.input_json.items.len > 0) block.input_json.items else "{}");
                if (block.signature.items.len > 0) {
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, &out, "signature");
                    try appendJsonString(allocator, &out, block.signature.items);
                }
            },
        }

        try out.append(allocator, '}');
    }

    try out.append(allocator, ']');
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "model");
    try appendJsonString(allocator, &out, stream.model orelse "");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stop_reason");
    if (stream.stop_reason) |stop_reason| {
        try appendJsonString(allocator, &out, stop_reason);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stop_sequence");
    if (stream.stop_sequence) |stop_sequence| {
        try appendJsonString(allocator, &out, stop_sequence);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "usage");
    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, &out, "input_tokens");
    try out.writer(allocator).print("{d}", .{stream.input_tokens});
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "output_tokens");
    try out.writer(allocator).print("{d}", .{stream.output_tokens});
    try out.appendSlice(allocator, "}");
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

// === Tests ===

const test_config: Config = .{
    .base_url = "http://localhost:9999",
    .api_key = "mock-key",
    .model = "mock-model",
};

test "sendMessage returns a text response from local server" {
    const alloc = std.testing.allocator;
    var client = Client.init(alloc, test_config);
    defer client.deinit();

    const msgs = [_]message.Message{
        .{ .role = .user, .content = .{ .text = "hello" } },
    };

    const resp = anthropic.sendMessage(&client, alloc, &msgs, &.{}) catch |err| switch (err) {
        error.ConnectionRefused => return error.ServerNotRunning,
        else => return err,
    };
    defer resp.deinit();

    try std.testing.expect(resp.value.textContent() != null);
    try std.testing.expect(resp.value.textContent().?.len > 0);
}

test "sendMessage with multi-turn history on local server" {
    const alloc = std.testing.allocator;
    var client = Client.init(alloc, test_config);
    defer client.deinit();

    const msgs = [_]message.Message{
        .{ .role = .user, .content = .{ .text = "What is Zig?" } },
        .{ .role = .assistant, .content = .{ .text = "Zig is a systems programming language." } },
        .{ .role = .user, .content = .{ .text = "zig" } },
    };

    const resp = anthropic.sendMessage(&client, alloc, &msgs, &.{}) catch |err| switch (err) {
        error.ConnectionRefused => return error.ServerNotRunning,
        else => return err,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("assistant", resp.value.role);
    try std.testing.expect(resp.value.textContent() != null);
}

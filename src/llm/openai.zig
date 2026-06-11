const std = @import("std");
const json_helpers = @import("../json_helpers.zig");
const message = @import("message.zig");
const client = @import("client.zig");

const log = std.log.scoped(.llm);

const appendJsonString = json_helpers.appendJsonString;
const appendObjectFieldName = json_helpers.appendObjectFieldName;

/// Serialize messages and tools to an OpenAI Chat Completions request JSON body.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const message.Message,
    tools: []const message.ToolDefinition,
    system_prompt: ?[]const u8,
    stream: bool,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, &out, "model");
    try appendJsonString(allocator, &out, model);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stream");
    try out.appendSlice(allocator, if (stream) "true" else "false");
    if (stream) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "stream_options");
        try out.appendSlice(allocator, "{\"include_usage\":true}");
    }

    if (tools.len > 0) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "tools");
        try out.append(allocator, '[');
        for (tools, 0..) |tool, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, &out, "type");
            try appendJsonString(allocator, &out, "function");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "function");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, &out, "name");
            try appendJsonString(allocator, &out, tool.name);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "description");
            try appendJsonString(allocator, &out, tool.description);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "parameters");
            const schema_json = try std.json.Stringify.valueAlloc(allocator, tool.input_schema, .{});
            defer allocator.free(schema_json);
            try out.appendSlice(allocator, schema_json);
            try out.appendSlice(allocator, "}}");
        }
        try out.append(allocator, ']');
    }

    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "messages");
    try out.append(allocator, '[');

    var first_msg = true;
    if (system_prompt) |sp| {
        try appendChatMessagePrefix(allocator, &out, &first_msg, "system");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "content");
        try appendJsonString(allocator, &out, sp);
        try out.append(allocator, '}');
    }

    for (messages) |msg| {
        switch (msg.content) {
            .text => |text| {
                try appendChatMessagePrefix(allocator, &out, &first_msg, @tagName(msg.role));
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "content");
                try appendJsonString(allocator, &out, text);
                try out.append(allocator, '}');
            },
            .content_blocks => |blocks| {
                if (msg.role == .user) {
                    try appendUserContentBlocks(allocator, &out, &first_msg, blocks);
                } else {
                    try appendAssistantContentBlocks(allocator, &out, &first_msg, blocks);
                }
            },
            .tool_result_blocks => |blocks| {
                try appendToolResultBlocks(allocator, &out, &first_msg, blocks);
            },
        }
    }

    try out.append(allocator, ']');
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn appendUserContentBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendChatMessagePrefix(allocator, out, first_msg, "user");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, out, "content");
    try out.append(allocator, '[');

    var first_part = true;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "text");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "text");
            try appendJsonString(allocator, out, blk.text orelse "");
            try out.append(allocator, '}');
        } else if (std.mem.eql(u8, blk.type, "image")) {
            const src = blk.source orelse continue;
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "image_url");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "image_url");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "url");
            const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ src.media_type, src.data });
            defer allocator.free(url);
            try appendJsonString(allocator, out, url);
            try out.appendSlice(allocator, "}}");
        }
    }

    try out.append(allocator, ']');
    try out.append(allocator, '}');
}

fn appendAssistantContentBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendChatMessagePrefix(allocator, out, first_msg, "assistant");

    var text_content: ?[]const u8 = null;
    var tool_use_count: usize = 0;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) text_content = blk.text;
        if (std.mem.eql(u8, blk.type, "tool_use")) tool_use_count += 1;
    }

    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, out, "content");
    try appendJsonString(allocator, out, text_content orelse "");

    if (tool_use_count > 0) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "tool_calls");
        try out.append(allocator, '[');
        var first_tc = true;
        for (blocks) |blk| {
            if (!std.mem.eql(u8, blk.type, "tool_use")) continue;
            if (!first_tc) try out.append(allocator, ',');
            first_tc = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "id");
            try appendJsonString(allocator, out, blk.id orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "function");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "function");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "name");
            try appendJsonString(allocator, out, blk.name orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "arguments");
            const args_json = try std.json.Stringify.valueAlloc(allocator, blk.input, .{});
            defer allocator.free(args_json);
            try appendJsonString(allocator, out, args_json);
            try out.appendSlice(allocator, "}}");
        }
        try out.append(allocator, ']');
    }

    try out.append(allocator, '}');
}

fn appendToolResultBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ToolResultBlock,
) !void {
    for (blocks) |blk| {
        try appendChatMessagePrefix(allocator, out, first_msg, "tool");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "tool_call_id");
        try appendJsonString(allocator, out, blk.tool_use_id);
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "content");
        try appendJsonString(allocator, out, blk.content);
        try out.append(allocator, '}');
    }
}

fn appendChatMessagePrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    role: []const u8,
) !void {
    if (!first_msg.*) try out.append(allocator, ',');
    first_msg.* = false;
    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, out, "role");
    try appendJsonString(allocator, out, role);
}

// === Streaming ===

/// Stream an OpenAI Chat Completions response and normalize it into a
/// MessagesResponse, reusing `client.prettyJson` for logging.
pub fn sendMessageStreaming(
    self: *client.Client,
    allocator: std.mem.Allocator,
    messages: []const message.Message,
    tools: []const message.ToolDefinition,
    system_prompt: ?[]const u8,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
    should_cancel: client.CancelFn,
) !std.json.Parsed(message.MessagesResponse) {
    _ = on_thinking_chunk; // OpenAI streaming does not emit separate thinking deltas
    const body = try buildRequestBody(allocator, self.config.model, messages, tools, system_prompt, true);
    defer allocator.free(body);

    const pretty_req = client.prettyJson(allocator, body) catch body;
    defer if (pretty_req.ptr != body.ptr) allocator.free(pretty_req);
    log.info("OpenAI streaming request body:\n{s}", .{pretty_req});

    const url_str = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.config.base_url});
    defer allocator.free(url_str);
    const uri = try std.Uri.parse(url_str);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.api_key});
    defer allocator.free(auth_header);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    log.info("OpenAI: connecting to {s}", .{url_str});

    var http_req = try self.http_client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
        .keep_alive = false,
    });
    defer http_req.deinit();

    try http_req.sendBodyComplete(body);

    var redirect_buf: [4096]u8 = undefined;
    var response = try http_req.receiveHead(&redirect_buf);
    log.info("OpenAI: response status: {d}", .{@intFromEnum(response.head.status)});

    if (response.head.status != .ok) {
        var err_buf: [4096]u8 = undefined;
        var err_transfer_buf: [4096]u8 = undefined;
        const err_reader = response.reader(&err_transfer_buf);
        var err_pos: usize = 0;
        while (err_reader.takeDelimiter('\n') catch null) |line| {
            if (err_pos + line.len < err_buf.len) {
                @memcpy(err_buf[err_pos..][0..line.len], line);
                err_pos += line.len;
            } else break;
        }
        log.err("OpenAI request failed {d}: {s}", .{ @intFromEnum(response.head.status), err_buf[0..err_pos] });
        return error.HttpRequestFailed;
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var oai_stream = OpenAIStreamAccumulator.init(allocator);
    defer oai_stream.deinit();

    try parseSseStream(allocator, body_reader, &oai_stream, ctx, on_chunk, should_cancel);

    const response_bytes = try buildStreamedResponseJson(allocator, &oai_stream, self.config.model);
    defer allocator.free(response_bytes);

    const pretty_resp = client.prettyJson(allocator, response_bytes) catch response_bytes;
    defer if (pretty_resp.ptr != response_bytes.ptr) allocator.free(pretty_resp);
    log.info("OpenAI streamed response:\n{s}", .{pretty_resp});

    return std.json.parseFromSlice(
        message.MessagesResponse,
        allocator,
        response_bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

/// One accumulated tool call from an OpenAI streaming response.
const OpenAIToolCall = struct {
    id: std.ArrayList(u8) = .{},
    name: std.ArrayList(u8) = .{},
    arguments: std.ArrayList(u8) = .{},

    fn deinit(self: *OpenAIToolCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

const OpenAIStreamAccumulator = struct {
    allocator: std.mem.Allocator,
    id: std.ArrayList(u8) = .{},
    text: std.ArrayList(u8) = .{},
    tool_calls: std.ArrayList(OpenAIToolCall) = .{},
    stop_reason: std.ArrayList(u8) = .{},
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,

    fn init(allocator: std.mem.Allocator) OpenAIStreamAccumulator {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *OpenAIStreamAccumulator) void {
        self.id.deinit(self.allocator);
        self.text.deinit(self.allocator);
        for (self.tool_calls.items) |*tc| tc.deinit(self.allocator);
        self.tool_calls.deinit(self.allocator);
        self.stop_reason.deinit(self.allocator);
    }

    fn getOrCreateToolCall(self: *OpenAIStreamAccumulator, index: usize) !*OpenAIToolCall {
        while (self.tool_calls.items.len <= index) {
            try self.tool_calls.append(self.allocator, .{});
        }
        return &self.tool_calls.items[index];
    }
};

fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream: *OpenAIStreamAccumulator,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    should_cancel: client.CancelFn,
) !void {
    while (true) {
        if (should_cancel(ctx)) return error.RequestCancelled;

        const line = try reader.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r");

        if (trimmed.len == 0) continue;

        if (!std.mem.startsWith(u8, trimmed, "data: ")) {
            log.debug("OpenAI SSE non-data line: [{s}]", .{trimmed});
            continue;
        }

        const data = trimmed["data: ".len..];

        if (std.mem.eql(u8, data, "[DONE]")) break;

        log.debug("OpenAI SSE data: {s}", .{data});

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            arena.allocator(),
            data,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            log.err("OpenAI SSE JSON parse error: {} — {s}", .{ err, data });
            continue;
        };
        const root = parsed.value;

        // Capture top-level id from first chunk
        if (stream.id.items.len == 0) {
            if (json_helpers.getStringField(root, "id")) |id| {
                try stream.id.appendSlice(allocator, id);
            }
        }

        // Token usage (present on last chunk for some models)
        if (json_helpers.getObjectField(root, "usage")) |usage_obj| {
            if (json_helpers.getU64Field(usage_obj, "prompt_tokens")) |v| stream.input_tokens = v;
            if (json_helpers.getU64Field(usage_obj, "completion_tokens")) |v| stream.output_tokens = v;
        }

        const choices = json_helpers.getField(root, "choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];

        // finish_reason
        if (json_helpers.getStringField(choice, "finish_reason")) |fr| {
            if (!std.mem.eql(u8, fr, "null") and fr.len > 0) {
                stream.stop_reason.clearRetainingCapacity();
                try stream.stop_reason.appendSlice(allocator, fr);
            }
        }

        const delta = json_helpers.getObjectField(choice, "delta") orelse continue;

        // Text content
        if (json_helpers.getStringField(delta, "content")) |text| {
            if (text.len > 0) {
                try stream.text.appendSlice(allocator, text);
                on_chunk(ctx, text);
            }
        }

        // Tool calls
        if (json_helpers.getField(delta, "tool_calls")) |tc_val| {
            if (tc_val != .array) continue;
            for (tc_val.array.items) |tc_item| {
                const idx_val = json_helpers.getU64Field(tc_item, "index") orelse 0;
                const idx: usize = @intCast(idx_val);
                const tc = try stream.getOrCreateToolCall(idx);

                if (json_helpers.getStringField(tc_item, "id")) |id| {
                    try tc.id.appendSlice(allocator, id);
                }
                if (json_helpers.getObjectField(tc_item, "function")) |fn_obj| {
                    if (json_helpers.getStringField(fn_obj, "name")) |name| {
                        try tc.name.appendSlice(allocator, name);
                    }
                    if (json_helpers.getStringField(fn_obj, "arguments")) |args| {
                        try tc.arguments.appendSlice(allocator, args);
                    }
                }
            }
        }
    }
}

/// Build a MessagesResponse JSON from accumulated OpenAI stream state.
fn buildStreamedResponseJson(
    allocator: std.mem.Allocator,
    stream: *const OpenAIStreamAccumulator,
    model: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    // Map OpenAI finish_reason → Anthropic stop_reason
    const stop_reason: []const u8 = blk: {
        const fr = stream.stop_reason.items;
        if (std.mem.eql(u8, fr, "tool_calls")) break :blk "tool_use";
        if (std.mem.eql(u8, fr, "stop")) break :blk "end_turn";
        if (fr.len > 0) break :blk fr;
        break :blk "end_turn";
    };

    try out.append(allocator, '{');
    try appendObjectFieldName(allocator, &out, "id");
    try appendJsonString(allocator, &out, stream.id.items);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "type");
    try appendJsonString(allocator, &out, "message");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "role");
    try appendJsonString(allocator, &out, "assistant");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "content");
    try out.append(allocator, '[');

    var first_block = true;

    // Text block
    if (stream.text.items.len > 0) {
        first_block = false;
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, &out, "type");
        try appendJsonString(allocator, &out, "text");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "text");
        try appendJsonString(allocator, &out, stream.text.items);
        try out.append(allocator, '}');
    }

    // Tool use blocks
    for (stream.tool_calls.items) |tc| {
        if (!first_block) try out.append(allocator, ',');
        first_block = false;
        try out.append(allocator, '{');
        try appendObjectFieldName(allocator, &out, "type");
        try appendJsonString(allocator, &out, "tool_use");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "id");
        try appendJsonString(allocator, &out, tc.id.items);
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "name");
        try appendJsonString(allocator, &out, tc.name.items);
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "input");
        // arguments is already a JSON string — embed it raw if non-empty
        if (tc.arguments.items.len > 0) {
            try out.appendSlice(allocator, tc.arguments.items);
        } else {
            try out.appendSlice(allocator, "{}");
        }
        try out.append(allocator, '}');
    }

    try out.append(allocator, ']');
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "model");
    try appendJsonString(allocator, &out, model);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stop_reason");
    try appendJsonString(allocator, &out, stop_reason);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stop_sequence");
    try out.appendSlice(allocator, "null");
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

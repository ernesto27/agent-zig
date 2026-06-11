const std = @import("std");
const json_helpers = @import("../json_helpers.zig");
const message = @import("message.zig");
const config = @import("../config.zig");
const providers = @import("providers.zig");
const client = @import("client.zig");

const log = std.log.scoped(.llm);

const appendJsonString = json_helpers.appendJsonString;
const appendObjectFieldName = json_helpers.appendObjectFieldName;

/// Serialize messages and tools to a Google Gemini `generateContent` request body.
///
/// `stream` is accepted for signature parity with the other providers but is not
/// reflected in the body — Gemini selects streaming via the endpoint
/// (`:streamGenerateContent?alt=sse`), not a request field.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const message.Message,
    tools: []const message.ToolDefinition,
    system_prompt: ?[]const u8,
    stream: bool,
    effort: config.Effort,
) ![]u8 {
    _ = stream;

    // Gemini correlates tool results by function NAME, but ToolResultBlock only
    // carries the tool_use_id. Build an id -> name lookup from the assistant
    // tool_use blocks so functionResponse parts can name their function.
    var id_to_name = std.StringHashMap([]const u8).init(allocator);
    defer id_to_name.deinit();
    for (messages) |msg| {
        if (msg.content == .content_blocks) {
            for (msg.content.content_blocks) |blk| {
                if (std.mem.eql(u8, blk.type, "tool_use")) {
                    if (blk.id) |id| {
                        if (blk.name) |name| try id_to_name.put(id, name);
                    }
                }
            }
        }
    }

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");

    // contents
    try appendObjectFieldName(allocator, &out, "contents");
    try out.append(allocator, '[');
    var first_content = true;
    for (messages) |msg| {
        switch (msg.content) {
            .text => |text| {
                try appendContentPrefix(allocator, &out, &first_content, geminiRole(msg.role));
                try out.append(allocator, '[');
                try appendTextPart(allocator, &out, text);
                try out.appendSlice(allocator, "]}");
            },
            .content_blocks => |blocks| {
                if (msg.role == .user) {
                    try appendUserBlocks(allocator, &out, &first_content, blocks);
                } else {
                    try appendModelBlocks(allocator, &out, &first_content, blocks);
                }
            },
            .tool_result_blocks => |blocks| {
                try appendToolResultBlocks(allocator, &out, &first_content, blocks, id_to_name);
            },
        }
    }
    try out.append(allocator, ']');

    // systemInstruction
    if (system_prompt) |sp| {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "systemInstruction");
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, &out, "parts");
        try out.append(allocator, '[');
        try appendTextPart(allocator, &out, sp);
        try out.appendSlice(allocator, "]}");
    }

    // tools
    if (tools.len > 0) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "tools");
        try out.appendSlice(allocator, "[{");
        try appendObjectFieldName(allocator, &out, "functionDeclarations");
        try out.append(allocator, '[');
        for (tools, 0..) |tool, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, &out, "name");
            try appendJsonString(allocator, &out, tool.name);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "description");
            try appendJsonString(allocator, &out, tool.description);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "parameters");
            try appendToolParameters(allocator, &out, tool.input_schema);
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "]}]");
    }

    // generationConfig.thinkingConfig
    const model_info = providers.findModel(model);
    const supports_thinking = model_info != null and model_info.?.model.supports_thinking;
    if (effort != .none and supports_thinking) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "generationConfig");
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, &out, "thinkingConfig");
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, &out, "includeThoughts");
        try out.appendSlice(allocator, "true");
        try out.appendSlice(allocator, "}}");
    }

    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn geminiRole(role: message.Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "model",
    };
}

/// Emit `{"role":"<role>","parts":` and leave the parts array open for the caller.
fn appendContentPrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_content: *bool,
    role: []const u8,
) !void {
    if (!first_content.*) try out.append(allocator, ',');
    first_content.* = false;
    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, out, "role");
    try appendJsonString(allocator, out, role);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, out, "parts");
}

fn appendTextPart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, out, "text");
    try appendJsonString(allocator, out, text);
    try out.append(allocator, '}');
}

fn appendUserBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_content: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendContentPrefix(allocator, out, first_content, "user");
    try out.append(allocator, '[');
    var first_part = true;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try appendTextPart(allocator, out, blk.text orelse "");
        } else if (std.mem.eql(u8, blk.type, "image")) {
            const src = blk.source orelse continue;
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "inlineData");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "mimeType");
            try appendJsonString(allocator, out, src.media_type);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "data");
            try appendJsonString(allocator, out, src.data);
            try out.appendSlice(allocator, "}}");
        }
    }
    try out.appendSlice(allocator, "]}");
}

fn appendModelBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_content: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendContentPrefix(allocator, out, first_content, "model");
    try out.append(allocator, '[');
    var first_part = true;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try appendTextPart(allocator, out, blk.text orelse "");
        } else if (std.mem.eql(u8, blk.type, "thinking")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "text");
            try appendJsonString(allocator, out, blk.thinking orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "thought");
            try out.appendSlice(allocator, "true");
            if (blk.signature) |sig| {
                if (sig.len > 0) {
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, out, "thoughtSignature");
                    try appendJsonString(allocator, out, sig);
                }
            }
            try out.append(allocator, '}');
        } else if (std.mem.eql(u8, blk.type, "tool_use")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "functionCall");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "name");
            try appendJsonString(allocator, out, blk.name orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "args");
            if (blk.input == .null) {
                try out.appendSlice(allocator, "{}");
            } else {
                const args_json = try std.json.Stringify.valueAlloc(allocator, blk.input, .{});
                defer allocator.free(args_json);
                try out.appendSlice(allocator, args_json);
            }
            try out.appendSlice(allocator, "}");
            // A thoughtSignature may ride along on the functionCall part.
            if (blk.signature) |sig| {
                if (sig.len > 0) {
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, out, "thoughtSignature");
                    try appendJsonString(allocator, out, sig);
                }
            }
            try out.append(allocator, '}');
        }
    }
    try out.appendSlice(allocator, "]}");
}

fn appendToolResultBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_content: *bool,
    blocks: []const message.ToolResultBlock,
    id_to_name: std.StringHashMap([]const u8),
) !void {
    try appendContentPrefix(allocator, out, first_content, "user");
    try out.append(allocator, '[');
    for (blocks, 0..) |blk, i| {
        if (i > 0) try out.append(allocator, ',');
        const name = id_to_name.get(blk.tool_use_id) orelse blk.tool_use_id;
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, out, "functionResponse");
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, out, "name");
        try appendJsonString(allocator, out, name);
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "response");
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, out, "result");
        try appendJsonString(allocator, out, blk.content);
        try out.appendSlice(allocator, "}}}");
    }
    try out.appendSlice(allocator, "]}");
}

/// Serialize a tool's input schema as Gemini `parameters`. Gemini rejects an
/// object schema with no properties, so fall back to a bare object schema.
fn appendToolParameters(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    schema: message.ToolInputSchema,
) !void {
    const has_props = schema.properties == .object and schema.properties.object.count() > 0;
    if (!has_props) {
        try out.appendSlice(allocator, "{\"type\":\"object\"}");
        return;
    }
    const schema_json = try std.json.Stringify.valueAlloc(allocator, schema, .{});
    defer allocator.free(schema_json);
    try out.appendSlice(allocator, schema_json);
}

// === Streaming ===

/// Stream a Gemini `streamGenerateContent` response, reusing the shared
/// StreamAccumulator + buildStreamedResponseJson from client.zig.
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
    const body = try buildRequestBody(allocator, self.config.model, messages, tools, system_prompt, true, self.config.effort);
    defer allocator.free(body);

    const pretty_req = client.prettyJson(allocator, body) catch body;
    defer if (pretty_req.ptr != body.ptr) allocator.free(pretty_req);
    log.info("Gemini streaming request body:\n{s}", .{pretty_req});

    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse",
        .{ self.config.base_url, self.config.model },
    );
    defer allocator.free(url_str);
    const uri = try std.Uri.parse(url_str);

    const extra_headers = [_]std.http.Header{
        .{ .name = "x-goog-api-key", .value = self.config.api_key },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    log.info("Gemini: connecting to {s}/v1beta/models/{s}:streamGenerateContent", .{ self.config.base_url, self.config.model });

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
    log.info("Gemini: response status: {d}", .{@intFromEnum(response.head.status)});

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
        log.err("Gemini request failed {d}: {s}", .{ @intFromEnum(response.head.status), err_buf[0..err_pos] });
        return error.HttpRequestFailed;
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    var stream = client.StreamAccumulator.init(allocator);
    defer stream.deinit();

    try parseSseStream(allocator, body_reader, &stream, self.config.model, ctx, on_chunk, on_thinking_chunk, should_cancel);

    const response_bytes = try client.buildStreamedResponseJson(allocator, &stream);
    defer allocator.free(response_bytes);

    const pretty_resp = client.prettyJson(allocator, response_bytes) catch response_bytes;
    defer if (pretty_resp.ptr != response_bytes.ptr) allocator.free(pretty_resp);
    log.info("Gemini streamed response:\n{s}", .{pretty_resp});

    return std.json.parseFromSlice(
        message.MessagesResponse,
        allocator,
        response_bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

/// Append a text/thinking delta, merging into the last block when it is the
/// same type so consecutive parts coalesce into a single content block.
fn appendTextDelta(
    allocator: std.mem.Allocator,
    stream: *client.StreamAccumulator,
    block_type: client.StreamBlockType,
    delta: []const u8,
) !*client.StreamBlock {
    if (stream.blocks.items.len > 0) {
        const last = &stream.blocks.items[stream.blocks.items.len - 1];
        if (last.block_type == block_type) {
            try last.text.appendSlice(allocator, delta);
            return last;
        }
    }
    try stream.blocks.append(allocator, client.StreamBlock.init(block_type));
    const b = &stream.blocks.items[stream.blocks.items.len - 1];
    try b.text.appendSlice(allocator, delta);
    return b;
}

/// Parse Gemini `streamGenerateContent?alt=sse` output into a StreamAccumulator,
/// which `buildStreamedResponseJson` then serializes into the normalized shape.
fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream: *client.StreamAccumulator,
    model: []const u8,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
    should_cancel: client.CancelFn,
) !void {
    try stream.setOwnedString(&stream.model, model);
    var tool_count: usize = 0;
    var finish_reason_buf: [64]u8 = undefined;
    var finish_reason_len: usize = 0;

    while (true) {
        if (should_cancel(ctx)) return error.RequestCancelled;

        const line = try reader.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;

        if (!std.mem.startsWith(u8, trimmed, "data: ")) {
            log.debug("Gemini SSE non-data line: [{s}]", .{trimmed});
            continue;
        }
        const data = trimmed["data: ".len..];
        if (data.len == 0) continue;

        log.debug("Gemini SSE data: {s}", .{data});

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            arena.allocator(),
            data,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            log.err("Gemini SSE JSON parse error: {} — {s}", .{ err, data });
            continue;
        };
        const root = parsed.value;

        if (stream.id == null) {
            if (json_helpers.getStringField(root, "responseId")) |rid| {
                try stream.setOwnedString(&stream.id, rid);
            }
        }

        if (json_helpers.getObjectField(root, "usageMetadata")) |um| {
            if (json_helpers.getU64Field(um, "promptTokenCount")) |v| stream.input_tokens = v;
            var out_tokens: u64 = 0;
            if (json_helpers.getU64Field(um, "candidatesTokenCount")) |v| out_tokens += v;
            if (json_helpers.getU64Field(um, "thoughtsTokenCount")) |v| out_tokens += v;
            if (out_tokens > 0) stream.output_tokens = out_tokens;
        }

        const candidates = json_helpers.getField(root, "candidates") orelse continue;
        if (candidates != .array or candidates.array.items.len == 0) continue;
        const candidate = candidates.array.items[0];

        if (json_helpers.getStringField(candidate, "finishReason")) |fr| {
            finish_reason_len = @min(fr.len, finish_reason_buf.len);
            @memcpy(finish_reason_buf[0..finish_reason_len], fr[0..finish_reason_len]);
        }

        const content = json_helpers.getObjectField(candidate, "content") orelse continue;
        const parts = json_helpers.getField(content, "parts") orelse continue;
        if (parts != .array) continue;

        for (parts.array.items) |part| {
            if (json_helpers.getObjectField(part, "functionCall")) |func| {
                try stream.blocks.append(allocator, client.StreamBlock.init(.tool_use));
                const b = &stream.blocks.items[stream.blocks.items.len - 1];
                b.id = try std.fmt.allocPrint(allocator, "call_{d}", .{tool_count});
                tool_count += 1;
                if (json_helpers.getStringField(func, "name")) |nm| {
                    b.name = try allocator.dupe(u8, nm);
                }
                if (json_helpers.getObjectField(func, "args")) |args_val| {
                    const args_json = try std.json.Stringify.valueAlloc(allocator, args_val, .{});
                    defer allocator.free(args_json);
                    try b.input_json.appendSlice(allocator, args_json);
                }
                if (json_helpers.getStringField(part, "thoughtSignature")) |sig| {
                    try b.signature.appendSlice(allocator, sig);
                }
                continue;
            }

            const text = json_helpers.getStringField(part, "text") orelse continue;
            const is_thought = blk: {
                const tv = json_helpers.getField(part, "thought") orelse break :blk false;
                break :blk (tv == .bool and tv.bool);
            };

            if (is_thought) {
                const b = try appendTextDelta(allocator, stream, .thinking, text);
                if (json_helpers.getStringField(part, "thoughtSignature")) |sig| {
                    b.signature.clearRetainingCapacity();
                    try b.signature.appendSlice(allocator, sig);
                }
                if (text.len > 0) on_thinking_chunk(ctx, text);
            } else {
                _ = try appendTextDelta(allocator, stream, .text, text);
                if (text.len > 0) on_chunk(ctx, text);
            }
        }
    }

    var has_tool = false;
    for (stream.blocks.items) |b| {
        if (b.block_type == .tool_use) {
            has_tool = true;
            break;
        }
    }
    const fr = finish_reason_buf[0..finish_reason_len];
    const stop_reason: []const u8 = if (has_tool)
        "tool_use"
    else if (std.mem.eql(u8, fr, "STOP"))
        "end_turn"
    else if (std.mem.eql(u8, fr, "MAX_TOKENS"))
        "max_tokens"
    else if (fr.len > 0)
        fr
    else
        "end_turn";
    try stream.setOwnedString(&stream.stop_reason, stop_reason);
}

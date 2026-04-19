const std = @import("std");
const message = @import("message.zig");
const providers = @import("providers.zig");
const json_helpers = @import("../json_helpers.zig");

const log = std.log.scoped(.llm);

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    provider_name: []const u8,
    effort: message.Effort = .none,
};

pub const CancelFn = *const fn (*anyopaque) bool;

const anthropic_version = "2023-06-01";

const StreamBlockType = enum {
    text,
    tool_use,
    thinking,
};

const StreamBlock = struct {
    block_type: StreamBlockType,
    text: std.ArrayList(u8) = .{},
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    input_json: std.ArrayList(u8) = .{},
    signature: std.ArrayList(u8) = .{},

    fn init(block_type: StreamBlockType) StreamBlock {
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

const StreamAccumulator = struct {
    allocator: std.mem.Allocator,
    id: ?[]u8 = null,
    role: ?[]u8 = null,
    model: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    stop_sequence: ?[]u8 = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    blocks: std.ArrayList(StreamBlock) = .{},

    fn init(allocator: std.mem.Allocator) StreamAccumulator {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StreamAccumulator) void {
        if (self.id) |id| self.allocator.free(id);
        if (self.role) |role| self.allocator.free(role);
        if (self.model) |model| self.allocator.free(model);
        if (self.stop_reason) |stop_reason| self.allocator.free(stop_reason);
        if (self.stop_sequence) |stop_sequence| self.allocator.free(stop_sequence);
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
    }

    fn setOwnedString(self: *StreamAccumulator, target: *?[]u8, value: []const u8) !void {
        if (target.*) |old| self.allocator.free(old);
        target.* = try self.allocator.dupe(u8, value);
    }

    fn initBlockAt(self: *StreamAccumulator, index: usize, block_type: StreamBlockType) !*StreamBlock {
        if (index > self.blocks.items.len) return error.InvalidSseEvent;
        if (index == self.blocks.items.len) {
            try self.blocks.append(self.allocator, StreamBlock.init(block_type));
        } else {
            self.blocks.items[index].deinit(self.allocator);
            self.blocks.items[index] = StreamBlock.init(block_type);
        }
        return &self.blocks.items[index];
    }

    fn getBlock(self: *StreamAccumulator, index: usize) ?*StreamBlock {
        if (index >= self.blocks.items.len) return null;
        return &self.blocks.items[index];
    }
};

/// Parse `json_bytes` and re-serialize with indentation for readable logging.
/// Returns a new allocation — caller must free. Falls back to duping the
/// original bytes if parsing fails (so the caller can always free the result).
fn prettyJson(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
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

    /// Send a full conversation history and return the parsed response.
    /// Caller must call `.deinit()` on the returned `Parsed(T)`.
    pub fn sendMessage(
        self: *Client,
        allocator: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const message.ToolDefinition,
    ) !std.json.Parsed(message.MessagesResponse) {
        const model_info = providers.findModel(self.config.model);
        const req = message.MessagesRequest{
            .model = self.config.model,
            .messages = messages,
            .tools = tools,
            .effort = self.config.effort,
            .supports_thinking = model_info != null and model_info.?.model.supports_thinking,
        };

        const body = try std.json.Stringify.valueAlloc(allocator, req, .{});
        defer allocator.free(body);

        const pretty_req = prettyJson(allocator, body) catch body;
        defer if (pretty_req.ptr != body.ptr) allocator.free(pretty_req);
        log.info("request body:\n{s}", .{pretty_req});

        const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.config.base_url});
        defer allocator.free(url);

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.config.api_key },
            .{ .name = "anthropic-version", .value = anthropic_version },
        };

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &extra_headers,
            .response_writer = &aw.writer,
        });

        if (result.status != .ok) {
            const err_body = aw.writer.buffer[0..aw.writer.end];
            log.err("HTTP {d}: {s}", .{ @intFromEnum(result.status), err_body });
            return error.HttpRequestFailed;
        }

        const response_bytes = aw.writer.buffer[0..aw.writer.end];
        const pretty_resp = prettyJson(allocator, response_bytes) catch response_bytes;
        defer if (pretty_resp.ptr != response_bytes.ptr) allocator.free(pretty_resp);
        log.info("response body:\n{s}", .{pretty_resp});
        return std.json.parseFromSlice(
            message.MessagesResponse,
            allocator,
            response_bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
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
        if (std.mem.eql(u8, self.config.provider_name, "OpenAI")) {
            return self.sendMessageStreamingOpenAI(allocator, messages, tools, system_prompt, ctx, on_chunk, should_cancel);
        }
        return self.sendMessageStreamingAnthropic(allocator, messages, tools, system_prompt, ctx, on_chunk, on_thinking_chunk, should_cancel);
    }

    fn sendMessageStreamingAnthropic(
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
        const model_info = providers.findModel(self.config.model);
        const req_body = message.MessagesRequest{
            .model = self.config.model,
            .messages = messages,
            .system = system_prompt,
            .stream = true,
            .tools = tools,
            .effort = self.config.effort,
            .supports_thinking = model_info != null and model_info.?.model.supports_thinking,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, req_body, .{});
        defer allocator.free(body);

        const pretty_req = prettyJson(allocator, body) catch body;
        defer if (pretty_req.ptr != body.ptr) allocator.free(pretty_req);
        log.info("streaming request body:\n{s}", .{pretty_req});

        const url_str = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.config.base_url});
        defer allocator.free(url_str);
        const uri = try std.Uri.parse(url_str);

        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.config.api_key },
            .{ .name = "anthropic-version", .value = anthropic_version },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        log.info("connecting to {s}", .{url_str});

        var http_req = try self.http_client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &extra_headers,
            .keep_alive = false,
        });
        defer http_req.deinit();

        log.info("sending request body ({d} bytes)", .{body.len});
        try http_req.sendBodyComplete(body);

        log.info("waiting for response headers", .{});
        var redirect_buf: [4096]u8 = undefined;
        var response = try http_req.receiveHead(&redirect_buf);
        log.info("response status: {d}", .{@intFromEnum(response.head.status)});

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
            log.err("request failed with status {d}: {s}", .{ @intFromEnum(response.head.status), err_buf[0..err_pos] });
            return error.HttpRequestFailed;
        }

        log.info("starting SSE stream", .{});
        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var stream = StreamAccumulator.init(allocator);
        defer stream.deinit();

        try parseSseStream(allocator, body_reader, &stream, ctx, on_chunk, on_thinking_chunk, should_cancel);

        const response_bytes = try buildStreamedResponseJson(allocator, &stream);
        defer allocator.free(response_bytes);

        const pretty_resp = prettyJson(allocator, response_bytes) catch response_bytes;
        defer if (pretty_resp.ptr != response_bytes.ptr) allocator.free(pretty_resp);
        log.info("streamed response body:\n{s}", .{pretty_resp});

        log.info("SSE stream complete", .{});

        return std.json.parseFromSlice(
            message.MessagesResponse,
            allocator,
            response_bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    fn sendMessageStreamingOpenAI(
        self: *Client,
        allocator: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const message.ToolDefinition,
        system_prompt: ?[]const u8,
        ctx: *anyopaque,
        on_chunk: *const fn (*anyopaque, []const u8) void,
        should_cancel: CancelFn,
    ) !std.json.Parsed(message.MessagesResponse) {
        const body = try buildOpenAIRequestBody(allocator, self.config.model, messages, tools, system_prompt, true);
        defer allocator.free(body);

        const pretty_req = prettyJson(allocator, body) catch body;
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

        try parseOpenAISseStream(allocator, body_reader, &oai_stream, ctx, on_chunk, should_cancel);

        const response_bytes = try buildOpenAIStreamedResponseJson(allocator, &oai_stream, self.config.model);
        defer allocator.free(response_bytes);

        const pretty_resp = prettyJson(allocator, response_bytes) catch response_bytes;
        defer if (pretty_resp.ptr != response_bytes.ptr) allocator.free(pretty_resp);
        log.info("OpenAI streamed response:\n{s}", .{pretty_resp});

        return std.json.parseFromSlice(
            message.MessagesResponse,
            allocator,
            response_bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }
};

// === SSE Parser ===

fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream: *StreamAccumulator,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
    should_cancel: CancelFn,
) !void {
    // event_name is copied into this buffer so it survives the next reader call
    var event_name_buf: [64]u8 = undefined;
    var event_name_len: usize = 0;
    var data_buf = std.ArrayListUnmanaged(u8){};
    defer data_buf.deinit(allocator);

    while (true) {
        if (should_cancel(ctx)) return error.RequestCancelled;

        // takeDelimiter returns null at end-of-stream, slice otherwise
        const line = try reader.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r");

        if (trimmed.len == 0) {
            const event_name = event_name_buf[0..event_name_len];
            if (event_name.len > 0) {
                try handleSseEvent(allocator, stream, event_name, data_buf.items, ctx, on_chunk, on_thinking_chunk);
            }
            if (std.mem.eql(u8, event_name, "message_stop")) {
                break;
            }
            event_name_len = 0;
            data_buf.clearRetainingCapacity();
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "event: ")) {
            // Copy event name — the slice into reader buffer is invalidated on next read
            const name = trimmed["event: ".len..];
            event_name_len = @min(name.len, event_name_buf.len);
            @memcpy(event_name_buf[0..event_name_len], name[0..event_name_len]);
            log.debug("SSE event: {s}", .{name});
        } else if (std.mem.startsWith(u8, trimmed, "data: ")) {
            if (data_buf.items.len > 0) try data_buf.append(allocator, '\n');
            try data_buf.appendSlice(allocator, trimmed["data: ".len..]);
        } else {
            log.debug("SSE raw line: [{s}]", .{trimmed});
        }
    }
}

fn handleSseEvent(
    allocator: std.mem.Allocator,
    stream: *StreamAccumulator,
    event_name: []const u8,
    data: []const u8,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
) !void {
    if (data.len == 0) return;

    log.debug("SSE {s}: {s}", .{ event_name, data });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        data,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        log.err("failed to parse SSE JSON for {s}: {} — data: {s}", .{ event_name, err, data });
        return;
    };
    const root = parsed.value;

    if (std.mem.eql(u8, event_name, "message_start")) {
        const msg_obj = json_helpers.getObjectField(root, "message") orelse return;
        if (json_helpers.getStringField(msg_obj, "id")) |id| try stream.setOwnedString(&stream.id, id);
        if (json_helpers.getStringField(msg_obj, "role")) |role| try stream.setOwnedString(&stream.role, role);
        if (json_helpers.getStringField(msg_obj, "model")) |model| try stream.setOwnedString(&stream.model, model);
        if (json_helpers.getObjectField(msg_obj, "usage")) |usage_obj| {
            if (json_helpers.getU64Field(usage_obj, "input_tokens")) |input_tokens| stream.input_tokens = input_tokens;
            if (json_helpers.getU64Field(usage_obj, "output_tokens")) |output_tokens| stream.output_tokens = output_tokens;
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "content_block_start")) {
        const index = json_helpers.getU64Field(root, "index") orelse return;
        const block_obj = json_helpers.getObjectField(root, "content_block") orelse return;
        const block_type = json_helpers.getStringField(block_obj, "type") orelse return;
        const block_kind: StreamBlockType = if (std.mem.eql(u8, block_type, "tool_use")) .tool_use else if (std.mem.eql(u8, block_type, "thinking")) .thinking else .text;
        const block = try stream.initBlockAt(index, block_kind);

        if (block_kind == .text) {
            if (json_helpers.getStringField(block_obj, "text")) |text| try block.text.appendSlice(allocator, text);
            return;
        }

        if (json_helpers.getStringField(block_obj, "id")) |id| block.id = try allocator.dupe(u8, id);
        if (json_helpers.getStringField(block_obj, "name")) |name| block.name = try allocator.dupe(u8, name);
        if (json_helpers.getField(block_obj, "input")) |input_val| {
            const input_json = try std.json.Stringify.valueAlloc(arena.allocator(), input_val, .{});
            if (!std.mem.eql(u8, input_json, "null") and !std.mem.eql(u8, input_json, "{}")) {
                try block.input_json.appendSlice(allocator, input_json);
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "content_block_delta")) {
        const index = json_helpers.getU64Field(root, "index") orelse return;
        const delta_obj = json_helpers.getObjectField(root, "delta") orelse return;
        const delta_type = json_helpers.getStringField(delta_obj, "type") orelse return;
        const block = stream.getBlock(index) orelse return;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = json_helpers.getStringField(delta_obj, "text") orelse return;
            try block.text.appendSlice(allocator, text);
            if (text.len > 0) on_chunk(ctx, text);
            return;
        }

        if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            const text = json_helpers.getStringField(delta_obj, "thinking") orelse return;
            try block.text.appendSlice(allocator, text);
            if (text.len > 0) on_thinking_chunk(ctx, text);
            return;
        }

        if (std.mem.eql(u8, delta_type, "signature_delta")) {
            const sig = json_helpers.getStringField(delta_obj, "signature") orelse return;
            try block.signature.appendSlice(allocator, sig);
            return;
        }

        if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            const partial_json = json_helpers.getStringField(delta_obj, "partial_json") orelse json_helpers.getStringField(delta_obj, "text") orelse return;
            try block.input_json.appendSlice(allocator, partial_json);
            return;
        }

        return;
    }

    if (std.mem.eql(u8, event_name, "message_delta")) {
        if (json_helpers.getObjectField(root, "delta")) |delta_obj| {
            if (json_helpers.getStringField(delta_obj, "stop_reason")) |stop_reason| try stream.setOwnedString(&stream.stop_reason, stop_reason);
            if (json_helpers.getStringField(delta_obj, "stop_sequence")) |stop_sequence| try stream.setOwnedString(&stream.stop_sequence, stop_sequence);
        }
        if (json_helpers.getObjectField(root, "usage")) |usage_obj| {
            if (json_helpers.getU64Field(usage_obj, "output_tokens")) |output_tokens| stream.output_tokens = output_tokens;
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "error")) {
        if (json_helpers.getObjectField(root, "error")) |err_obj| {
            if (json_helpers.getStringField(err_obj, "message")) |msg| log.err("stream error: {s}", .{msg});
        }
        return error.HttpRequestFailed;
    }
}

fn buildStreamedResponseJson(allocator: std.mem.Allocator, stream: *const StreamAccumulator) ![]u8 {
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

fn appendObjectFieldName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hexDigit(ch >> 4));
                    try out.append(allocator, hexDigit(ch & 0x0F));
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

// === OpenAI Support ===

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

fn parseOpenAISseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream: *OpenAIStreamAccumulator,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
    should_cancel: CancelFn,
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
fn buildOpenAIStreamedResponseJson(
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

/// Serialize messages and tools to OpenAI chat completions request JSON.
fn buildOpenAIRequestBody(
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
        // Request usage in the stream's final chunk
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "stream_options");
        try out.appendSlice(allocator, "{\"include_usage\":true}");
    }

    // Tools
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
            // Serialize the input_schema as OpenAI "parameters"
            const schema_json = try std.json.Stringify.valueAlloc(allocator, tool.input_schema, .{});
            defer allocator.free(schema_json);
            try out.appendSlice(allocator, schema_json);
            try out.appendSlice(allocator, "}}");
        }
        try out.append(allocator, ']');
    }

    // Messages
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "messages");
    try out.append(allocator, '[');

    var first_msg = true;
    if (system_prompt) |sp| {
        try out.appendSlice(allocator, "{");
        try appendObjectFieldName(allocator, &out, "role");
        try appendJsonString(allocator, &out, "system");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "content");
        try appendJsonString(allocator, &out, sp);
        try out.append(allocator, '}');
        first_msg = false;
    }

    for (messages) |msg| {
        switch (msg.content) {
            .text => |text| {
                if (!first_msg) try out.append(allocator, ',');
                first_msg = false;
                try out.appendSlice(allocator, "{");
                try appendObjectFieldName(allocator, &out, "role");
                try appendJsonString(allocator, &out, @tagName(msg.role));
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "content");
                try appendJsonString(allocator, &out, text);
                try out.append(allocator, '}');
            },
            .content_blocks => |blocks| {
                // Assistant message with possible text + tool_calls
                if (!first_msg) try out.append(allocator, ',');
                first_msg = false;
                try out.appendSlice(allocator, "{");
                try appendObjectFieldName(allocator, &out, "role");
                try appendJsonString(allocator, &out, "assistant");

                // Collect text and tool_use blocks separately
                var text_content: ?[]const u8 = null;
                var tool_use_count: usize = 0;
                for (blocks) |blk| {
                    if (std.mem.eql(u8, blk.type, "text")) text_content = blk.text;
                    if (std.mem.eql(u8, blk.type, "tool_use")) tool_use_count += 1;
                }

                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "content");
                if (text_content) |t| {
                    try appendJsonString(allocator, &out, t);
                } else {
                    try appendJsonString(allocator, &out, "");
                }

                if (tool_use_count > 0) {
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, &out, "tool_calls");
                    try out.append(allocator, '[');
                    var first_tc = true;
                    for (blocks) |blk| {
                        if (!std.mem.eql(u8, blk.type, "tool_use")) continue;
                        if (!first_tc) try out.append(allocator, ',');
                        first_tc = false;
                        try out.appendSlice(allocator, "{");
                        try appendObjectFieldName(allocator, &out, "id");
                        try appendJsonString(allocator, &out, blk.id orelse "");
                        try out.append(allocator, ',');
                        try appendObjectFieldName(allocator, &out, "type");
                        try appendJsonString(allocator, &out, "function");
                        try out.append(allocator, ',');
                        try appendObjectFieldName(allocator, &out, "function");
                        try out.appendSlice(allocator, "{");
                        try appendObjectFieldName(allocator, &out, "name");
                        try appendJsonString(allocator, &out, blk.name orelse "");
                        try out.append(allocator, ',');
                        try appendObjectFieldName(allocator, &out, "arguments");
                        // input is a json.Value — serialize it as a JSON string (OpenAI expects string)
                        const args_json = try std.json.Stringify.valueAlloc(allocator, blk.input, .{});
                        defer allocator.free(args_json);
                        try appendJsonString(allocator, &out, args_json);
                        try out.appendSlice(allocator, "}}");
                    }
                    try out.append(allocator, ']');
                }

                try out.append(allocator, '}');
            },
            .tool_result_blocks => |blocks| {
                // Each tool result becomes a separate "tool" role message
                for (blocks) |blk| {
                    if (!first_msg) try out.append(allocator, ',');
                    first_msg = false;
                    try out.appendSlice(allocator, "{");
                    try appendObjectFieldName(allocator, &out, "role");
                    try appendJsonString(allocator, &out, "tool");
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, &out, "tool_call_id");
                    try appendJsonString(allocator, &out, blk.tool_use_id);
                    try out.append(allocator, ',');
                    try appendObjectFieldName(allocator, &out, "content");
                    try appendJsonString(allocator, &out, blk.content);
                    try out.append(allocator, '}');
                }
            },
        }
    }

    try out.append(allocator, ']');
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

// === Tests ===

const test_config: Config = .{
    .base_url = "http://localhost:9999",
    .api_key = "mock-key",
    .model = "mock-model",
};

test "chat returns a text response from local server" {
    const alloc = std.testing.allocator;
    var client = Client.init(alloc, test_config);
    defer client.deinit();

    const resp = client.chat(alloc, "hello") catch |err| switch (err) {
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

    const resp = client.sendMessage(alloc, &msgs, &.{}) catch |err| switch (err) {
        error.ConnectionRefused => return error.ServerNotRunning,
        else => return err,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("assistant", resp.value.role);
    try std.testing.expect(resp.value.textContent() != null);
}

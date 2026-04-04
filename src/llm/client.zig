const std = @import("std");
const message = @import("message.zig");

const log = std.log.scoped(.llm);

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

const anthropic_version = "2023-06-01";

const StreamBlockType = enum {
    text,
    tool_use,
};

const StreamBlock = struct {
    block_type: StreamBlockType,
    text: std.ArrayList(u8) = .{},
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    input_json: std.ArrayList(u8) = .{},

    fn init(block_type: StreamBlockType) StreamBlock {
        return .{ .block_type = block_type };
    }

    fn deinit(self: *StreamBlock, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.input_json.deinit(allocator);
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
        const req = message.MessagesRequest{
            .model = self.config.model,
            .messages = messages,
            .tools = tools,
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

    /// Send messages with streaming. Calls `on_chunk(ctx, text)` for each text token.
    /// The text slice is only valid during the callback — copy it if needed.
    pub fn sendMessageStreaming(
        self: *Client,
        allocator: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const message.ToolDefinition,
        ctx: *anyopaque,
        on_chunk: *const fn (*anyopaque, []const u8) void,
    ) !std.json.Parsed(message.MessagesResponse) {
        const req_body = message.MessagesRequest{
            .model = self.config.model,
            .messages = messages,
            .stream = true,
            .tools = tools,
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
            log.err("request failed with status {d}", .{@intFromEnum(response.head.status)});
            return error.HttpRequestFailed;
        }

        log.info("starting SSE stream", .{});
        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var stream = StreamAccumulator.init(allocator);
        defer stream.deinit();

        try parseSseStream(allocator, body_reader, &stream, ctx, on_chunk);

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
};

// === SSE Parser ===

fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream: *StreamAccumulator,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
) !void {
    // event_name is copied into this buffer so it survives the next reader call
    var event_name_buf: [64]u8 = undefined;
    var event_name_len: usize = 0;
    var data_buf = std.ArrayListUnmanaged(u8){};
    defer data_buf.deinit(allocator);

    while (true) {
        // takeDelimiter returns null at end-of-stream, slice otherwise
        const line = try reader.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r");

        if (trimmed.len == 0) {
            const event_name = event_name_buf[0..event_name_len];
            if (event_name.len > 0) {
                try handleSseEvent(allocator, stream, event_name, data_buf.items, ctx, on_chunk);
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
        const msg_obj = getObjectField(root, "message") orelse return;
        if (getStringField(msg_obj, "id")) |id| try stream.setOwnedString(&stream.id, id);
        if (getStringField(msg_obj, "role")) |role| try stream.setOwnedString(&stream.role, role);
        if (getStringField(msg_obj, "model")) |model| try stream.setOwnedString(&stream.model, model);
        if (getObjectField(msg_obj, "usage")) |usage_obj| {
            if (getU64Field(usage_obj, "input_tokens")) |input_tokens| stream.input_tokens = input_tokens;
            if (getU64Field(usage_obj, "output_tokens")) |output_tokens| stream.output_tokens = output_tokens;
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "content_block_start")) {
        const index = getU64Field(root, "index") orelse return;
        const block_obj = getObjectField(root, "content_block") orelse return;
        const block_type = getStringField(block_obj, "type") orelse return;
        const block_kind: StreamBlockType = if (std.mem.eql(u8, block_type, "tool_use")) .tool_use else .text;
        const block = try stream.initBlockAt(index, block_kind);

        if (block_kind == .text) {
            if (getStringField(block_obj, "text")) |text| try block.text.appendSlice(allocator, text);
            return;
        }

        if (getStringField(block_obj, "id")) |id| block.id = try allocator.dupe(u8, id);
        if (getStringField(block_obj, "name")) |name| block.name = try allocator.dupe(u8, name);
        if (getField(block_obj, "input")) |input_val| {
            const input_json = try std.json.Stringify.valueAlloc(arena.allocator(), input_val, .{});
            if (!std.mem.eql(u8, input_json, "null") and !std.mem.eql(u8, input_json, "{}")) {
                try block.input_json.appendSlice(allocator, input_json);
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "content_block_delta")) {
        const index = getU64Field(root, "index") orelse return;
        const delta_obj = getObjectField(root, "delta") orelse return;
        const delta_type = getStringField(delta_obj, "type") orelse return;
        const block = stream.getBlock(index) orelse return;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = getStringField(delta_obj, "text") orelse return;
            try block.text.appendSlice(allocator, text);
            if (text.len > 0) on_chunk(ctx, text);
            return;
        }

        if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            const partial_json = getStringField(delta_obj, "partial_json") orelse getStringField(delta_obj, "text") orelse return;
            try block.input_json.appendSlice(allocator, partial_json);
            return;
        }

        return;
    }

    if (std.mem.eql(u8, event_name, "message_delta")) {
        if (getObjectField(root, "delta")) |delta_obj| {
            if (getStringField(delta_obj, "stop_reason")) |stop_reason| try stream.setOwnedString(&stream.stop_reason, stop_reason);
            if (getStringField(delta_obj, "stop_sequence")) |stop_sequence| try stream.setOwnedString(&stream.stop_sequence, stop_sequence);
        }
        if (getObjectField(root, "usage")) |usage_obj| {
            if (getU64Field(usage_obj, "output_tokens")) |output_tokens| stream.output_tokens = output_tokens;
        }
        return;
    }

    if (std.mem.eql(u8, event_name, "error")) {
        if (getObjectField(root, "error")) |err_obj| {
            if (getStringField(err_obj, "message")) |msg| log.err("stream error: {s}", .{msg});
        }
        return error.HttpRequestFailed;
    }
}

fn getField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    const child = getField(value, field) orelse return null;
    if (child != .object) return null;
    return child;
}

fn getStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    const child = getField(value, field) orelse return null;
    if (child != .string) return null;
    return child.string;
}

fn getU64Field(value: std.json.Value, field: []const u8) ?u64 {
    const child = getField(value, field) orelse return null;
    return switch (child) {
        .integer => |num| if (num >= 0) @intCast(num) else null,
        .float => |num| if (num >= 0) @intFromFloat(num) else null,
        .number_string => |num| std.fmt.parseUnsigned(u64, num, 10) catch null,
        else => null,
    };
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
        try appendJsonString(allocator, &out, if (block.block_type == .tool_use) "tool_use" else "text");

        switch (block.block_type) {
            .text => {
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "text");
                try appendJsonString(allocator, &out, block.text.items);
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

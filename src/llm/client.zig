const std = @import("std");
const message = @import("message.zig");

const log = std.log.scoped(.llm);

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

const anthropic_version = "2023-06-01";

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
        ctx: *anyopaque,
        on_chunk: *const fn (*anyopaque, []const u8) void,
    ) !void {
        const req_body = message.MessagesRequest{
            .model = self.config.model,
            .messages = messages,
            .stream = true,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, req_body, .{});
        defer allocator.free(body);

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
        try parseSseStream(allocator, body_reader, ctx, on_chunk);
        log.info("SSE stream complete", .{});
    }
};

// === SSE Parser ===

fn parseSseStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
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
            if (std.mem.eql(u8, event_name, "content_block_delta")) {
                try dispatchDelta(allocator, data_buf.items, ctx, on_chunk);
            } else if (std.mem.eql(u8, event_name, "message_stop")) {
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
            try data_buf.appendSlice(allocator, trimmed["data: ".len..]);
        } else {
            log.debug("SSE raw line: [{s}]", .{trimmed});
        }
    }
}

fn dispatchDelta(
    allocator: std.mem.Allocator,
    data: []const u8,
    ctx: *anyopaque,
    on_chunk: *const fn (*anyopaque, []const u8) void,
) !void {
    log.debug("dispatching delta data: {s}", .{data});
    const parsed = std.json.parseFromSlice(
        message.ContentBlockDeltaEvent,
        allocator,
        data,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        log.err("failed to parse delta JSON: {} — data: {s}", .{ err, data });
        return;
    };
    defer parsed.deinit();

    const delta = parsed.value.delta;
    log.debug("delta type={s} text={s}", .{ delta.type, delta.text });
    if (std.mem.eql(u8, delta.type, "text_delta") and delta.text.len > 0) {
        on_chunk(ctx, delta.text);
    }
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

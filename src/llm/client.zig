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

pub const RequestError = error{
    ProviderAuthenticationFailed,
    ProviderHttpRequestFailed,
};

/// Map a non-200 provider HTTP status to a typed request error. 401/403 are
/// treated as authentication failures; everything else is a generic provider
/// request failure.
pub fn statusToError(status: std.http.Status) RequestError {
    return switch (status) {
        .unauthorized, .forbidden => error.ProviderAuthenticationFailed,
        else => error.ProviderHttpRequestFailed,
    };
}

/// Read up to `buffer.len` bytes of a provider error body after the response
/// headers. Streams into a fixed writer rather than `readSliceShort`: the
/// latter swallows `EndOfStream` from the std HTTP reader once some bytes have
/// been copied (Reader.readVec), then loops and re-enters the reader after it
/// transitions to `.ready`, panicking on the `body_remaining_content_length`
/// union access. `stream` propagates `EndOfStream` cleanly, so we stop at it
/// (or at a full buffer via `WriteFailed`). A read failure is non-fatal: it
/// logs and yields whatever was read so non-200 handling never depends on the
/// body being readable.
pub fn readErrorBodySnippet(response_reader: *std.Io.Reader, buffer: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buffer);
    while (true) {
        _ = response_reader.stream(&w, .limited(buffer.len - w.end)) catch |err| switch (err) {
            error.EndOfStream, error.WriteFailed => break,
            error.ReadFailed => {
                log.warn("could not read provider error body: {}", .{err});
                break;
            },
        };
        if (w.end == buffer.len) break;
    }
    return w.buffered();
}

/// Build a user-facing message for a request error. Never includes the API key.
/// Caller owns the returned slice.
pub fn requestErrorMessage(allocator: std.mem.Allocator, err: anyerror, provider_name: []const u8) ![]u8 {
    return switch (err) {
        error.ProviderAuthenticationFailed => std.fmt.allocPrint(
            allocator,
            "Provider authentication failed. Check the API key for {s} with /provider.",
            .{provider_name},
        ),
        error.ProviderHttpRequestFailed => allocator.dupe(
            u8,
            "Provider request failed. Check ~/.config/agent-zig/agent.log for details.",
        ),
        else => allocator.dupe(u8, "Service is not working, try later"),
    };
}

pub const Backend = enum { anthropic, openai, gemini };

fn backendFor(name: []const u8) Backend {
    const map = std.StaticStringMap(Backend).initComptime(.{
        .{ "Anthropic", .anthropic },
        .{ "OpenAI", .openai },
        .{ "DeepSeek", .anthropic }, // uses DeepSeek's Anthropic-compatible /anthropic/v1/messages
        .{ "Gemini", .gemini },
        .{ "OpenRouter", .openai }, // OpenAI-compatible /api/v1/chat/completions
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
    /// Cache for `connectPreferIpv4`: the hostname last resolved and the IPv4
    /// literal it produced. Owned by `http_client.allocator`. Lets DNS run once
    /// per host instead of on every streaming request; re-resolved only when
    /// the host changes (e.g. switching providers).
    ipv4_host: ?[]u8 = null,
    ipv4_addr: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{
            .http_client = std.http.Client{ .allocator = allocator },
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.ipv4_host) |h| self.http_client.allocator.free(h);
        if (self.ipv4_addr) |a| self.http_client.allocator.free(a);
        self.http_client.deinit();
    }

    /// Open a TLS connection to `host:port`, preferring an IPv4 address.
    ///
    /// Works around a std.net limitation: `tcpConnectToHost` tries resolved
    /// addresses in RFC-6724 order (IPv6 first when the host has a global IPv6
    /// source address) with a blocking connect, and only advances to the next
    /// address on `ConnectionRefused` — never on `ConnectionTimedOut`. On a host
    /// whose IPv6 route is dead (e.g. a VPN), connecting to a Cloudflare-fronted
    /// host like openrouter.ai hangs then fails without ever trying the working
    /// IPv4 address.
    ///
    /// We connect to the cached IPv4 literal so std skips IPv6; `proxied_host`
    /// keeps the TLS SNI (and pool key) on the real hostname so Cloudflare still
    /// routes the request. Falls back to the default resolver when no IPv4
    /// address is available.
    pub fn connectPreferIpv4(
        self: *Client,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
    ) !*std.http.Client.Connection {
        const http_client = &self.http_client;

        // `request()` lazily scans the CA bundle before it connects; since we
        // open the TLS connection ourselves *before* calling `request()`, do the
        // scan here too or TLS init fails with an empty bundle. Runs once because
        // std clears `next_https_rescan_certs` after the first scan.
        if (@atomicLoad(bool, &http_client.next_https_rescan_certs, .acquire)) {
            http_client.ca_bundle_mutex.lock();
            defer http_client.ca_bundle_mutex.unlock();
            if (http_client.next_https_rescan_certs) {
                try http_client.ca_bundle.rescan(allocator);
                @atomicStore(bool, &http_client.next_https_rescan_certs, false, .release);
            }
        }

        if (self.resolvedIpv4(host, port)) |ip| {
            return http_client.connectTcpOptions(.{
                .host = ip, // numeric literal → std connects IPv4, no IPv6 attempt
                .port = port,
                .protocol = .tls,
                .proxied_host = host, // TLS SNI + Host header stay the real hostname
                .proxied_port = port,
            });
        }

        return http_client.connectTcp(host, port, .tls);
    }

    /// Return a cached IPv4 literal for `host`, resolving (and caching) on a
    /// miss. Cache strings use the long-lived client allocator. Returns null
    /// when no IPv4 address is available so the caller falls back to the
    /// default resolver.
    fn resolvedIpv4(self: *Client, host: []const u8, port: u16) ?[]const u8 {
        if (self.ipv4_host) |cached_host| {
            if (std.mem.eql(u8, cached_host, host)) return self.ipv4_addr;
        }

        const gpa = self.http_client.allocator;
        const list = std.net.getAddressList(gpa, host, port) catch |err| {
            log.warn("connectPreferIpv4: getAddressList({s}) failed: {} — using default resolver", .{ host, err });
            return null;
        };
        defer list.deinit();

        var ip_buf: [15]u8 = undefined;
        var ip: ?[]const u8 = null;
        for (list.addrs) |addr| {
            if (addr.any.family != std.posix.AF.INET) continue;
            const octets = std.mem.asBytes(&addr.in.sa.addr); // 4 bytes, network order
            ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
                octets[0], octets[1], octets[2], octets[3],
            }) catch continue;
            break;
        }
        const resolved = ip orelse {
            log.warn("connectPreferIpv4: no IPv4 address for {s} — using default resolver", .{host});
            return null;
        };

        const new_host = gpa.dupe(u8, host) catch |err| {
            log.warn("connectPreferIpv4: cache alloc failed: {} — not caching", .{err});
            return null;
        };
        const new_addr = gpa.dupe(u8, resolved) catch |err| {
            log.warn("connectPreferIpv4: cache alloc failed: {} — not caching", .{err});
            gpa.free(new_host);
            return null;
        };
        if (self.ipv4_host) |h| gpa.free(h);
        if (self.ipv4_addr) |a| gpa.free(a);
        self.ipv4_host = new_host;
        self.ipv4_addr = new_addr;
        return self.ipv4_addr;
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

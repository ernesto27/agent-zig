//! One MCP server connection, transport-agnostic.
//!
//! Lifecycle:
//!   spawnStdio | connectHttp → initialize → (listTools | callTool)* → shutdown
//!
//! The high-level MCP methods (`initialize`, `listTools`, `callTool`) speak
//! JSON-RPC and don't care how bytes move — that's the `Transport` union's job
//! (`stdio_transport.zig` for subprocesses, `http_transport.zig` for hosted
//! Streamable HTTP servers). Requests are synchronous; the caller (the agentic
//! loop) is already on a background thread, so blocking reads are fine.

const std = @import("std");
const protocol = @import("protocol.zig");
const json_helpers = @import("../json_helpers.zig");
const StdioTransport = @import("stdio_transport.zig").StdioTransport;
const HttpTransport = @import("http_transport.zig").HttpTransport;

const log = std.log.scoped(.mcp);

/// How an McpClient moves JSON-RPC bytes. Two transports, both known at
/// compile time — a tagged union (not a vtable) keeps dispatch monomorphic and
/// matches the rest of the codebase's plain-struct style.
pub const Transport = union(enum) {
    stdio: *StdioTransport,
    http: *HttpTransport,

    /// Send a serialized request body and block for the response frame with
    /// `id`. Caller owns the returned Parsed.
    pub fn roundtrip(self: Transport, gpa: std.mem.Allocator, id: u64, body: []u8) !std.json.Parsed(std.json.Value) {
        return switch (self) {
            inline else => |t| t.roundtrip(gpa, id, body),
        };
    }

    /// Fire-and-forget a notification body (no response expected).
    pub fn send(self: Transport, body: []u8) !void {
        return switch (self) {
            inline else => |t| t.send(body),
        };
    }

    pub fn deinit(self: Transport) void {
        switch (self) {
            inline else => |t| t.deinit(),
        }
    }
};

const empty_params: struct {} = .{};

/// Catalog entry returned by tools/list.
pub const Tool = struct {
    name: []const u8,                  // server's native name, unprefixed
    description: []const u8,
    input_schema_json: []const u8,     // raw JSON of inputSchema, passthrough

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

pub fn freeTools(allocator: std.mem.Allocator, tools: []Tool) void {
    for (tools) |t| t.deinit(allocator);
    allocator.free(tools);
}

/// Result of tools/call. `text` is the concatenation of all `text` content
/// parts. Non-text parts are surfaced as `[<type> content omitted]` markers
/// until v2 handles them properly.
pub const CallResult = struct {
    text: []const u8,
    is_error: bool,

    pub fn deinit(self: CallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    server_name: []u8,                  // owned
    transport: Transport,
    next_id: u64 = 1,

    /// Tool catalog from the most recent `tools/list`. Owned by this
    /// McpClient's allocator (independent of any per-turn arena) so it can
    /// be looked up at confirmation time to display the tool's description
    /// in the modal. Refreshed by `refreshTools()`.
    cached_tools: []Tool = &.{},

    /// Connect to a server running as a subprocess (stdio transport).
    pub fn spawnStdio(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        command: []const u8,
        args: []const []const u8,
    ) !*McpClient {
        const transport = try StdioTransport.spawn(allocator, server_name, command, args);
        errdefer transport.deinit();
        return create(allocator, server_name, .{ .stdio = transport });
    }

    /// Connect to a hosted server over Streamable HTTP. `headers` are extra
    /// request headers (e.g. Authorization) borrowed from config; the
    /// transport dupes what it keeps.
    pub fn connectHttp(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        url: []const u8,
        headers: []const std.http.Header,
    ) !*McpClient {
        const transport = try HttpTransport.connect(allocator, server_name, url, headers);
        errdefer transport.deinit();
        return create(allocator, server_name, .{ .http = transport });
    }

    fn create(allocator: std.mem.Allocator, server_name: []const u8, transport: Transport) !*McpClient {
        const self = try allocator.create(McpClient);
        errdefer allocator.destroy(self);
        const name_copy = try allocator.dupe(u8, server_name);
        self.* = .{
            .allocator = allocator,
            .server_name = name_copy,
            .transport = transport,
        };
        return self;
    }

    /// Tear down the transport, free the tool cache, destroy the client.
    pub fn shutdown(self: *McpClient) void {
        self.transport.deinit();
        self.freeCachedTools();
        self.allocator.free(self.server_name);
        self.allocator.destroy(self);
    }

    fn freeCachedTools(self: *McpClient) void {
        for (self.cached_tools) |t| t.deinit(self.allocator);
        self.allocator.free(self.cached_tools);
        self.cached_tools = &.{};
    }

    /// Re-fetch the tool catalog and replace `cached_tools`. Safe to call
    /// repeatedly — old entries are freed before the new slice is stored.
    pub fn refreshTools(self: *McpClient) !void {
        const new_tools = try self.listTools(self.allocator);
        self.freeCachedTools();
        self.cached_tools = new_tools;
    }

    /// O(N) lookup by name (catalog is small). Returns null if unknown.
    pub fn findToolDescription(self: *const McpClient, name: []const u8) ?[]const u8 {
        for (self.cached_tools) |t| {
            if (std.mem.eql(u8, t.name, name)) return t.description;
        }
        return null;
    }

    // ───── high-level MCP methods ─────────────────────────────────────────

    pub fn initialize(self: *McpClient) !void {
        const Params = struct {
            protocolVersion: []const u8,
            capabilities: struct {} = .{},
            clientInfo: struct {
                name: []const u8,
                version: []const u8,
            },
        };
        var parsed = try self.requestRaw("initialize", Params{
            .protocolVersion = "2025-11-25",
            .clientInfo = .{ .name = "zigent", .version = "0.0.0" },
        });
        defer parsed.deinit();

        if (json_helpers.getObjectField(parsed.value, "result")) |result| {
            if (json_helpers.getStringField(result, "protocolVersion")) |v| {
                log.info("[{s}] negotiated protocolVersion={s}", .{ self.server_name, v });
            }
            if (json_helpers.getObjectField(result, "serverInfo")) |info| {
                const sname = json_helpers.getStringField(info, "name") orelse "?";
                const sver = json_helpers.getStringField(info, "version") orelse "?";
                log.info("[{s}] serverInfo: {s} v{s}", .{ self.server_name, sname, sver });
            }
        }

        // Per spec: client confirms initialization with this notification
        // before issuing any other request.
        try self.notify("notifications/initialized", empty_params);
    }

    /// tools/list, following nextCursor until empty. Caller frees with `freeTools`.
    pub fn listTools(self: *McpClient, allocator: std.mem.Allocator) ![]Tool {
        var collected: std.ArrayList(Tool) = .{};
        errdefer {
            for (collected.items) |t| t.deinit(allocator);
            collected.deinit(allocator);
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |c| allocator.free(c);

        while (true) {
            var parsed = if (cursor) |c|
                try self.requestRaw("tools/list", .{ .cursor = c })
            else
                try self.requestRaw("tools/list", empty_params);
            defer parsed.deinit();

            const result = json_helpers.getObjectField(parsed.value, "result")
                orelse return error.MalformedResponse;

            const tools_field = json_helpers.getField(result, "tools")
                orelse return error.MalformedResponse;
            if (tools_field != .array) return error.MalformedResponse;

            for (tools_field.array.items) |item| {
                const name = json_helpers.getStringField(item, "name") orelse continue;
                const desc = json_helpers.getStringField(item, "description") orelse "";
                const schema_val = json_helpers.getField(item, "inputSchema") orelse continue;
                const schema_json = try std.json.Stringify.valueAlloc(allocator, schema_val, .{});
                errdefer allocator.free(schema_json);

                const name_owned = try allocator.dupe(u8, name);
                errdefer allocator.free(name_owned);
                const desc_owned = try allocator.dupe(u8, desc);
                errdefer allocator.free(desc_owned);

                try collected.append(allocator, .{
                    .name = name_owned,
                    .description = desc_owned,
                    .input_schema_json = schema_json,
                });
            }

            const next = json_helpers.getStringField(result, "nextCursor") orelse break;
            if (cursor) |c| allocator.free(c);
            cursor = try allocator.dupe(u8, next);
        }

        return collected.toOwnedSlice(allocator);
    }

    /// tools/call. `arguments` is the model-provided JSON object for the tool's input.
    pub fn callTool(
        self: *McpClient,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments: std.json.Value,
    ) !CallResult {
        var parsed = try self.requestRaw("tools/call", .{
            .name = name,
            .arguments = arguments,
        });
        defer parsed.deinit();

        const result = json_helpers.getObjectField(parsed.value, "result")
            orelse return error.MalformedResponse;

        const is_error = blk: {
            const v = json_helpers.getField(result, "isError") orelse break :blk false;
            break :blk v == .bool and v.bool;
        };

        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(allocator);

        if (json_helpers.getField(result, "content")) |content| if (content == .array) {
            for (content.array.items) |part| {
                const t = json_helpers.getStringField(part, "type") orelse continue;
                if (out.items.len > 0) try out.append(allocator, '\n');
                if (std.mem.eql(u8, t, "text")) {
                    const txt = json_helpers.getStringField(part, "text") orelse continue;
                    try out.appendSlice(allocator, txt);
                } else {
                    const marker = try std.fmt.allocPrint(
                        allocator,
                        "[{s} content omitted]",
                        .{t},
                    );
                    defer allocator.free(marker);
                    try out.appendSlice(allocator, marker);
                }
            }
        };

        return .{
            .text = try out.toOwnedSlice(allocator),
            .is_error = is_error,
        };
    }

    // ───── low-level JSON-RPC (delegates to the transport) ────────────────

    /// Build a JSON-RPC request, hand it to the transport, and return the
    /// matching response. Caller owns the returned Parsed and must `.deinit()`.
    fn requestRaw(
        self: *McpClient,
        method: []const u8,
        params: anytype,
    ) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;

        const body = try protocol.buildRequest(self.allocator, id, method, params);
        defer self.allocator.free(body);

        return self.transport.roundtrip(self.allocator, id, body);
    }

    fn notify(self: *McpClient, method: []const u8, params: anytype) !void {
        const body = try protocol.buildNotification(self.allocator, method, params);
        defer self.allocator.free(body);
        try self.transport.send(body);
    }
};

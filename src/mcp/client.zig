//! One MCP server connection over stdio.
//!
//! Lifecycle:
//!   spawn → initialize → (listTools | callTool)* → shutdown
//!
//! Threading: requests are synchronous. The caller (the agentic loop) is
//! already on a background thread, so blocking reads on stdout are fine.
//! One side thread drains stderr into the .mcp log scope — without this,
//! a chatty server would block on a full ~64KB stderr pipe buffer.

const std = @import("std");
const protocol = @import("protocol.zig");
const json_helpers = @import("../json_helpers.zig");

const log = std.log.scoped(.mcp);

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
    child: std.process.Child,
    next_id: u64 = 1,

    stdout_buf: []u8,                   // owned; backs stdout_reader
    stdout_reader: std.fs.File.Reader,
    stderr_thread: ?std.Thread = null,

    /// Tool catalog from the most recent `tools/list`. Owned by this
    /// McpClient's allocator (independent of any per-turn arena) so it can
    /// be looked up at confirmation time to display the tool's description
    /// in the modal. Refreshed by `refreshTools()`.
    cached_tools: []Tool = &.{},

    /// Spawn the server as a subprocess. argv = command + args. Inherits the
    /// parent environment for v1 (env-var override comes with config wiring).
    /// Heap-allocates the client so its internal buffers/reader can be
    /// referenced by pointer without worrying about moves.
    pub fn spawn(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        command: []const u8,
        args: []const []const u8,
    ) !*McpClient {
        const argv = try allocator.alloc([]const u8, args.len + 1);
        defer allocator.free(argv);
        argv[0] = command;
        for (args, 0..) |a, i| argv[i + 1] = a;

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }

        const self = try allocator.create(McpClient);
        errdefer allocator.destroy(self);

        const stdout_buf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(stdout_buf);

        const name_copy = try allocator.dupe(u8, server_name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .allocator = allocator,
            .server_name = name_copy,
            .child = child,
            .stdout_buf = stdout_buf,
            .stdout_reader = undefined,
        };
        // Bind the reader to *our* (now-owned) stdout file and buffer.
        self.stdout_reader = self.child.stdout.?.reader(self.stdout_buf);

        // Stderr drainer takes its own duped name so its lifetime is
        // independent from self (we may be shutting down while it's mid-line).
        const name_for_thread = try allocator.dupe(u8, server_name);
        self.stderr_thread = try std.Thread.spawn(.{}, drainStderr, .{
            self.child.stderr.?, name_for_thread, allocator,
        });

        log.info("[{s}] spawned: {s}", .{ server_name, command });
        return self;
    }

    /// Close stdin (signals server to exit), wait for child + stderr drain.
    pub fn shutdown(self: *McpClient) void {
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch |err| {
            log.warn("[{s}] wait failed: {}", .{ self.server_name, err });
        };
        if (self.stderr_thread) |t| t.join();
        self.freeCachedTools();
        self.allocator.free(self.stdout_buf);
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

    // ───── low-level transport ────────────────────────────────────────────

    /// Send a JSON-RPC request, read until the matching response arrives.
    /// Notifications and stray responses are logged and discarded. Caller
    /// owns the returned Parsed and must `.deinit()` it.
    fn requestRaw(
        self: *McpClient,
        method: []const u8,
        params: anytype,
    ) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;

        const body = try protocol.buildRequest(self.allocator, id, method, params);
        defer self.allocator.free(body);
        log.debug("[{s}] -> {s}", .{ self.server_name, body });

        const stdin = self.child.stdin orelse return error.ServerStdinClosed;
        try stdin.writeAll(body);
        try stdin.writeAll("\n");

        const reader = &self.stdout_reader.interface;
        while (true) {
            const line = (reader.takeDelimiter('\n') catch |err| {
                log.err("[{s}] read error: {}", .{ self.server_name, err });
                return err;
            }) orelse return error.ServerClosedStream;
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            log.debug("[{s}] <- {s}", .{ self.server_name, trimmed });

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                trimmed,
                .{ .allocate = .alloc_always },
            ) catch |err| {
                log.warn("[{s}] non-JSON line ignored: {}", .{ self.server_name, err });
                continue;
            };

            const frame = protocol.frameFromValue(parsed.value);

            if (frame.id) |fid| {
                if (fid == @as(i64, @intCast(id))) {
                    if (frame.err) |e| {
                        log.err("[{s}] RPC error {d}: {s}", .{ self.server_name, e.code, e.message });
                        parsed.deinit();
                        return error.RpcError;
                    }
                    return parsed;
                }
                // Response to an id we didn't issue — shouldn't happen in
                // sync mode, drop it.
                log.warn("[{s}] unexpected response id={d} (waiting for {d})", .{ self.server_name, fid, id });
                parsed.deinit();
                continue;
            }

            // No id → server-initiated notification. v1 ignores
            // tools/list_changed etc.
            if (frame.method) |m| {
                log.info("[{s}] notification: {s}", .{ self.server_name, m });
            }
            parsed.deinit();
        }
    }

    fn notify(self: *McpClient, method: []const u8, params: anytype) !void {
        const body = try protocol.buildNotification(self.allocator, method, params);
        defer self.allocator.free(body);
        log.debug("[{s}] -> {s}", .{ self.server_name, body });
        const stdin = self.child.stdin orelse return error.ServerStdinClosed;
        try stdin.writeAll(body);
        try stdin.writeAll("\n");
    }
};

fn drainStderr(
    stderr_file: std.fs.File,
    name_owned: []u8,
    allocator: std.mem.Allocator,
) void {
    defer allocator.free(name_owned);
    var buf: [4096]u8 = undefined;
    var reader_state = stderr_file.reader(&buf);
    const reader = &reader_state.interface;
    while (true) {
        const line = reader.takeDelimiter('\n') catch break;
        const slice = line orelse break;
        const trimmed = std.mem.trimRight(u8, slice, "\r");
        if (trimmed.len == 0) continue;
        log.info("[{s} stderr] {s}", .{ name_owned, trimmed });
    }
}

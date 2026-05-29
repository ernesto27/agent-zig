//! JSON-RPC 2.0 envelope helpers for MCP.
//!
//! MCP rides on JSON-RPC 2.0. Three message kinds:
//!   - request:      { jsonrpc:"2.0", id, method, params }    (expects response)
//!   - notification: { jsonrpc:"2.0",     method, params }    (no id, no response)
//!   - response:     { jsonrpc:"2.0", id, result | error }
//!
//! This module owns *only* the envelope. Higher-level MCP method payloads
//! (initialize params, tools/call params, tools/list result …) live in
//! `client.zig` so they can be built next to their call sites.

const std = @import("std");

const log = std.log.scoped(.mcp);

/// JSON-RPC error object. Spec: code is integer, message is short string,
/// data is optional and free-form.
pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// Result of parsing one incoming JSON-RPC frame. Exactly one of `result` /
/// `err` is set when `id` is present (i.e. it's a response). When `id` is
/// null, it's an incoming notification from the server — `method` and
/// `params` will be set instead. We tolerate either shape in the same
/// parser to keep the read-loop simple.
pub const IncomingFrame = struct {
    id: ?i64 = null,
    result: ?std.json.Value = null,
    err: ?RpcError = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
};

/// Build a JSON-RPC request body. `params` is any value `std.json.Stringify`
/// can serialize (anonymous struct, std.json.Value, etc.). Caller owns the
/// returned buffer.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{});
}

/// Build a JSON-RPC notification body (no `id`, no response expected).
pub fn buildNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = method,
        .params = params,
    }, .{});
}

/// Parse one already-extracted JSON-RPC frame. The caller is responsible for
/// `parsed.deinit()` on the returned `Parsed` — the `IncomingFrame` holds
/// slices into the parsed arena.
pub fn parseFrame(
    allocator: std.mem.Allocator,
    line: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{});
}

/// Parse one JSON-RPC line and decide whether it's the response to `want_id`.
///
/// Returns the owned `Parsed` (caller must `.deinit()`) when the line is the
/// matching response. Returns `null` — meaning "keep reading" — for non-JSON
/// lines, server notifications, and responses to other ids. Returns
/// `error.RpcError` when the matching response carries a JSON-RPC error.
///
/// Shared by every transport's read path (stdio newline frames, HTTP JSON
/// bodies, HTTP SSE `data:` events) so id-matching never diverges. `name` is
/// only used for log scoping.
pub fn matchResponse(
    gpa: std.mem.Allocator,
    line: []const u8,
    want_id: u64,
    name: []const u8,
) !?std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        gpa,
        line,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        log.warn("[{s}] non-JSON line ignored: {}", .{ name, err });
        return null;
    };

    const frame = frameFromValue(parsed.value);

    if (frame.id) |fid| {
        if (fid == @as(i64, @intCast(want_id))) {
            if (frame.err) |e| {
                log.err("[{s}] RPC error {d}: {s}", .{ name, e.code, e.message });
                parsed.deinit();
                return error.RpcError;
            }
            return parsed;
        }
        // Response to an id we didn't issue — shouldn't happen in sync mode.
        log.warn("[{s}] unexpected response id={d} (waiting for {d})", .{ name, fid, want_id });
        parsed.deinit();
        return null;
    }

    // No id → server-initiated notification. v1 ignores tools/list_changed etc.
    if (frame.method) |m| log.info("[{s}] notification: {s}", .{ name, m });
    parsed.deinit();
    return null;
}

/// Project a `std.json.Value` (must be `.object`) into the structured
/// `IncomingFrame` shape. Slices point into the source value — same lifetime.
pub fn frameFromValue(v: std.json.Value) IncomingFrame {
    var f: IncomingFrame = .{};
    if (v != .object) return f;
    const obj = v.object;

    if (obj.get("id")) |id_val| {
        switch (id_val) {
            .integer => |n| f.id = n,
            .float => |x| f.id = @intFromFloat(x),
            // Some servers send string ids — we don't issue those, so ignore.
            else => {},
        }
    }
    if (obj.get("result")) |r| f.result = r;
    if (obj.get("method")) |m| {
        if (m == .string) f.method = m.string;
    }
    if (obj.get("params")) |p| f.params = p;
    if (obj.get("error")) |e| {
        if (e == .object) {
            const eo = e.object;
            const code: i64 = if (eo.get("code")) |c| switch (c) {
                .integer => |n| n,
                .float => |x| @intFromFloat(x),
                else => 0,
            } else 0;
            const msg: []const u8 = if (eo.get("message")) |m|
                (if (m == .string) m.string else "")
            else
                "";
            f.err = .{ .code = code, .message = msg, .data = eo.get("data") };
        }
    }
    return f;
}

//! MCP transport over Streamable HTTP (the transport hosted servers use:
//! Linear, GitHub, Notion, DeepWiki).
//!
//! Each JSON-RPC request is POSTed to a single endpoint URL. The server
//! answers either with a plain `application/json` body or with a
//! `text/event-stream` (SSE) whose `data:` events each carry one JSON-RPC
//! message. We read the whole response body and let `protocol.matchResponse`
//! pick out the frame whose id matches our request — identical id-matching to
//! the stdio transport.
//!
//! Session: if the server returns an `Mcp-Session-Id` header (typically on the
//! initialize response) we capture it and echo it back on every later request,
//! along with `MCP-Protocol-Version`.
//!
//! Threading: synchronous and blocking, like stdio. The agentic loop is
//! already on a background thread and a server's calls are serialized there,
//! so one `std.http.Client` per transport is safe.
//!
//! v1 limits (see plan "Deferred"): no manual redirect handling (relies on the
//! std client following <=3 redirects), no per-request timeout, static auth
//! headers only (no OAuth). Reading the body to EOF assumes the server closes
//! the POST-initiated stream after replying — which Streamable HTTP servers do.

const std = @import("std");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.mcp);

/// Cap on a single JSON response body we'll buffer (tool results can be large).
const max_body = 8 * 1024 * 1024;
/// Read buffer for SSE: an event's `data:` line must fit. Big enough for large
/// tool results; an oversized single line surfaces as StreamTooLong, not a hang.
const max_line = 1024 * 1024;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    name: []u8, // owned; log scoping
    url: []u8, // owned; `uri` points into it
    uri: std.Uri,
    headers: []std.http.Header, // owned auth headers (name + value duped)
    http_client: std.http.Client,
    session_id: ?[]u8 = null, // owned; captured from a response header
    protocol_version: []const u8 = "2025-11-25",

    /// Borrow `url` and `header_pairs` from the caller (config-lifetime
    /// `std.json.Value`) and dupe everything we keep. Heap-allocates so the
    /// http_client and buffers are addressable by pointer.
    pub fn connect(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        url: []const u8,
        header_pairs: []const std.http.Header,
    ) !*HttpTransport {
        const self = try allocator.create(HttpTransport);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, server_name);
        errdefer allocator.free(name_copy);

        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);

        const uri = try std.Uri.parse(url_copy);

        const hdrs = try allocator.alloc(std.http.Header, header_pairs.len);
        errdefer allocator.free(hdrs);
        var built: usize = 0;
        errdefer for (hdrs[0..built]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        };
        for (header_pairs, 0..) |h, i| {
            const n = try allocator.dupe(u8, h.name);
            errdefer allocator.free(n);
            const v = try allocator.dupe(u8, h.value);
            hdrs[i] = .{ .name = n, .value = v };
            built = i + 1;
        }

        self.* = .{
            .allocator = allocator,
            .name = name_copy,
            .url = url_copy,
            .uri = uri,
            .headers = hdrs,
            .http_client = .{ .allocator = allocator },
        };
        log.info("[{s}] http transport: {s}", .{ server_name, url });
        return self;
    }

    pub fn deinit(self: *HttpTransport) void {
        self.http_client.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.url);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Assemble the per-request header list into `list` (caller-owned arena).
    fn buildHeaders(self: *HttpTransport, list: *std.ArrayList(std.http.Header), gpa: std.mem.Allocator) !void {
        try list.append(gpa, .{ .name = "accept", .value = "application/json, text/event-stream" });
        if (self.session_id) |sid| {
            try list.append(gpa, .{ .name = "Mcp-Session-Id", .value = sid });
            // Protocol version is required only after initialization; gate on
            // having a session so the initialize request stays minimal.
            try list.append(gpa, .{ .name = "MCP-Protocol-Version", .value = self.protocol_version });
        }
        try list.appendSlice(gpa, self.headers);
    }

    /// POST the request body, read the response to EOF, return the matching
    /// JSON-RPC frame. Caller owns the returned Parsed.
    pub fn roundtrip(
        self: *HttpTransport,
        gpa: std.mem.Allocator,
        id: u64,
        body: []u8,
    ) !std.json.Parsed(std.json.Value) {
        var hdrs: std.ArrayList(std.http.Header) = .{};
        defer hdrs.deinit(gpa);
        try self.buildHeaders(&hdrs, gpa);

        log.debug("[{s}] -> {s}", .{ self.name, body });

        var req = try self.http_client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = hdrs.items,
            .keep_alive = false,
        });
        defer req.deinit();
        try req.sendBodyComplete(body);

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            var tb: [4096]u8 = undefined;
            const r = response.reader(&tb);
            const errbody = r.allocRemaining(gpa, @enumFromInt(4096)) catch "";
            defer if (errbody.len > 0) gpa.free(errbody);
            log.err("[{s}] HTTP {d}: {s}", .{ self.name, @intFromEnum(response.head.status), errbody });
            return error.HttpRequestFailed;
        }

        // Capture the session id BEFORE response.reader() — head pointers are
        // invalidated once the body stream is initialized.
        if (self.session_id == null) {
            var it = response.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) {
                    self.session_id = try gpa.dupe(u8, h.value);
                    log.info("[{s}] session id captured", .{self.name});
                    break;
                }
            }
        }

        const is_sse = if (response.head.content_type) |ct|
            std.mem.indexOf(u8, ct, "text/event-stream") != null
        else
            false;

        if (is_sse) {
            // Streamable-HTTP servers commonly hold the SSE connection open
            // after sending our response, so we must NOT read to EOF — we
            // stream until the matching frame arrives and return (req.deinit
            // closes the connection). Big single-line frames need a roomy read
            // buffer; allocate it on the heap.
            const line_buf = try gpa.alloc(u8, max_line);
            defer gpa.free(line_buf);
            const body_reader = response.reader(line_buf);
            return readSseStreaming(gpa, body_reader, id, self.name);
        }

        // Plain JSON response is content-length / close-delimited, so reading
        // to EOF is safe and gives us the whole body in one shot.
        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const raw = try body_reader.allocRemaining(gpa, @enumFromInt(max_body));
        defer gpa.free(raw);
        log.debug("[{s}] <- (json) {s}", .{ self.name, raw });
        return parseJsonBody(gpa, raw, id, self.name);
    }

    /// Fire-and-forget a notification: POST it, drain whatever comes back
    /// (202 Accepted, usually empty), never parse, never fail on status.
    pub fn send(self: *HttpTransport, body: []u8) !void {
        var hdrs: std.ArrayList(std.http.Header) = .{};
        defer hdrs.deinit(self.allocator);
        try self.buildHeaders(&hdrs, self.allocator);

        log.debug("[{s}] -> {s}", .{ self.name, body });

        var req = try self.http_client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = hdrs.items,
            .keep_alive = false,
        });
        defer req.deinit();
        try req.sendBodyComplete(body);

        var redirect_buf: [4096]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);
        // Don't read the body — a server may answer a notification with a
        // held-open SSE stream, and we'd hang. keep_alive=false means
        // req.deinit() closes the socket regardless of unread bytes.
        if (response.head.status != .ok and response.head.status != .accepted) {
            log.warn("[{s}] notification HTTP {d}", .{ self.name, @intFromEnum(response.head.status) });
        }
    }
};

/// Parse a single JSON response body. Must be the matching frame.
fn parseJsonBody(
    gpa: std.mem.Allocator,
    buf: []const u8,
    id: u64,
    name: []const u8,
) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, buf, " \t\r\n");
    if (try protocol.matchResponse(gpa, trimmed, id, name)) |parsed| return parsed;
    return error.MalformedResponse;
}

/// Stream an SSE response: accumulate `data:` payloads and, at each event
/// boundary (blank line), try to match the JSON-RPC frame. Returns the FIRST
/// match — without reading to EOF, since the server may keep the stream open
/// after replying. `event:`/`id:`/`retry:` fields and comments are ignored.
fn readSseStreaming(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    id: u64,
    name: []const u8,
) !std.json.Parsed(std.json.Value) {
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(gpa);

    while (true) {
        const raw = (reader.takeDelimiter('\n') catch |err| {
            log.err("[{s}] sse read error: {}", .{ name, err });
            return err;
        }) orelse {
            // EOF: flush any trailing event that lacked a terminating blank line.
            if (data.items.len > 0) {
                if (try protocol.matchResponse(gpa, data.items, id, name)) |parsed| return parsed;
            }
            return error.ServerClosedStream;
        };
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) {
            if (data.items.len > 0) {
                if (try protocol.matchResponse(gpa, data.items, id, name)) |parsed| return parsed;
                data.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            const v = std.mem.trimLeft(u8, line["data:".len..], " ");
            if (data.items.len > 0) try data.append(gpa, '\n');
            try data.appendSlice(gpa, v);
        }
        // event:/id:/retry:/":" comment lines are ignored
    }
}

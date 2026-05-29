//! MCP transport over Streamable HTTP (the transport hosted servers use:
//! Linear, GitHub, Notion, DeepWiki).
//!
//! Why this doesn't use std.http.Client: that client connects via
//! std.net.tcpConnectToHost, which tries resolved addresses in order with no
//! Happy-Eyeballs and no per-address timeout. On a host that publishes IPv6
//! (AAAA) records while the local IPv6 route is blackholed (common behind
//! split-tunnel VPNs), it stalls forever on the dead IPv6 address and never
//! falls back to IPv4. std.http.Client exposes no address-family/timeout knob
//! and its connection internals are private, so we dial ourselves —
//! IPv4-first — and run TLS via std.crypto.tls directly.
//!
//! Each JSON-RPC request is a fresh `Connection: close` POST. Because the
//! server closes after replying, we read the whole response to EOF and parse
//! it in memory: split head/body, de-chunk, then pick out the JSON-RPC frame
//! whose id matches (SSE `data:` events or a plain JSON body).
//!
//! Session: an `Mcp-Session-Id` response header (usually on initialize) is
//! captured and echoed back on later requests with `MCP-Protocol-Version`.
//!
//! Threading: synchronous/blocking, one connection per request. The agentic
//! loop and the per-server loader thread are already off the UI thread.
//!
//! v1 limits: static auth headers only (no OAuth); a dead *IPv4* address still
//! blocks on the OS connect timeout (the loader-thread isolation keeps that
//! from affecting other servers).

const std = @import("std");
const protocol = @import("protocol.zig");

const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.mcp);

/// Cap on a single response we'll buffer (tool results can be large).
const max_body = 8 * 1024 * 1024;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    name: []u8, // owned; log scoping
    url: []u8, // owned (kept for logging)
    https: bool,
    host: []u8, // owned
    port: u16,
    path: []u8, // owned (path + optional query)
    headers: []std.http.Header, // owned auth headers (name + value duped)
    ca_bundle: Certificate.Bundle,
    session_id: ?[]u8 = null, // owned; captured from a response header
    protocol_version: []const u8 = "2025-11-25",

    pub fn connect(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        url: []const u8,
        header_pairs: []const std.http.Header,
    ) !*HttpTransport {
        const parts = try parseUrl(url);

        const self = try allocator.create(HttpTransport);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, server_name);
        errdefer allocator.free(name_copy);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        const host_copy = try allocator.dupe(u8, parts.host);
        errdefer allocator.free(host_copy);
        const path_copy = try allocator.dupe(u8, parts.path);
        errdefer allocator.free(path_copy);

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

        var bundle: Certificate.Bundle = .{};
        if (parts.https) {
            bundle.rescan(allocator) catch |err| {
                log.err("[{s}] CA bundle load failed: {}", .{ server_name, err });
                return err;
            };
        }
        errdefer bundle.deinit(allocator);

        self.* = .{
            .allocator = allocator,
            .name = name_copy,
            .url = url_copy,
            .https = parts.https,
            .host = host_copy,
            .port = parts.port,
            .path = path_copy,
            .headers = hdrs,
            .ca_bundle = bundle,
        };
        log.info("[{s}] http transport: {s} (host={s} port={d})", .{ server_name, url, host_copy, parts.port });
        return self;
    }

    pub fn deinit(self: *HttpTransport) void {
        self.ca_bundle.deinit(self.allocator);
        if (self.session_id) |sid| self.allocator.free(sid);
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.path);
        self.allocator.free(self.host);
        self.allocator.free(self.url);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn roundtrip(
        self: *HttpTransport,
        gpa: std.mem.Allocator,
        id: u64,
        body: []u8,
    ) !std.json.Parsed(std.json.Value) {
        const raw = try self.doRequest(gpa, body);
        defer gpa.free(raw);

        const split = splitHeadBody(raw) orelse return error.MalformedResponse;
        const status = statusFromHead(split.head) orelse return error.MalformedResponse;
        if (status != 200) {
            log.err("[{s}] HTTP {d}: {s}", .{ self.name, status, split.body });
            return error.HttpRequestFailed;
        }

        if (self.session_id == null) {
            if (headerValue(split.head, "mcp-session-id")) |sid| {
                self.session_id = try gpa.dupe(u8, sid);
                log.info("[{s}] session id captured", .{self.name});
            }
        }

        const chunked = if (headerValue(split.head, "transfer-encoding")) |te|
            std.ascii.indexOfIgnoreCase(te, "chunked") != null
        else
            false;
        const decoded = if (chunked) try dechunk(gpa, split.body) else null;
        defer if (decoded) |d| gpa.free(d);
        const payload = decoded orelse split.body;

        const is_sse = if (headerValue(split.head, "content-type")) |ct|
            std.ascii.indexOfIgnoreCase(ct, "text/event-stream") != null
        else
            false;

        log.debug("[{s}] <- ({s}) {s}", .{ self.name, if (is_sse) "sse" else "json", payload });

        if (is_sse) return parseSseBuffer(gpa, payload, id, self.name);
        return parseJsonBody(gpa, payload, id, self.name);
    }

    /// Fire-and-forget a notification: deliver the POST, ignore the reply.
    pub fn send(self: *HttpTransport, body: []u8) !void {
        const raw = self.doRequest(self.allocator, body) catch |err| {
            log.warn("[{s}] notification send failed: {}", .{ self.name, err });
            return;
        };
        self.allocator.free(raw);
    }

    /// Open a fresh connection, send one request, read the entire response to
    /// EOF (`Connection: close` guarantees the server closes after replying),
    /// and return the owned raw bytes (head + body). Caller frees.
    fn doRequest(self: *HttpTransport, gpa: std.mem.Allocator, body: []u8) ![]u8 {
        var stream = try dialPreferIpv4(gpa, self.host, self.port);
        defer stream.close();

        const req = try self.buildRequest(gpa, body);
        defer gpa.free(req);

        if (!self.https) {
            var rbuf: [64 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var sr = stream.reader(&rbuf);
            var sw = stream.writer(&wbuf);
            try sw.interface.writeAll(req);
            try sw.interface.flush();
            return sr.interface().allocRemaining(gpa, @enumFromInt(max_body));
        }

        // HTTPS buffer sizing. The socket reader AND socket writer must each
        // hold a full TLS record — TLS flush does writableSliceGreedy(min) on
        // the socket writer, so both must be >= min_buffer_len (~16 KB).
        // `tls_write_buffer` (the .write_buffer option) is the app-side
        // plaintext staging buffer and can be smaller.
        const min = tls.Client.min_buffer_len;
        const socket_read_buffer = try gpa.alloc(u8, min);
        defer gpa.free(socket_read_buffer);
        const socket_write_buffer = try gpa.alloc(u8, min);
        defer gpa.free(socket_write_buffer);
        const tls_read_buffer = try gpa.alloc(u8, min + 16 * 1024);
        defer gpa.free(tls_read_buffer);
        const tls_write_buffer = try gpa.alloc(u8, 16 * 1024);
        defer gpa.free(tls_write_buffer);

        var sr = stream.reader(socket_read_buffer);
        var sw = stream.writer(socket_write_buffer);

        var client = tls.Client.init(sr.interface(), &sw.interface, .{
            .host = .{ .explicit = self.host },
            .ca = .{ .bundle = self.ca_bundle },
            .read_buffer = tls_read_buffer,
            .write_buffer = tls_write_buffer,
            // HTTP detects truncation via Content-Length / chunk framing, so a
            // server EOF without close_notify is fine (and expected here).
            .allow_truncation_attacks = true,
        }) catch |err| {
            log.err("[{s}] TLS handshake failed: {}", .{ self.name, err });
            return error.TlsInitializationFailed;
        };

        try client.writer.writeAll(req);
        try client.writer.flush(); // encrypt into the socket writer
        try sw.interface.flush(); // push ciphertext to the socket

        return client.reader.allocRemaining(gpa, @enumFromInt(max_body));
    }

    /// Serialize the full HTTP/1.1 request (head + body) into one owned buffer.
    fn buildRequest(self: *HttpTransport, gpa: std.mem.Allocator, body: []u8) ![]u8 {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(gpa);
        const w = out.writer(gpa);
        try w.print("POST {s} HTTP/1.1\r\n", .{self.path});
        try w.print("Host: {s}\r\n", .{self.host});
        try w.writeAll("User-Agent: zigent/0.0.0\r\n");
        try w.writeAll("Accept: application/json, text/event-stream\r\n");
        try w.writeAll("Content-Type: application/json\r\n");
        try w.print("Content-Length: {d}\r\n", .{body.len});
        try w.writeAll("Connection: close\r\n");
        if (self.session_id) |sid| {
            try w.print("Mcp-Session-Id: {s}\r\n", .{sid});
            try w.print("MCP-Protocol-Version: {s}\r\n", .{self.protocol_version});
        }
        for (self.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        try w.writeAll(body);
        return out.toOwnedSlice(gpa);
    }
};

// ───── URL + HTTP parsing helpers (all in-memory) ──────────────────────────

const UrlParts = struct { https: bool, host: []const u8, port: u16, path: []const u8 };

/// Minimal URL split: scheme://host[:port][/path]. Slices borrow from `url`.
fn parseUrl(url: []const u8) !UrlParts {
    var https = true;
    var rest = url;
    if (std.mem.startsWith(u8, url, "https://")) {
        rest = url["https://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        https = false;
        rest = url["http://".len..];
    } else return error.UnsupportedUrlScheme;

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |s| rest[0..s] else rest;
    const path = if (slash) |s| rest[s..] else "/";
    if (authority.len == 0) return error.MalformedUrl;

    var host = authority;
    var port: u16 = if (https) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.MalformedUrl;
    }
    return .{ .https = https, .host = host, .port = port, .path = path };
}

/// Connect to `host:port`, trying IPv4 addresses before IPv6 — the whole point
/// of this module: std's connect prefers whatever DNS returns first, which
/// hangs when an unreachable IPv6 address sorts ahead of a working IPv4 one.
fn dialPreferIpv4(gpa: std.mem.Allocator, host: []const u8, port: u16) !net.Stream {
    const list = try net.getAddressList(gpa, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;

    var last_err: anyerror = error.ConnectionRefused;
    for ([_]bool{ true, false }) |want_v4| {
        for (list.addrs) |addr| {
            const is_v4 = addr.any.family == posix.AF.INET;
            if (is_v4 != want_v4) continue;
            return net.tcpConnectToAddress(addr) catch |err| {
                last_err = err;
                continue;
            };
        }
    }
    return last_err;
}

const HeadBody = struct { head: []const u8, body: []const u8 };

fn splitHeadBody(raw: []const u8) ?HeadBody {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    return .{ .head = raw[0 .. sep + 4], .body = raw[sep + 4 ..] };
}

fn statusFromHead(head: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];
    // "HTTP/1.1 200 OK" → the token after the first space.
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const after = std.mem.trimLeft(u8, line[sp + 1 ..], " ");
    const code_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    return std.fmt.parseInt(u16, after[0..code_end], 10) catch null;
}

/// Case-insensitive lookup of a single header value in raw head bytes.
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // skip the status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

/// Decode HTTP chunked transfer-encoding into an owned buffer.
fn dechunk(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse break;
        var size_line = body[i..nl];
        size_line = std.mem.trimRight(u8, size_line, "\r");
        // A chunk-size line may carry ";ext" extensions — ignore them.
        if (std.mem.indexOfScalar(u8, size_line, ';')) |s| size_line = size_line[0..s];
        size_line = std.mem.trim(u8, size_line, " ");
        const size = std.fmt.parseInt(usize, size_line, 16) catch break;
        i = nl + 1;
        if (size == 0) break;
        if (i + size > body.len) {
            try out.appendSlice(gpa, body[i..]); // truncated; salvage what we have
            break;
        }
        try out.appendSlice(gpa, body[i .. i + size]);
        i += size;
        // Skip the CRLF that terminates the chunk data.
        if (i < body.len and body[i] == '\r') i += 1;
        if (i < body.len and body[i] == '\n') i += 1;
    }
    return out.toOwnedSlice(gpa);
}

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

/// Parse an SSE body in memory: accumulate `data:` payloads and, at each event
/// boundary (blank line), try to match the JSON-RPC frame. Returns the first
/// match. `event:`/`id:`/`retry:` fields and comments are ignored.
fn parseSseBuffer(
    gpa: std.mem.Allocator,
    buf: []const u8,
    id: u64,
    name: []const u8,
) !std.json.Parsed(std.json.Value) {
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(gpa);

    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |raw| {
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
    if (data.items.len > 0) {
        if (try protocol.matchResponse(gpa, data.items, id, name)) |parsed| return parsed;
    }
    return error.ServerClosedStream;
}

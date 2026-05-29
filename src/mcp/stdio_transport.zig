//! MCP transport over a child process's stdio (newline-delimited JSON-RPC).
//!
//! This is the original (and default) transport: the server runs as a
//! subprocess and we frame JSON-RPC messages one-per-line on its stdin/stdout.
//!
//! Threading: requests are synchronous. The caller (the agentic loop) is
//! already on a background thread, so blocking reads on stdout are fine. One
//! side thread drains stderr into the .mcp log scope — without this, a chatty
//! server would block on a full ~64KB stderr pipe buffer.

const std = @import("std");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.mcp);

pub const StdioTransport = struct {
    allocator: std.mem.Allocator,
    name: []u8, // owned; used for log scoping
    child: std.process.Child,

    stdout_buf: []u8, // owned; backs stdout_reader
    stdout_reader: std.fs.File.Reader,
    stderr_thread: ?std.Thread = null,

    /// Spawn the server as a subprocess. argv = command + args. Inherits the
    /// parent environment for v1. Heap-allocates so its internal buffers and
    /// reader can be referenced by pointer without worrying about moves.
    pub fn spawn(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        command: []const u8,
        args: []const []const u8,
    ) !*StdioTransport {
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

        const self = try allocator.create(StdioTransport);
        errdefer allocator.destroy(self);

        const stdout_buf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(stdout_buf);

        const name_copy = try allocator.dupe(u8, server_name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .allocator = allocator,
            .name = name_copy,
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
    pub fn deinit(self: *StdioTransport) void {
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }
        _ = self.child.wait() catch |err| {
            log.warn("[{s}] wait failed: {}", .{ self.name, err });
        };
        if (self.stderr_thread) |t| t.join();
        self.allocator.free(self.stdout_buf);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Write the JSON-RPC request body, then read newline frames until the
    /// response with `id` arrives. Caller owns the returned Parsed.
    pub fn roundtrip(
        self: *StdioTransport,
        gpa: std.mem.Allocator,
        id: u64,
        body: []u8,
    ) !std.json.Parsed(std.json.Value) {
        log.debug("[{s}] -> {s}", .{ self.name, body });
        const stdin = self.child.stdin orelse return error.ServerStdinClosed;
        try stdin.writeAll(body);
        try stdin.writeAll("\n");

        const reader = &self.stdout_reader.interface;
        while (true) {
            const line = (reader.takeDelimiter('\n') catch |err| {
                log.err("[{s}] read error: {}", .{ self.name, err });
                return err;
            }) orelse return error.ServerClosedStream;
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            log.debug("[{s}] <- {s}", .{ self.name, trimmed });

            if (try protocol.matchResponse(gpa, trimmed, id, self.name)) |parsed| {
                return parsed;
            }
        }
    }

    /// Fire-and-forget a notification body (no response expected).
    pub fn send(self: *StdioTransport, body: []u8) !void {
        log.debug("[{s}] -> {s}", .{ self.name, body });
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

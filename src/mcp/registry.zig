//! Holds N McpClients and routes by name prefix.
//!
//! Tools are exposed to the LLM as `mcp__<server>__<tool>`. When a tool_use
//! comes back with that prefix, routeCall splits it, looks up the client,
//! and forwards via JSON-RPC tools/call. Names without the prefix return
//! null so the caller falls through to the built-in dispatcher.
//!
//! Each configured server connects on its OWN loader thread, so a slow or
//! hanging server (e.g. an unreachable hosted HTTP endpoint) never blocks the
//! others — stdio servers like context7 come online independently of a stuck
//! HTTP one. A mutex guards `clients`/`states`; every reader (collectTools,
//! routeCall, the /mcp picker) locks it so it never observes a half-inserted
//! entry while a loader thread is mid-mutation.

const std = @import("std");
const client_mod = @import("client.zig");
const message = @import("../llm/message.zig");
const config = @import("../config.zig");

const McpClient = client_mod.McpClient;

const log = std.log.scoped(.mcp);

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

/// Per-server lifecycle, surfaced to the /mcp picker.
pub const ServerState = enum { loading, connected, failed };

/// Heap-allocated context handed to each loader thread. Freed by the thread.
const LoadCtx = struct {
    reg: *McpRegistry,
    name: []const u8, // borrowed from the config map keys (outlive the registry)
    cfg: config.McpServerConfig, // slices borrowed from the config arena
};

pub const McpRegistry = struct {
    allocator: std.mem.Allocator,
    /// Guards `clients` and `states`. Held only briefly around map access —
    /// never across a spawn/connect/RPC call.
    mutex: std.Thread.Mutex = .{},
    /// Connected servers, by name. Populated incrementally as each loader
    /// thread finishes. Keys owned by this registry's allocator.
    clients: std.StringHashMapUnmanaged(*McpClient) = .{},
    /// Lifecycle state for every configured server (loading/connected/failed).
    /// Keys owned by this registry's allocator.
    states: std.StringHashMapUnmanaged(ServerState) = .{},
    /// One loader thread per configured server; joined in shutdownAll.
    load_threads: std.ArrayList(std.Thread) = .{},

    pub fn init(allocator: std.mem.Allocator) McpRegistry {
        return .{ .allocator = allocator };
    }

    /// Lifecycle state for `name`; `.loading` if not yet recorded.
    pub fn serverState(self: *McpRegistry, name: []const u8) ServerState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.states.get(name) orelse .loading;
    }

    /// Connected client for `name`, or null. Locks so it never races a loader
    /// mid-insert. The returned pointer is stable for the life of the process.
    pub fn clientFor(self: *McpRegistry, name: []const u8) ?*McpClient {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clients.get(name);
    }

    fn setState(self: *McpRegistry, name: []const u8, state: ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.states.getPtr(name)) |s| {
            s.* = state;
        } else {
            const key = self.allocator.dupe(u8, name) catch return;
            self.states.put(self.allocator, key, state) catch self.allocator.free(key);
        }
    }

    /// Look up a tool's description from the cached catalog, used by the
    /// confirmation modal. Splits a prefixed `mcp__<server>__<tool>` name
    /// internally so callers pass the same string the LLM emitted.
    pub fn findDescriptionForPrefixed(self: *McpRegistry, prefixed_name: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, prefixed_name, "mcp__")) return null;
        const rest = prefixed_name[5..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse return null;
        const server = rest[0..sep];
        const tool = rest[sep + 2 ..];
        const c = self.clientFor(server) orelse return null;
        return c.findToolDescription(tool);
    }

    /// Spawn one loader thread per configured server and return. Cheap and
    /// non-blocking: the actual connect/initialize (which can be slow or hang
    /// for hosted HTTP servers) happens on the per-server threads, so no single
    /// server can stall the others. Safe to call from `App.loadMcpServers`'s
    /// background thread.
    pub fn loadFromConfig(self: *McpRegistry, mcp_servers: config.McpServers) !void {
        var it = mcp_servers.map.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const cfg = entry.value_ptr.*;

            // Pre-seed lifecycle state so the picker shows "loading…" right away.
            const key = self.allocator.dupe(u8, name) catch continue;
            self.mutex.lock();
            const put_ok = if (self.states.put(self.allocator, key, .loading)) |_| true else |_| false;
            self.mutex.unlock();
            if (!put_ok) {
                self.allocator.free(key);
                continue;
            }

            const ctx = self.allocator.create(LoadCtx) catch continue;
            ctx.* = .{ .reg = self, .name = name, .cfg = cfg };
            const t = std.Thread.spawn(.{}, loadOne, .{ctx}) catch |err| {
                log.err("mcpServers.{s}: loader spawn failed: {}", .{ name, err });
                self.allocator.destroy(ctx);
                self.setState(name, .failed);
                continue;
            };
            self.load_threads.append(self.allocator, t) catch t.detach();
        }
    }

    pub fn shutdownAll(self: *McpRegistry) void {
        // Join loaders first so none touches the maps after we free them. A
        // loader stuck in a hung connect blocks here — same exit behavior as
        // before, but at runtime it never blocked the other servers.
        for (self.load_threads.items) |t| t.join();
        self.load_threads.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        var cit = self.clients.iterator();
        while (cit.next()) |entry| {
            entry.value_ptr.*.shutdown();
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit(self.allocator);

        var sit = self.states.iterator();
        while (sit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.states.deinit(self.allocator);
    }

    /// Append every connected server's tool catalog (refreshed live each call)
    /// to the model-facing definitions. Names are prefixed
    /// `mcp__<server>__<tool>`. `arena_alloc` is expected to be a per-turn
    /// arena. Servers still loading or failed are simply absent this turn.
    pub fn collectTools(
        self: *McpRegistry,
        arena_alloc: std.mem.Allocator,
    ) ![]const message.ToolDefinition {
        // Snapshot connected (name, client) pairs under the lock, then do the
        // network refresh + def building WITHOUT holding it (refreshTools does
        // a JSON-RPC round-trip).
        const Pair = struct { name: []const u8, client: *McpClient };
        var pairs: std.ArrayList(Pair) = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.clients.iterator();
            while (it.next()) |entry| {
                pairs.append(arena_alloc, .{
                    .name = entry.key_ptr.*,
                    .client = entry.value_ptr.*,
                }) catch continue;
            }
        }

        var defs: std.ArrayList(message.ToolDefinition) = .{};

        for (pairs.items) |p| {
            const server_name = p.name;
            const c = p.client;

            c.refreshTools() catch |err| {
                log.err("mcpServers.{s}: tools/list failed: {}", .{ server_name, err });
                continue;
            };
            const tools = c.cached_tools;

            for (tools) |t| {
                const prefixed_name = std.fmt.allocPrint(
                    arena_alloc,
                    "mcp__{s}__{s}",
                    .{ server_name, t.name },
                ) catch continue;

                const schema = std.json.parseFromSliceLeaky(
                    std.json.Value,
                    arena_alloc,
                    t.input_schema_json,
                    .{},
                ) catch |err| {
                    log.warn("mcpServers.{s}.{s}: schema parse failed: {}", .{ server_name, t.name, err });
                    continue;
                };

                const properties: std.json.Value = blk: {
                    if (schema != .object) break :blk .null;
                    break :blk schema.object.get("properties") orelse .null;
                };

                var required_list: std.ArrayList([]const u8) = .{};
                if (schema == .object) {
                    if (schema.object.get("required")) |r| if (r == .array) {
                        for (r.array.items) |item| {
                            if (item == .string) {
                                required_list.append(arena_alloc, item.string) catch {};
                            }
                        }
                    };
                }

                defs.append(arena_alloc, .{
                    .name = prefixed_name,
                    .description = t.description,
                    .input_schema = .{
                        .type = "object",
                        .properties = properties,
                        .required = required_list.items,
                    },
                }) catch continue;
            }
        }

        return defs.toOwnedSlice(arena_alloc);
    }

    /// If `tool_name` starts with `mcp__`, dispatch to the matching server.
    /// Returns null when the name belongs to a built-in tool, letting the
    /// existing dispatcher handle it. All RPC errors are surfaced as
    /// `is_error = true` so the model sees them and can self-correct.
    /// `result.content` is allocated from `allocator` (caller owns).
    pub fn routeCall(
        self: *McpRegistry,
        allocator: std.mem.Allocator,
        tool_name: []const u8,
        input: std.json.Value,
    ) ?ToolResult {
        if (!std.mem.startsWith(u8, tool_name, "mcp__")) return null;
        const rest = tool_name[5..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse {
            const msg = std.fmt.allocPrint(allocator, "Malformed MCP tool name: {s}", .{tool_name}) catch return .{ .content = "Malformed MCP tool name", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        const server_name = rest[0..sep];
        const inner_name = rest[sep + 2 ..];

        const c = self.clientFor(server_name) orelse {
            const reason = switch (self.serverState(server_name)) {
                .loading => "is still connecting; retry shortly",
                .failed => "failed to connect",
                .connected => "is unavailable",
            };
            const msg = std.fmt.allocPrint(allocator, "MCP server '{s}' {s}.", .{ server_name, reason }) catch return .{ .content = "MCP server unavailable", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        const call_result = c.callTool(allocator, inner_name, input) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "MCP call failed ({s}.{s}): {}", .{ server_name, inner_name, err }) catch return .{ .content = "MCP call failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        return .{ .content = call_result.text, .is_error = call_result.is_error };
    }
};

/// Per-server loader thread: connect → initialize → prime tools → publish.
/// Any failure flips the server to `.failed` and never affects the others.
fn loadOne(ctx: *LoadCtx) void {
    const self = ctx.reg;
    const name = ctx.name;
    const cfg = ctx.cfg;
    defer self.allocator.destroy(ctx);

    const client = (connectClient(self.allocator, name, cfg) catch |err| {
        log.err("mcpServers.{s}: connect failed: {}", .{ name, err });
        self.setState(name, .failed);
        return;
    }) orelse {
        self.setState(name, .failed);
        return;
    };

    client.initialize() catch |err| {
        log.err("mcpServers.{s}: initialize failed: {}", .{ name, err });
        client.shutdown();
        self.setState(name, .failed);
        return;
    };

    // Prime the cached tool catalog so /mcp and the confirmation modal can
    // render names/descriptions before the first LLM turn refreshes it.
    if (client.refreshTools()) {
        log.info("mcpServers.{s}: {d} tool(s)", .{ name, client.cached_tools.len });
    } else |err| {
        log.warn("mcpServers.{s}: initial tools/list failed: {}", .{ name, err });
    }

    const key = self.allocator.dupe(u8, name) catch {
        client.shutdown();
        self.setState(name, .failed);
        return;
    };
    self.mutex.lock();
    self.clients.put(self.allocator, key, client) catch {
        self.allocator.free(key);
        self.mutex.unlock();
        client.shutdown();
        self.setState(name, .failed);
        return;
    };
    self.mutex.unlock();

    self.setState(name, .connected);
    log.info("mcpServers.{s}: ready", .{name});
}

/// Build the right transport from a server's config entry. Returns null (not an
/// error) when the entry has neither `command` (stdio) nor `url` (http).
fn connectClient(
    allocator: std.mem.Allocator,
    name: []const u8,
    cfg: config.McpServerConfig,
) !?*McpClient {
    if (cfg.command.len > 0) {
        return try McpClient.spawnStdio(allocator, name, cfg.command, cfg.args);
    } else if (cfg.url.len > 0) {
        const headers = try buildHttpHeaders(allocator, cfg.headers);
        defer freeHttpHeaders(allocator, headers);
        return try McpClient.connectHttp(allocator, name, cfg.url, headers);
    }
    log.warn("mcpServers.{s}: needs 'command' or 'url', skipping", .{name});
    return null;
}

fn buildHttpHeaders(
    allocator: std.mem.Allocator,
    header_map: config.HttpHeaders,
) ![]std.http.Header {
    const count = header_map.map.count();
    if (count == 0) return &.{};

    const headers = try allocator.alloc(std.http.Header, count);
    errdefer allocator.free(headers);

    var built: usize = 0;
    errdefer for (headers[0..built]) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    };

    var it = header_map.map.iterator();
    while (it.next()) |entry| {
        headers[built] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.*),
        };
        built += 1;
    }

    return headers;
}

fn freeHttpHeaders(allocator: std.mem.Allocator, headers: []std.http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

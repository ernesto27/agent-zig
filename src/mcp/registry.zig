//! Holds N McpClients and routes by name prefix.
//!
//! Tools are exposed to the LLM as `mcp__<server>__<tool>`. When a tool_use
//! comes back with that prefix, routeCall splits it, looks up the client,
//! and forwards via JSON-RPC tools/call. Names without the prefix return
//! null so the caller falls through to the built-in dispatcher.

const std = @import("std");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const message = @import("../llm/message.zig");
const json_helpers = @import("../json_helpers.zig");

const McpClient = client_mod.McpClient;

const log = std.log.scoped(.mcp);

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub const McpRegistry = struct {
    allocator: std.mem.Allocator,
    clients: std.StringHashMapUnmanaged(*McpClient) = .{},
    /// Set to true once `loadFromConfig` returns. Until then, the clients
    /// map may be mid-mutation by the loader thread — readers (collectTools,
    /// routeCall, /mcp) MUST consult `isReady()` before touching `clients`.
    ready: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(allocator: std.mem.Allocator) McpRegistry {
        return .{ .allocator = allocator };
    }

    pub fn isReady(self: *const McpRegistry) bool {
        return self.ready.load(.acquire);
    }

    /// Look up a tool's description from the cached catalog, used by the
    /// confirmation modal. Splits a prefixed `mcp__<server>__<tool>` name
    /// internally so callers pass the same string the LLM emitted.
    pub fn findDescriptionForPrefixed(self: *const McpRegistry, prefixed_name: []const u8) ?[]const u8 {
        if (!self.isReady()) return null;
        if (!std.mem.startsWith(u8, prefixed_name, "mcp__")) return null;
        const rest = prefixed_name[5..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse return null;
        const server = rest[0..sep];
        const tool = rest[sep + 2 ..];
        const c = self.clients.get(server) orelse return null;
        return c.findToolDescription(tool);
    }

    /// Spawn each configured server. Servers that fail to spawn or
    /// initialize are logged and skipped — failures do not block other
    /// servers. Sets `ready=true` on return.
    ///
    /// IMPORTANT: this call is BLOCKING. First-run `npx`/`uvx` invocations
    /// download server packages; that can take 10-30 seconds. Run this on
    /// a background thread (see `App.loadMcpServers`) so the TUI is not
    /// frozen during startup.
    pub fn loadFromConfig(self: *McpRegistry, mcp_servers: std.json.Value) !void {
        defer self.ready.store(true, .release);
        if (mcp_servers != .object) return;
        var it = mcp_servers.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const cfg = entry.value_ptr.*;

            const command = json_helpers.getStringField(cfg, "command") orelse {
                log.warn("mcpServers.{s}: missing 'command', skipping", .{name});
                continue;
            };

            // Collect args (optional, empty if missing).
            var args_list: std.ArrayList([]const u8) = .{};
            defer args_list.deinit(self.allocator);
            if (json_helpers.getField(cfg, "args")) |a| if (a == .array) {
                for (a.array.items) |item| {
                    if (item == .string) try args_list.append(self.allocator, item.string);
                }
            };

            const c = McpClient.spawn(self.allocator, name, command, args_list.items) catch |err| {
                log.err("mcpServers.{s}: spawn failed: {}", .{ name, err });
                continue;
            };
            c.initialize() catch |err| {
                log.err("mcpServers.{s}: initialize failed: {}", .{ name, err });
                c.shutdown();
                continue;
            };

            // Prime the cached tool catalog so /mcp and the confirmation
            // modal can render names/descriptions before the first LLM turn
            // refreshes it via collectTools.
            if (c.refreshTools()) {
                log.info("mcpServers.{s}: {d} tool(s)", .{ name, c.cached_tools.len });
            } else |err| {
                log.warn("mcpServers.{s}: initial tools/list failed: {}", .{ name, err });
            }

            const name_owned = self.allocator.dupe(u8, name) catch {
                c.shutdown();
                continue;
            };
            self.clients.put(self.allocator, name_owned, c) catch {
                self.allocator.free(name_owned);
                c.shutdown();
                continue;
            };
            log.info("mcpServers.{s}: ready", .{name});
        }
    }

    pub fn shutdownAll(self: *McpRegistry) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.shutdown();
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit(self.allocator);
    }

    /// Append every server's tool catalog (refreshed live each call) to the
    /// model-facing definitions. Names are prefixed `mcp__<server>__<tool>`.
    /// `arena_alloc` is expected to be a per-turn arena — all allocations
    /// (Tool names, schema parses, prefixed strings) outlive only the turn.
    pub fn collectTools(
        self: *McpRegistry,
        arena_alloc: std.mem.Allocator,
    ) ![]const message.ToolDefinition {
        // Loader thread may still be mutating `clients` — skip cleanly until
        // it publishes ready=true. Caller treats empty as "no MCP this turn".
        if (!self.isReady()) return &[_]message.ToolDefinition{};

        var defs: std.ArrayList(message.ToolDefinition) = .{};

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const server_name = entry.key_ptr.*;
            const c = entry.value_ptr.*;

            // Refresh the client-owned cache (kept across turns for the
            // confirmation modal's description lookup) and then iterate it
            // to build the per-turn ToolDefinitions in the arena.
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

                // Re-parse the schema in the arena so its json.Value can be
                // embedded in ToolDefinition (lifetime = arena).
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

                // Extract required[] into []const []const u8 (arena-owned).
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
        if (!self.isReady()) {
            const msg = std.fmt.allocPrint(allocator, "MCP servers are still loading; retry shortly.", .{}) catch return .{ .content = "MCP loading", .is_error = true };
            return .{ .content = msg, .is_error = true };
        }
        const rest = tool_name[5..];
        const sep = std.mem.indexOf(u8, rest, "__") orelse {
            const msg = std.fmt.allocPrint(allocator, "Malformed MCP tool name: {s}", .{tool_name}) catch return .{ .content = "Malformed MCP tool name", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        const server_name = rest[0..sep];
        const inner_name = rest[sep + 2 ..];

        const c = self.clients.get(server_name) orelse {
            const msg = std.fmt.allocPrint(allocator, "Unknown MCP server: {s}", .{server_name}) catch return .{ .content = "Unknown MCP server", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        const call_result = c.callTool(allocator, inner_name, input) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "MCP call failed ({s}.{s}): {}", .{ server_name, inner_name, err }) catch return .{ .content = "MCP call failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        // call_result.text was allocated from `allocator` by callTool — we
        // hand ownership to the caller via ToolResult.
        return .{ .content = call_result.text, .is_error = call_result.is_error };
    }
};

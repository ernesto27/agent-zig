const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = @import("modal_list.zig");

pub const Phase = enum { servers, tools };

const status_connected_fg: vaxis.Color = .{ .rgb = .{ 0x60, 0xCC, 0x60 } };
const status_loading_fg: vaxis.Color = .{ .rgb = .{ 0xFF, 0xC0, 0x40 } };
const status_failed_fg: vaxis.Color = .{ .rgb = .{ 0xFF, 0x60, 0x60 } };

const MAX_SERVERS = 32;
const COUNT_TEXT_CAP = 16;

pub const McpPicker = struct {
    active: bool = false,
    phase: Phase = .servers,
    selected: usize = 0,
    server_names: std.ArrayList([]const u8) = .{},
    entered_server: ?[]const u8 = null,
    mcp_registry: ?*agent.mcp.registry.McpRegistry = null,
    mcp_config: std.json.Value = .null,
    count_text_buf: [MAX_SERVERS][COUNT_TEXT_CAP]u8 = undefined,
    title_buf: [64]u8 = undefined,

    pub fn init() McpPicker {
        return .{};
    }

    pub fn deinit(self: *McpPicker, alloc: std.mem.Allocator) void {
        self.server_names.deinit(alloc);
    }

    pub fn open(
        self: *McpPicker,
        alloc: std.mem.Allocator,
        registry: *agent.mcp.registry.McpRegistry,
        cfg: std.json.Value,
    ) !void {
        self.mcp_registry = registry;
        self.mcp_config = cfg;
        self.server_names.clearRetainingCapacity();
        if (cfg == .object) {
            var it = cfg.object.iterator();
            while (it.next()) |entry| {
                try self.server_names.append(alloc, entry.key_ptr.*);
            }
        }
        self.active = true;
        self.selected = 0;
        self.phase = .servers;
        self.entered_server = null;
    }

    pub fn reset(self: *McpPicker) void {
        self.active = false;
        self.phase = .servers;
        self.selected = 0;
        self.entered_server = null;
        self.server_names.clearRetainingCapacity();
        self.mcp_registry = null;
        self.mcp_config = .null;
    }

    pub fn enter(self: *McpPicker) void {
        switch (self.phase) {
            .servers => {
                if (self.selected >= self.server_names.items.len) return;
                self.entered_server = self.server_names.items[self.selected];
                self.phase = .tools;
                self.selected = 0;
            },
            .tools => {},
        }
    }

    pub fn backOrClose(self: *McpPicker) bool {
        if (self.phase == .tools) {
            self.phase = .servers;
            if (self.entered_server) |name| {
                for (self.server_names.items, 0..) |n, i| {
                    if (std.mem.eql(u8, n, name)) {
                        self.selected = i;
                        break;
                    }
                }
            }
            self.entered_server = null;
            return true;
        }
        return false;
    }

    pub fn moveUp(self: *McpPicker) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *McpPicker) void {
        const max = self.currentListLen();
        if (max == 0) return;
        if (self.selected + 1 < max) self.selected += 1;
    }

    fn currentListLen(self: *const McpPicker) usize {
        return switch (self.phase) {
            .servers => self.server_names.items.len,
            .tools => blk: {
                const tools = self.currentTools() orelse break :blk 0;
                break :blk tools.len;
            },
        };
    }

    fn currentTools(self: *const McpPicker) ?[]const agent.mcp.client.Tool {
        const name = self.entered_server orelse return null;
        const reg = self.mcp_registry orelse return null;
        const client = reg.clientFor(name) orelse return null;
        return client.cached_tools;
    }

    pub fn render(
        self: *McpPicker,
        win: vaxis.Window,
        screen_w: u16,
        screen_h: u16,
    ) void {
        switch (self.phase) {
            .servers => self.renderServers(win, screen_w, screen_h),
            .tools => self.renderTools(win, screen_w, screen_h),
        }
    }

    fn renderServers(
        self: *McpPicker,
        win: vaxis.Window,
        screen_w: u16,
        screen_h: u16,
    ) void {
        var items_buf: [MAX_SERVERS]modal_list.Item = undefined;

        const reg = self.mcp_registry;

        const n = @min(self.server_names.items.len, MAX_SERVERS);
        for (self.server_names.items[0..n], 0..) |name, i| {
            var badge: ?modal_list.Badge = null;
            var secondary: ?[]const u8 = null;

            // Each server reports its own state, so a still-connecting or failed
            // HTTP server shows its status while connected stdio servers show
            // "connected" right away — no shared all-or-nothing gate.
            if (reg) |r| {
                switch (r.serverState(name)) {
                    .loading => badge = .{ .text = "loading…", .fg = status_loading_fg },
                    .failed => badge = .{ .text = "failed", .fg = status_failed_fg },
                    .connected => {
                        badge = .{ .text = "connected", .fg = status_connected_fg };
                        if (r.clientFor(name)) |c| {
                            secondary = std.fmt.bufPrint(&self.count_text_buf[i], "{d} tool(s)", .{c.cached_tools.len}) catch null;
                        }
                    },
                }
            } else {
                badge = .{ .text = "loading…", .fg = status_loading_fg };
            }

            items_buf[i] = .{
                .primary = name,
                .secondary = secondary,
                .badge = badge,
            };
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " MCP servers",
            .esc_hint = "enter→tools  esc",
            .items = items_buf[0..n],
            .selected = self.selected,
            .empty_message = " (no mcpServers configured)",
            .max_width = 70,
            .max_height = 20,
        });
    }

    fn renderTools(
        self: *McpPicker,
        win: vaxis.Window,
        screen_w: u16,
        screen_h: u16,
    ) void {
        const max_items = 64;
        var items_buf: [max_items]modal_list.Item = undefined;

        const tools = self.currentTools() orelse {
            modal_list.render(win, screen_w, screen_h, .{
                .title = " MCP tools",
                .esc_hint = "esc back",
                .items = items_buf[0..0],
                .selected = 0,
                .empty_message = " (no tools — server may have failed)",
                .max_width = 80,
                .max_height = 20,
            });
            return;
        };

        const n = @min(tools.len, max_items);
        for (tools[0..n], 0..) |t, i| {
            items_buf[i] = .{
                .primary = t.name,
                .secondary = t.description,
            };
        }

        const title = std.fmt.bufPrint(&self.title_buf, " MCP tools — {s}", .{self.entered_server orelse ""}) catch " MCP tools";

        modal_list.render(win, screen_w, screen_h, .{
            .title = title,
            .esc_hint = "esc back",
            .items = items_buf[0..n],
            .selected = self.selected,
            .max_width = 90,
            .max_height = 22,
        });
    }
};

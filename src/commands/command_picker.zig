const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const palette = @import("theme");

pub const MAX_RESULTS = 10;
pub const SKILL_PREFIX = "skills:";
const COUNTER_BUF_LEN = 32;
const COUNTER_FG = palette.dim;

pub const CommandAction = enum { provider, model, clear, compact, fork, resume_session, init, mcp, skills, rename, sandbox, export_session, copy_session, settings, exit, logout };

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    action: ?CommandAction,
};

pub const commands = [_]Command{
    .{ .name = "provider", .description = "Set provider API key", .action = .provider },
    .{ .name = "model", .description = "Choose active model", .action = .model },
    .{ .name = "clear", .description = "Clear conversation", .action = .clear },
    .{ .name = "compact", .description = "Compact conversation", .action = .compact },
    .{ .name = "fork", .description = "Fork session", .action = .fork },
    .{ .name = "resume", .description = "Resume conversation", .action = .resume_session },
    .{ .name = "init", .description = "Create or update AGENTS.md", .action = .init },
    .{ .name = "mcp", .description = "List active MCP servers", .action = .mcp },
    .{ .name = "skills", .description = "List skills and toggle enablement", .action = .skills },
    .{ .name = "rename", .description = "Rename current session", .action = .rename },
    .{ .name = "sandbox", .description = "Toggle Docker sandbox", .action = .sandbox },
    .{ .name = "export", .description = "Export conversation to HTML", .action = .export_session },
    .{ .name = "copy", .description = "Copy session to clipboard", .action = .copy_session },
    .{ .name = "settings", .description = "Open settings", .action = .settings },
    .{ .name = "exit", .description = "Exit the application", .action = .exit },
    .{ .name = "logout", .description = "Remove provider authenticacion", .action = .logout },
};

/// Exact (case-sensitive) lookup of a built-in command by its `name`.
/// Used to dispatch "/name args..." lines where the picker is inactive.
pub fn findByName(name: []const u8) ?Command {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

pub const CommandPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    results: std.ArrayList(Command) = .{},
    selected: usize = 0,
    skill_registry: ?*const agent.skills.Registry = null,
    counter_buf: [COUNTER_BUF_LEN]u8 = undefined,

    pub fn init(skill_registry: ?*const agent.skills.Registry) CommandPicker {
        return .{ .skill_registry = skill_registry };
    }

    pub fn deinit(self: *CommandPicker, alloc: std.mem.Allocator) void {
        self.freeOwnedNames(alloc);
        self.query.deinit(alloc);
        self.results.deinit(alloc);
    }

    pub fn reset(self: *CommandPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.freeOwnedNames(alloc);
        self.results.clearRetainingCapacity();
        self.selected = 0;
    }

    fn freeOwnedNames(self: *CommandPicker, alloc: std.mem.Allocator) void {
        for (self.results.items) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, SKILL_PREFIX)) alloc.free(cmd.name);
        }
    }

    pub fn updateFromInput(self: *CommandPicker, alloc: std.mem.Allocator, input: []const u8) !void {
        if (input.len == 0 or input[0] != '/' or std.mem.indexOfScalar(u8, input, ' ') != null) {
            self.reset(alloc);
            return;
        }

        self.active = true;
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(alloc, input[1..]);
        try self.refresh(alloc);
    }

    pub fn selectedCommand(self: *const CommandPicker) ?Command {
        if (self.results.items.len == 0) return null;
        return self.results.items[self.selected];
    }

    fn refresh(self: *CommandPicker, alloc: std.mem.Allocator) !void {
        self.freeOwnedNames(alloc);
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (commands) |command| {
            if (matchesQuery(command.name, self.query.items)) {
                try self.results.append(alloc, command);
            }
        }

        if (self.skill_registry) |registry| {
            const prefix_matches = self.query.items.len > 0 and
                std.ascii.indexOfIgnoreCase(SKILL_PREFIX, self.query.items) != null;
            for (registry.skills.items) |skill| {
                if (!skill.enabled) continue;
                if (prefix_matches or matchesQuery(skill.name, self.query.items)) {
                    const skillName = try std.fmt.allocPrint(alloc, "{s}{s}", .{ SKILL_PREFIX, skill.name });
                    try self.results.append(alloc, .{
                        .name = skillName,
                        .description = skill.description,
                        .action = null,
                    });
                }
            }
        }
    }

    fn matchesQuery(name: []const u8, query: []const u8) bool {
        return query.len == 0 or std.ascii.indexOfIgnoreCase(name, query) != null;
    }

    pub fn render(self: *CommandPicker, win: vaxis.Window, screen_w: u16, anchor_y: u16) void {
        const n: u16 = @intCast(@min(self.results.items.len, MAX_RESULTS));
        const start: usize = if (self.selected < n) 0 else self.selected - n + 1;
        const picker_h: u16 = n + 2;
        const picker_y: u16 = if (anchor_y >= picker_h) anchor_y - picker_h else 0;
        const picker = win.child(.{
            .x_off = 0,
            .y_off = picker_y,
            .width = screen_w,
            .height = picker_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        // Fill entire picker background so text behind it doesn't show through
        var row_idx: u16 = 0;
        while (row_idx < picker_h) : (row_idx += 1) {
            var col: u16 = 1;
            while (col < screen_w -| 1) : (col += 1) {
                picker.writeCell(col, row_idx, .{ .char = .{ .grapheme = " ", .width = 1 } });
            }
        }

        const prefix_width: u16 = 4;
        const name_width = self.maxNameWidth(start, n);
        const desc_col = prefix_width + name_width + 2;
        const max_desc_width: usize = picker.width -| desc_col -| 1;

        var row: u16 = 0;
        while (row < n) : (row += 1) {
            const idx = start + row;
            if (idx >= self.results.items.len) break;
            const command = self.results.items[idx];

            const is_selected = idx == self.selected;
            const style: vaxis.Style = if (is_selected)
                .{ .fg = palette.cyan, .bold = false }
            else
                .{ .fg = palette.light };
            const prefix: []const u8 = if (is_selected) "❯ /" else "  /";

            const res = picker.printSegment(.{ .text = prefix, .style = style }, .{ .row_offset = row, .col_offset = 0 });
            _ = picker.printSegment(.{ .text = command.name, .style = style }, .{ .row_offset = row, .col_offset = res.col });
            if (max_desc_width == 0 or command.description.len == 0) continue;
            _ = picker.printSegment(.{
                .text = agent.utils.truncate(command.description, max_desc_width, 3),
                .style = if (is_selected)
                    .{ .fg = palette.cyan }
                else
                    .{ .fg = palette.dim },
            }, .{ .row_offset = row, .col_offset = desc_col });
        }
        self.renderCounter(win, picker_y, picker_h);
    }

    fn maxNameWidth(self: *const CommandPicker, start: usize, visible_count: u16) u16 {
        var width: u16 = 0;
        var row: u16 = 0;
        while (row < visible_count) : (row += 1) {
            const idx = start + row;
            if (idx >= self.results.items.len) break;
            width = @max(width, @as(u16, @intCast(self.results.items[idx].name.len + 1)));
        }
        return width;
    }

    fn renderCounter(self: *CommandPicker, win: vaxis.Window, picker_y: u16, picker_h: u16) void {
        const text = std.fmt.bufPrint(&self.counter_buf, " ({d}/{d}) ", .{ self.selected + 1, self.results.items.len }) catch return;
        _ = win.printSegment(
            .{ .text = text, .style = .{ .fg = COUNTER_FG } },
            .{ .row_offset = picker_y + picker_h -| 1, .col_offset = 1 },
        );
    }
};

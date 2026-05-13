const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");

pub const MAX_RESULTS = 10;

pub const CommandAction = enum { provider, model, clear, compact, fork, resume_session, init, exit };

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
    .{ .name = "exit", .description = "Exit the application", .action = .exit },
};

pub const CommandPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    results: std.ArrayList(Command) = .{},
    selected: usize = 0,
    skill_registry: ?*const agent.skills.Registry = null,

    pub fn init(skill_registry: ?*const agent.skills.Registry) CommandPicker {
        return .{ .skill_registry = skill_registry };
    }

    pub fn deinit(self: *CommandPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
    }

    pub fn reset(self: *CommandPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.results.clearRetainingCapacity();
        self.selected = 0;
        _ = alloc;
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
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (commands) |command| {
            if (matchesQuery(command.name, self.query.items)) {
                try self.results.append(alloc, command);
            }
        }

        if (self.skill_registry) |registry| {
            for (registry.skills.items) |skill| {
                if (matchesQuery(skill.name, self.query.items)) {
                    try self.results.append(alloc, .{
                        .name = skill.name,
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

    pub fn render(self: *const CommandPicker, win: vaxis.Window, screen_w: u16, input_y: u16) void {
        const n: u16 = @intCast(@min(self.results.items.len, MAX_RESULTS));
        const picker_h: u16 = n + 2;
        const picker_y: u16 = if (input_y >= picker_h) input_y - picker_h else 0;
        const picker = win.child(.{
            .x_off = 0,
            .y_off = picker_y,
            .width = screen_w,
            .height = picker_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const panel_bg: vaxis.Color = .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };

        // Fill entire panel background
        var row_idx: u16 = 0;
        while (row_idx < picker_h) : (row_idx += 1) {
            var col: u16 = 1;
            while (col < screen_w -| 1) : (col += 1) {
                picker.writeCell(col, row_idx, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = panel_bg } });
            }
        }

        const prefix_width: u16 = 4;
        const name_width = self.maxNameWidth(n);
        const desc_col = prefix_width + name_width + 2;
        const max_desc_width: usize = picker.width -| desc_col -| 1;

        for (self.results.items, 0..) |command, idx| {
            const row: u16 = @intCast(idx);
            if (row >= n) break;

            const is_selected = idx == self.selected;
            const bg: vaxis.Color = if (is_selected)
                .{ .rgb = .{ 0xC0, 0x70, 0x20 } }
            else
                panel_bg;
            const style: vaxis.Style = if (is_selected)
                .{ .bg = bg, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true }
            else
                .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } }, .bg = panel_bg };
            const prefix: []const u8 = if (is_selected) " > /" else "   /";

            const res = picker.printSegment(.{ .text = prefix, .style = style }, .{ .row_offset = row, .col_offset = 0 });
            _ = picker.printSegment(.{ .text = command.name, .style = style }, .{ .row_offset = row, .col_offset = res.col });
            if (max_desc_width == 0 or command.description.len == 0) continue;
            _ = picker.printSegment(.{
                .text = truncateDescription(command.description, max_desc_width),
                .style = if (is_selected)
                    .{ .fg = .{ .rgb = .{ 0x2A, 0x15, 0x00 } }, .bg = bg }
                else
                    .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } }, .bg = panel_bg },
            }, .{ .row_offset = row, .col_offset = desc_col });
        }
    }

    fn maxNameWidth(self: *const CommandPicker, visible_count: u16) u16 {
        var width: u16 = 0;
        for (self.results.items, 0..) |command, idx| {
            if (idx >= visible_count) break;
            width = @max(width, @as(u16, @intCast(command.name.len + 1)));
        }
        return width;
    }

    fn truncateDescription(text: []const u8, max_width: usize) []const u8 {
        if (text.len <= max_width) return text;

        var end = if (max_width <= 3) max_width else max_width - 3;
        while (end > 0 and isUtf8ContinuationByte(text[end])) {
            end -= 1;
        }
        return text[0..end];
    }

    fn isUtf8ContinuationByte(byte: u8) bool {
        return (byte & 0b1100_0000) == 0b1000_0000;
    }
};

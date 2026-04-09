const std = @import("std");
const vaxis = @import("vaxis");

pub const MAX_RESULTS = 10;

pub const CommandAction = enum { provider, model, clear };

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    action: CommandAction,
};

pub const commands = [_]Command{
    .{ .name = "provider", .description = "Set provider API key", .action = .provider },
    .{ .name = "model", .description = "Choose active model", .action = .model },
    .{ .name = "clear", .description = "Clear conversation", .action = .clear },
};

pub const CommandPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    results: std.ArrayList(*const Command) = .{},
    selected: usize = 0,

    pub fn init() CommandPicker {
        return .{};
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

    pub fn selectedCommand(self: *const CommandPicker) ?*const Command {
        if (self.results.items.len == 0) return null;
        return self.results.items[self.selected];
    }

    fn refresh(self: *CommandPicker, alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (&commands) |*command| {
            if (self.query.items.len == 0 or std.ascii.indexOfIgnoreCase(command.name, self.query.items) != null) {
                try self.results.append(alloc, command);
            }
        }
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

        for (self.results.items, 0..) |command, idx| {
            const row: u16 = @intCast(idx);
            if (row >= n) break;

            const is_selected = idx == self.selected;
            const bg: vaxis.Color = if (is_selected)
                .{ .rgb = .{ 0xC0, 0x70, 0x20 } }
            else
                .{ .index = 0 };
            const style: vaxis.Style = if (is_selected)
                .{ .bg = bg, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true }
            else
                .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } };
            const prefix: []const u8 = if (is_selected) " > /" else "   /";

            if (is_selected) {
                var col: u16 = 1;
                while (col < screen_w -| 1) : (col += 1) {
                    picker.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
                }
            }

            const res = picker.printSegment(.{ .text = prefix, .style = style }, .{ .row_offset = row, .col_offset = 0 });
            const name_res = picker.printSegment(.{ .text = command.name, .style = style }, .{ .row_offset = row, .col_offset = res.col });
            _ = picker.printSegment(.{
                .text = command.description,
                .style = if (is_selected)
                    .{ .fg = .{ .rgb = .{ 0x2A, 0x15, 0x00 } }, .bg = bg }
                else
                    .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
            }, .{ .row_offset = row, .col_offset = name_res.col + 2 });
        }
    }
};

const std = @import("std");
const vaxis = @import("vaxis");
const modal_list = @import("../modal_list.zig");
const palette = @import("theme");

const badge_on = palette.green;
const badge_off = palette.dim;

const log = std.log.scoped(.settings);

pub const Setting = struct { status: bool = false };

pub const Settings = struct {
    showThinking: Setting = .{},
    testOption: Setting = .{},

    active: bool = false,
    selected: usize = 0,

    const option_count = blk: {
        var n: usize = 0;
        for (@typeInfo(Settings).@"struct".fields) |field| {
            if (field.type == Setting) n += 1;
        }
        break :blk n;
    };

    pub fn init(cfg: Settings) Settings {
        var s: Settings = .{};
        inline for (@typeInfo(Settings).@"struct".fields) |field| {
            if (field.type == Setting) @field(s, field.name) = @field(cfg, field.name);
        }
        return s;
    }

    pub fn open(self: *Settings) void {
        self.active = true;
        self.selected = 0;
    }

    pub fn reset(self: *Settings) void {
        self.active = false;
        self.selected = 0;
    }

    pub fn moveUp(self: *Settings) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *Settings) void {
        if (self.selected + 1 < option_count) self.selected += 1;
    }

    pub fn toggleSelected(self: *Settings) void {
        var idx: usize = 0;
        inline for (@typeInfo(Settings).@"struct".fields) |field| {
            if (field.type == Setting) {
                if (idx == self.selected)
                    @field(self, field.name).status = !@field(self, field.name).status;
                idx += 1;
            }
        }
    }

    pub fn render(self: *const Settings, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        var items_buf: [option_count]modal_list.Item = undefined;
        comptime var idx: usize = 0;
        inline for (@typeInfo(Settings).@"struct".fields) |field| {
            if (field.type == Setting) {
                const on = @field(self, field.name).status;
                items_buf[idx] = .{
                    .primary = field.name,
                    .badge = .{ .text = if (on) "true " else "false ", .fg = if (on) badge_on else badge_off },
                };
                idx += 1;
            }
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " Settings",
            .items = &items_buf,
            .selected = self.selected,
            .max_width = 50,
            .max_height = 20,
        });
    }
};

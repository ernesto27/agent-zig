const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = agent.modal_list;

const Authenticated = agent.config.Providers.Authenticated;

const badge_fg: vaxis.Color = .{ .rgb = .{ 0x60, 0xCC, 0x60 } };

pub const LogoutPicker = struct {
    active: bool = false,
    selected: usize = 0,
    authed: Authenticated = .{},

    pub fn init() LogoutPicker {
        return .{};
    }

    pub fn open(self: *LogoutPicker, authed: Authenticated) void {
        self.active = true;
        self.selected = 0;
        self.authed = authed;
    }

    pub fn reset(self: *LogoutPicker) void {
        self.active = false;
        self.selected = 0;
    }

    pub fn moveUp(self: *LogoutPicker) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *LogoutPicker) void {
        if (self.selected + 1 < self.authed.len) self.selected += 1;
    }

    pub fn selectedProvider(self: *const LogoutPicker) ?[]const u8 {
        const names = self.authed.slice();
        if (self.selected >= names.len) return null;
        return names[self.selected];
    }

    pub fn render(self: *const LogoutPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const names = self.authed.slice();
        var items_buf: [agent.config.Providers.count]modal_list.Item = undefined;
        for (names, 0..) |name, i| {
            items_buf[i] = .{
                .primary = name,
                .badge = modal_list.Badge{ .text = "logged in ", .fg = badge_fg },
            };
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " Log out of provider",
            .items = items_buf[0..names.len],
            .selected = self.selected,
            .empty_message = "(no authenticated providers)",
            .max_width = 50,
            .max_height = 20,
        });
    }
};

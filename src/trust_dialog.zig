const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");

pub const Choice = enum { yes, no };

pub const TrustDialog = struct {
    active: bool = false,
    selected: Choice = .yes,
    cwd: []const u8 = "",

    pub fn init() TrustDialog {
        return .{};
    }

    pub fn open(self: *TrustDialog, cwd: []const u8) void {
        self.active = true;
        self.selected = .yes;
        self.cwd = cwd;
    }

    pub fn reset(self: *TrustDialog) void {
        self.active = false;
        self.selected = .yes;
    }

    pub fn moveUp(self: *TrustDialog) void {
        self.selected = .yes;
    }

    pub fn moveDown(self: *TrustDialog) void {
        self.selected = .no;
    }

    pub fn render(self: *const TrustDialog, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const modal_w: u16 = @min(60, screen_w -| 4);
        const modal_h: u16 = 8;
        const modal_x: u16 = (screen_w -| modal_w) / 2;
        const modal_y: u16 = (screen_h -| modal_h) / 2;

        const modal = win.child(.{
            .x_off = modal_x,
            .y_off = modal_y,
            .width = modal_w,
            .height = modal_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        var fr: u16 = 0;
        while (fr < modal_h) : (fr += 1) {
            var fc: u16 = 0;
            while (fc < modal_w) : (fc += 1) {
                modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 } });
            }
        }

        _ = modal.printSegment(.{
            .text = " Do you trust in this folder?",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });

        const path_width: usize = modal_w -| 3;
        _ = modal.printSegment(.{
            .text = agent.utils.truncate(self.cwd, path_width, 3),
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

        renderOption(modal, 4, "Yes - trust folder", self.selected == .yes);
        renderOption(modal, 5, "No  - untrust folder", self.selected == .no);

        _ = modal.printSegment(.{
            .text = "↑↓ select   Enter confirm",
            .style = .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } },
        }, .{ .row_offset = 7, .col_offset = 2 });
    }

    fn renderOption(modal: vaxis.Window, row: u16, label: []const u8, is_sel: bool) void {
        const fg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0x9C, 0xE3, 0xEE } } else .{ .rgb = .{ 0xDD, 0xDD, 0xDD } };
        if (is_sel) {
            _ = modal.printSegment(.{
                .text = "❯",
                .style = .{ .fg = fg, .bold = true },
            }, .{ .row_offset = row, .col_offset = 2 });
        }
        _ = modal.printSegment(.{
            .text = label,
            .style = .{ .fg = fg, .bold = is_sel },
        }, .{ .row_offset = row, .col_offset = 4 });
    }
};

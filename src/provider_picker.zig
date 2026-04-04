const std = @import("std");
const vaxis = @import("vaxis");
const model_picker = @import("model_picker.zig");

 pub const Phase = enum { list, key_input };

pub const ProviderPicker = struct {
    active: bool = false, 
    selected: usize = 0,
    phase: Phase = .list,
    key_input: std.ArrayList(u8) = .{},

    pub fn init() ProviderPicker {
        return .{};
    }

    pub fn deinit(self: *ProviderPicker, alloc: std.mem.Allocator) void {
        self.key_input.deinit(alloc);
    }

    pub fn open(self: *ProviderPicker) void {
        self.active = true;
        self.selected = 0;
        self.phase = .list;
    }
    pub fn selectedProvider(self: *const ProviderPicker) *const model_picker.Provider {
        return &model_picker.providers[self.selected];
    }

    pub fn reset(self: *ProviderPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.selected = 0;
        self.phase = .list;
        self.key_input.clearRetainingCapacity();
        _ = alloc;
    }

    pub fn render(self: *const ProviderPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const modal_w: u16 = @min(50, screen_w -| 4);
        const modal_h: u16 = if (self.phase == .list)
            @intCast(model_picker.providers.len + 4)
        else
            7;
        const modal_x: u16 = (screen_w -| modal_w) / 2;
        const modal_y: u16 = (screen_h -| modal_h) / 2;

        const modal = win.child(.{
            .x_off = modal_x,
            .y_off = modal_y,
            .width = modal_w,
            .height = modal_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const modal_bg: vaxis.Color = .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };
        var fr: u16 = 0;
        while (fr < modal_h) : (fr += 1) {
            var fc: u16 = 0;
            while (fc < modal_w) : (fc += 1) {
                modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = modal_bg } });
            }
        }

        switch (self.phase) {
            .list => {
                _ = modal.printSegment(.{
                    .text = " Select provider",
                    .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
                }, .{ .row_offset = 0, .col_offset = 1 });
                _ = modal.printSegment(.{
                    .text = "esc ",
                    .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
                }, .{ .row_offset = 0, .col_offset = modal_w -| 5 });

                for (model_picker.providers, 0..) |p, idx| {
                    const prow: u16 = @intCast(idx + 2);
                    const is_sel = idx == self.selected;
                    const bg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xC0, 0x70, 0x20 } } else .{ .index = 0 };
                    const fg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else .{ .rgb = .{ 0xDD, 0xDD, 0xDD } };

                    if (is_sel) {
                        var c: u16 = 1;
                        while (c < modal_w -| 1) : (c += 1) {
                            modal.writeCell(c, prow, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
                        }
                    }

                    _ = modal.printSegment(.{
                        .text = p.name,
                        .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
                    }, .{ .row_offset = prow, .col_offset = 2 });
                }
            },
            .key_input => {
                const provider = self.selectedProvider();
                _ = modal.printSegment(.{
                    .text = " API key for ",
                    .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
                }, .{ .row_offset = 0, .col_offset = 1 });
                _ = modal.printSegment(.{
                    .text = provider.name,
                    .style = .{ .fg = .{ .rgb = .{ 0xC0, 0x70, 0x20 } }, .bold = true },
                }, .{ .row_offset = 0, .col_offset = 15 });

                const key_text = if (self.key_input.items.len > 0)
                    self.key_input.items
                else
                    "Enter API key...";
                const key_style: vaxis.Style = if (self.key_input.items.len > 0)
                    .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } }
                else
                    .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } };

                _ = modal.printSegment(.{
                    .text = key_text,
                    .style = key_style,
                }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

                _ = modal.printSegment(.{
                    .text = "Enter to save   esc to cancel",
                    .style = .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } },
                }, .{ .row_offset = 4, .col_offset = 2 });
            },
        }
    }
};

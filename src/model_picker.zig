const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");

const p = agent.llm.providers;

// Re-export data types so existing callers don't need to change imports
pub const Model = p.Model;
pub const Provider = p.Provider;
pub const providers = p.providers;
pub const findModel = p.findModel;

pub const ModelPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    selected: usize = 0,
    results: std.ArrayList(*const Model) = .{},

    pub fn init() ModelPicker {
        return .{};
    }

    pub fn deinit(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
    }

    pub fn refresh(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (&p.providers) |*prov| {
            for (prov.models) |*m| {
                if (self.query.items.len == 0) {
                    try self.results.append(alloc, m);
                } else {
                    const q = self.query.items;
                    if (std.ascii.indexOfIgnoreCase(m.display, q) != null or
                        std.ascii.indexOfIgnoreCase(m.id, q) != null)
                    {
                        try self.results.append(alloc, m);
                    }
                }
            }
        }
    }

    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.active = true;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        try self.refresh(alloc);
    }

    pub fn reset(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.results.clearRetainingCapacity();
        _ = alloc;
    }

    pub fn render(self: *const ModelPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const modal_w: u16 = @min(60, screen_w -| 4);
        const modal_h: u16 = @intCast(@min(self.results.items.len + 5, 20));
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

        _ = modal.printSegment(.{
            .text = " Select model",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });
        _ = modal.printSegment(.{
            .text = "esc ",
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = 0, .col_offset = modal_w -| 5 });

        const q = self.query.items;
        const search_text = if (q.len > 0) q else "Search...";
        const search_style: vaxis.Style = if (q.len > 0)
            .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } }
        else
            .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } };
        _ = modal.printSegment(.{
            .text = search_text,
            .style = search_style,
        }, .{ .row_offset = 1, .col_offset = 2 });

        for (self.results.items, 0..) |m, idx| {
            const mrow: u16 = @intCast(idx + 2);
            if (mrow >= modal_h -| 1) break;
            const is_sel = idx == self.selected;
            const bg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xC0, 0x70, 0x20 } } else .{ .index = 0 };
            const fg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else .{ .rgb = .{ 0xDD, 0xDD, 0xDD } };

            if (is_sel) {
                var c: u16 = 1;
                while (c < modal_w -| 1) : (c += 1) {
                    modal.writeCell(c, mrow, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
                }
            }

            _ = modal.printSegment(.{
                .text = m.display,
                .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
            }, .{ .row_offset = mrow, .col_offset = 2 });

            if (m.free) {
                _ = modal.printSegment(.{
                    .text = "Free",
                    .style = .{ .fg = .{ .rgb = .{ 0x60, 0xCC, 0x60 } }, .bg = bg },
                }, .{ .row_offset = mrow, .col_offset = modal_w -| 6 });
            }
        }
    }
};

const std = @import("std");
const vaxis = @import("vaxis");

pub const Badge = struct {
    text: []const u8,
    fg: vaxis.Color,
};

pub const Item = struct {
    primary: []const u8,
    secondary: ?[]const u8 = null,
    badge: ?Badge = null,
};

pub const Options = struct {
    title: []const u8,
    esc_hint: []const u8 = "esc",
    query: ?[]const u8 = null,
    query_placeholder: []const u8 = "Search...",
    items: []const Item,
    selected: usize,
    empty_message: []const u8 = "(empty)",
    max_width: u16 = 60,
    max_height: u16 = 20,
};

const modal_bg: vaxis.Color = .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };
const sel_bg: vaxis.Color = .{ .rgb = .{ 0xC0, 0x70, 0x20 } };
const fg_default: vaxis.Color = .{ .rgb = .{ 0xDD, 0xDD, 0xDD } };
const fg_selected: vaxis.Color = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } };
const fg_muted: vaxis.Color = .{ .rgb = .{ 0x88, 0x88, 0x88 } };
const fg_muted_on_sel: vaxis.Color = .{ .rgb = .{ 0x2A, 0x15, 0x00 } };
const fg_placeholder: vaxis.Color = .{ .rgb = .{ 0x66, 0x66, 0x66 } };

pub fn render(win: vaxis.Window, screen_w: u16, screen_h: u16, opts: Options) void {
    const has_query = opts.query != null;
    const overhead: u16 = if (has_query) 5 else 4;
    const item_count: u16 = @intCast(opts.items.len);
    const wanted_h: u16 = @min(opts.max_height, @max(@as(u16, 6), item_count + overhead));
    const modal_w: u16 = @min(opts.max_width, screen_w -| 4);
    const modal_h: u16 = @min(wanted_h, screen_h -| 4);
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
            modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = modal_bg } });
        }
    }

    _ = modal.printSegment(.{
        .text = opts.title,
        .style = .{ .fg = fg_selected, .bold = true, .bg = modal_bg },
    }, .{ .row_offset = 0, .col_offset = 1 });
    const hint_len: u16 = @intCast(opts.esc_hint.len);
    if (modal_w > hint_len + 3) {
        _ = modal.printSegment(.{
            .text = opts.esc_hint,
            .style = .{ .fg = fg_muted, .bg = modal_bg },
        }, .{ .row_offset = 0, .col_offset = modal_w - hint_len - 2 });
    }

    var items_row: u16 = 2;
    if (opts.query) |q| {
        const text = if (q.len > 0) q else opts.query_placeholder;
        const style: vaxis.Style = if (q.len > 0)
            .{ .fg = fg_selected, .bg = modal_bg }
        else
            .{ .fg = fg_placeholder, .bg = modal_bg };
        _ = modal.printSegment(.{ .text = text, .style = style }, .{ .row_offset = 1, .col_offset = 2 });
        items_row = 2;
    } else {
        items_row = 2;
    }

    if (opts.items.len == 0) {
        _ = modal.printSegment(.{
            .text = opts.empty_message,
            .style = .{ .fg = fg_muted, .bg = modal_bg },
        }, .{ .row_offset = items_row, .col_offset = 2 });
        return;
    }

    const last_row: u16 = modal_h -| 1;
    const inner_w: u16 = modal_w -| 2;

    var primary_max: usize = 0;
    for (opts.items) |it| {
        if (it.primary.len > primary_max) primary_max = it.primary.len;
    }
    const secondary_col: u16 = @intCast(@min(
        @as(usize, inner_w) - 1,
        primary_max + 4,
    ));

    for (opts.items, 0..) |it, idx| {
        const row: u16 = items_row + @as(u16, @intCast(idx));
        if (row >= last_row) break;

        const is_sel = idx == opts.selected;
        const bg = if (is_sel) sel_bg else modal_bg;
        const fg = if (is_sel) fg_selected else fg_default;
        const fg_secondary = if (is_sel) fg_muted_on_sel else fg_muted;

        if (is_sel) {
            var c: u16 = 1;
            while (c < inner_w + 1) : (c += 1) {
                modal.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
            }
        }

        const cursor: []const u8 = if (is_sel) "❯ " else "  ";
        _ = modal.printSegment(.{
            .text = cursor,
            .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
        }, .{ .row_offset = row, .col_offset = 1 });

        _ = modal.printSegment(.{
            .text = it.primary,
            .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
        }, .{ .row_offset = row, .col_offset = 3 });

        if (it.secondary) |sec| {
            if (sec.len > 0 and secondary_col < inner_w -| 1) {
                const max_sec_w: usize = @as(usize, inner_w) -| secondary_col -| 1;
                const text = truncate(sec, max_sec_w);
                _ = modal.printSegment(.{
                    .text = text,
                    .style = .{ .fg = fg_secondary, .bg = bg },
                }, .{ .row_offset = row, .col_offset = secondary_col });
            }
        }

        if (it.badge) |bdg| {
            const blen: u16 = @intCast(bdg.text.len);
            if (blen + 2 < inner_w) {
                _ = modal.printSegment(.{
                    .text = bdg.text,
                    .style = .{ .fg = bdg.fg, .bg = bg, .bold = true },
                }, .{ .row_offset = row, .col_offset = inner_w - blen });
            }
        }
    }
}

fn truncate(text: []const u8, max_w: usize) []const u8 {
    if (text.len <= max_w) return text;
    if (max_w <= 1) return text[0..0];
    var end = max_w - 1;
    while (end > 0 and isUtf8Continuation(text[end])) end -= 1;
    return text[0..end];
}

fn isUtf8Continuation(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

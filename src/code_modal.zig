const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const app_mod = @import("App.zig");
const App = app_mod.App;
const ConfirmationAction = app_mod.ConfirmationAction;

const title_fg: vaxis.Color = .{ .rgb = .{ 0x9C, 0xE3, 0xEE } };
const fg_muted: vaxis.Color = .{ .rgb = .{ 0x88, 0x88, 0x88 } };
const fg_write: vaxis.Color = .{ .rgb = .{ 0xCC, 0xFF, 0xCC } };
const fg_old: vaxis.Color = .{ .rgb = .{ 0xFF, 0x60, 0x60 } };
const fg_new: vaxis.Color = .{ .rgb = .{ 0x60, 0xFF, 0x60 } };

const h_margin: u16 = 8;
const v_margin: u16 = 4;
const min_width: u16 = 40;
const side_padding: u16 = 4;
const footer_hint = " ↑↓ select · Enter · Esc · PgUp/PgDn";

const Geometry = struct {
    w: u16,
    h: u16,
    x: u16,
    y: u16,
    body_start: u16,
    body_end: u16,
    options_start: u16,
    hint_row: u16,
    body_h: u16,
};

pub fn isCodeConfirmation(app: *const App) bool {
    if (!app.tool_confirmation.pending) return false;
    const name = app.tool_confirmation.tool_name;
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file");
}

fn isWrite(app: *const App) bool {
    return std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file");
}

pub fn contentLineCount(app: *const App) usize {
    const tc = app.tool_confirmation;
    if (isWrite(app)) return std.mem.count(u8, tc.content, "\n") + 1;
    return std.mem.count(u8, tc.old_string, "\n") + 1 +
        std.mem.count(u8, tc.new_string, "\n") + 1;
}

fn contentCols(app: *const App) usize {
    const tc = app.tool_confirmation;
    var max_len: usize = 0;
    if (isWrite(app)) {
        var it = std.mem.splitScalar(u8, tc.content, '\n');
        while (it.next()) |line| max_len = @max(max_len, line.len);
    } else {
        var old_it = std.mem.splitScalar(u8, tc.old_string, '\n');
        while (old_it.next()) |line| max_len = @max(max_len, line.len + 2);
        var new_it = std.mem.splitScalar(u8, tc.new_string, '\n');
        while (new_it.next()) |line| max_len = @max(max_len, line.len + 2);
    }
    return max_len;
}

fn geometry(screen_w: u16, screen_h: u16, content_cols: usize) Geometry {
    const h: u16 = screen_h -| v_margin;
    const desired_inner: usize = @max(content_cols + 1, @as(usize, footer_hint.len));
    const desired_w: u16 = @intCast(@min(desired_inner + side_padding, @as(usize, std.math.maxInt(u16))));
    const w: u16 = @min(@max(desired_w, min_width), screen_w -| h_margin);
    const x: u16 = (screen_w -| w) / 2;
    const y: u16 = (screen_h -| h) / 2;
    const options_start: u16 = h -| 5;
    const hint_row: u16 = h -| 2;
    const body_start: u16 = 2;
    const body_end: u16 = options_start;
    const body_h: u16 = body_end -| body_start;
    return .{
        .w = w,
        .h = h,
        .x = x,
        .y = y,
        .body_start = body_start,
        .body_end = body_end,
        .options_start = options_start,
        .hint_row = hint_row,
        .body_h = body_h,
    };
}

pub fn maxScroll(screen_w: u16, screen_h: u16, app: *const App) usize {
    const lines = contentLineCount(app);
    const geo = geometry(screen_w, screen_h, contentCols(app));
    return if (lines > geo.body_h) lines - geo.body_h else 0;
}

pub fn render(
    alloc: std.mem.Allocator,
    win: vaxis.Window,
    screen_w: u16,
    screen_h: u16,
    app: *const App,
    scroll: usize,
) void {
    if (!isCodeConfirmation(app)) return;

    const tc = app.tool_confirmation;
    const geo = geometry(screen_w, screen_h, contentCols(app));
    const inner_w: u16 = geo.w -| 2;

    const modal = win.child(.{
        .x_off = geo.x,
        .y_off = geo.y,
        .width = geo.w,
        .height = geo.h,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    var fr: u16 = 0;
    while (fr < geo.h) : (fr += 1) {
        var fc: u16 = 0;
        while (fc < geo.w) : (fc += 1) {
            modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 } });
        }
    }

    const title = std.fmt.allocPrint(alloc, " {s} {s} ", .{
        if (isWrite(app)) "New file:" else "Editing:",
        tc.file_path,
    }) catch " Preview ";
    _ = modal.printSegment(.{
        .text = agent.utils.truncate(title, inner_w, 0),
        .style = .{ .fg = title_fg, .bold = true },
    }, .{ .row_offset = 0, .col_offset = 1 });

    const ms = maxScroll(screen_w, screen_h, app);
    if (ms > 0) {
        const pos = std.fmt.allocPrint(alloc, "{d}/{d}", .{ @min(scroll, ms) + 1, ms + 1 }) catch "";
        const plen: u16 = @intCast(pos.len);
        if (inner_w > plen + 2) {
            _ = modal.printSegment(.{
                .text = pos,
                .style = .{ .fg = fg_muted },
            }, .{ .row_offset = 0, .col_offset = geo.w -| plen -| 2 });
        }
    }

    if (isWrite(app)) {
        var it = std.mem.splitScalar(u8, tc.content, '\n');
        var idx: usize = 0;
        var prow: u16 = geo.body_start;
        while (it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(line, inner_w, 1),
                    .style = .{ .fg = fg_write },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            idx += 1;
        }
    } else {
        var prow: u16 = geo.body_start;
        var idx: usize = 0;
        var old_it = std.mem.splitScalar(u8, tc.old_string, '\n');
        while (old_it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                const dl = std.fmt.allocPrint(alloc, "- {s}", .{line}) catch line;
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(dl, inner_w, 1),
                    .style = .{ .fg = fg_old },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            idx += 1;
        }
        var new_it = std.mem.splitScalar(u8, tc.new_string, '\n');
        while (new_it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                const dl = std.fmt.allocPrint(alloc, "+ {s}", .{line}) catch line;
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(dl, inner_w, 1),
                    .style = .{ .fg = fg_new },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            idx += 1;
        }
    }

    const options = [_]struct { label: []const u8, action: ConfirmationAction }{
        .{ .label = "Yes", .action = .approve },
        .{ .label = "No", .action = .deny },
        .{ .label = "Accept all", .action = .accept_all },
    };
    for (options, 0..) |opt, i| {
        const selected = tc.cursor == opt.action;
        const text = std.fmt.allocPrint(alloc, "{s}{s}", .{
            if (selected) " ❯ " else "   ",
            opt.label,
        }) catch opt.label;
        _ = modal.printSegment(.{
            .text = text,
            .style = .{ .fg = if (selected) title_fg else fg_muted, .bold = selected },
        }, .{ .row_offset = geo.options_start + @as(u16, @intCast(i)), .col_offset = 1 });
    }

    _ = modal.printSegment(.{
        .text = footer_hint,
        .style = .{ .fg = fg_muted },
    }, .{ .row_offset = geo.hint_row, .col_offset = 1 });
}

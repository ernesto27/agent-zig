const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig").App;

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const SpinnerState = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Wrap text into at most `max_lines` lines of `width` columns.
/// Handles embedded newlines: splits on '\n' first, then word-wraps each line.
/// Returns a fixed array; unused slots are null.
pub fn wrapText(text: []const u8, width: usize, comptime max_lines: usize) [max_lines]?[]const u8 {
    var lines: [max_lines]?[]const u8 = .{null} ** max_lines;
    if (width == 0) return lines;
    var line_idx: usize = 0;

    // Split on newlines first
    var rest = text;
    while (rest.len > 0 and line_idx < max_lines) {
        // Find next newline (or end of text)
        const nl_pos = std.mem.indexOfScalar(u8, rest, '\n');
        const physical_line = if (nl_pos) |pos| rest[0..pos] else rest;
        rest = if (nl_pos) |pos| rest[pos + 1 ..] else &.{};

        // Word-wrap this physical line
        if (physical_line.len == 0) {
            // Empty line (consecutive newlines) — emit a blank
            lines[line_idx] = "";
            line_idx += 1;
            continue;
        }

        var start: usize = 0;
        while (start < physical_line.len and line_idx < max_lines) {
            var end = if (start + width < physical_line.len) start + width else physical_line.len;

            if (end < physical_line.len) {
                var best = end;
                while (best > start) : (best -= 1) {
                    if (physical_line[best] == ' ') {
                        end = best;
                        break;
                    }
                }
            }

            lines[line_idx] = physical_line[start..end];
            line_idx += 1;
            start = end;
            if (start < physical_line.len and physical_line[start] == ' ') start += 1;
        }
    }

    return lines;
}

var loadingBuf: [32]u8 = undefined;

pub fn loading(elapsed_secs: usize) []const u8 {
    const frames = [_][]const u8{ "[=   ] ", "[==  ] ", "[=== ] ", "[ ===] ", "[  ==] ", "[   =] " };
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    const frame = frames[(now_ms / 120) % frames.len];
    const minutes = elapsed_secs / 60;
    const seconds = elapsed_secs % 60;

    const result = if (minutes == 0)
        std.fmt.bufPrint(&loadingBuf, "{s}({d}s) ", .{ frame, elapsed_secs }) catch return frame
    else
        std.fmt.bufPrint(&loadingBuf, "{s}({d}m {d}s) ", .{ frame, minutes, seconds }) catch return frame;
    return result;
}

pub fn wakeLoop(loop: *EventLoop) void {
    loop.postEvent(.{ .winsize = .{
        .rows = loop.vaxis.screen.height,
        .cols = loop.vaxis.screen.width,
        .x_pixel = 0,
        .y_pixel = 0,
    } });
}

pub fn spinnerThread(app: *App, loop: *EventLoop, spinner_state: *SpinnerState, generation: u64) void {
    while (spinner_state.generation.load(.acquire) == generation) {
        app.mutex.lock();
        const still_loading = app.is_loading;
        if (still_loading) app.needs_redraw = true;
        app.mutex.unlock();

        if (!still_loading) break;
        wakeLoop(loop);
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}

pub fn renderTools(alloc: std.mem.Allocator, win: vaxis.Window, screen_w: u16, preview_y: u16, preview_h: u16, app: *const App, preview_scroll: usize) void {
    const show_grep_panel = !app.tool_confirmation.pending and app.grep_status.pattern.len > 0;
    const show_glob_panel = !app.tool_confirmation.pending and app.glob_status.pattern.len > 0;
    const show_web_panel = !app.tool_confirmation.pending and app.web_status.label.len > 0;

    if (!(app.tool_confirmation.pending or show_grep_panel or show_glob_panel or show_web_panel)) return;

    const is_write = std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file");
    const is_bash = std.mem.eql(u8, app.tool_confirmation.tool_name, "bash");
    const is_web_preview = if (app.tool_confirmation.pending)
        std.mem.eql(u8, app.tool_confirmation.tool_name, "web_search") or std.mem.eql(u8, app.tool_confirmation.tool_name, "web_extract")
    else
        show_web_panel;
    const is_search_preview = if (app.tool_confirmation.pending)
        std.mem.eql(u8, app.tool_confirmation.tool_name, "grep") or std.mem.eql(u8, app.tool_confirmation.tool_name, "glob") or is_web_preview
    else
        show_grep_panel or show_glob_panel or show_web_panel;
    const is_grep = if (app.tool_confirmation.pending)
        std.mem.eql(u8, app.tool_confirmation.tool_name, "grep")
    else
        show_grep_panel;
    const preview_path = if (is_web_preview) app.web_status.label else if (is_grep) app.grep_status.path else app.glob_status.path;

    const preview_win = win.child(.{
        .x_off = 0,
        .y_off = preview_y,
        .width = screen_w,
        .height = preview_h,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    const title = std.fmt.allocPrint(alloc, " {s} {s} ", .{
        if (is_bash) "Run:" else if (is_search_preview) (if (is_web_preview) "Web Tool:" else if (is_grep) "Grep Tool (params):" else "Glob Tool (params):") else if (is_write) "New file:" else "Editing:",
        if (is_search_preview) preview_path else app.tool_confirmation.file_path,
    }) catch " Preview ";
    _ = preview_win.printSegment(.{
        .text = title,
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true, .bg = .{ .rgb = .{ 0x30, 0x60, 0xA0 } } },
    }, .{ .row_offset = 0, .col_offset = 1 });

    const sel_row = preview_win.height -| 3;
    const preview_content_end = sel_row;

    if (is_search_preview) {
        if (is_web_preview) {} else {
            var grep_row: u16 = 1;
            const pattern = if (is_grep) app.grep_status.pattern else app.glob_status.pattern;
            if (pattern.len > 0) {
                const grep_pattern = std.fmt.allocPrint(alloc, " pattern: {s}", .{pattern}) catch " pattern: ";
                _ = preview_win.printSegment(.{
                    .text = grep_pattern,
                    .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xFF, 0xCC } } },
                }, .{ .row_offset = grep_row, .col_offset = 1 });
                grep_row += 1;
            }
            if (preview_path.len > 0) {
                const grep_path = std.fmt.allocPrint(alloc, " path: {s}", .{preview_path}) catch " path: .";
                _ = preview_win.printSegment(.{
                    .text = grep_path,
                    .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xFF } } },
                }, .{ .row_offset = grep_row, .col_offset = 1 });
                grep_row += 1;
            }
            if (is_grep and app.grep_status.include.len > 0) {
                const grep_include = std.fmt.allocPrint(alloc, " include: {s}", .{app.grep_status.include}) catch " include: ";
                _ = preview_win.printSegment(.{
                    .text = grep_include,
                    .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xE0, 0xA0 } } },
                }, .{ .row_offset = grep_row, .col_offset = 1 });
                grep_row += 1;
            }

            _ = preview_win.printSegment(.{
                .text = if (is_grep) " Searching with current grep parameters..." else " Searching with current glob parameters...",
                .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
            }, .{ .row_offset = grep_row + 1, .col_offset = 1 });
        }
    } else if (is_bash) {
        _ = preview_win.printSegment(.{
            .text = " Do you want to proceed?",
            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = 2, .col_offset = 1 });
    } else if (is_write) {
        var line_iter = std.mem.splitScalar(u8, app.tool_confirmation.content, '\n');
        var line_idx: usize = 0;
        var prow: u16 = 1;
        while (line_iter.next()) |line| {
            if (prow >= preview_content_end) break;
            if (line_idx >= preview_scroll) {
                _ = preview_win.printSegment(.{
                    .text = line,
                    .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xFF, 0xCC } } },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            line_idx += 1;
        }
    } else {
        var prow: u16 = 1;
        var line_idx: usize = 0;
        var old_iter = std.mem.splitScalar(u8, app.tool_confirmation.old_string, '\n');
        while (old_iter.next()) |line| {
            if (prow >= preview_content_end) break;
            if (line_idx >= preview_scroll) {
                const diff_line = std.fmt.allocPrint(alloc, "- {s}", .{line}) catch line;
                _ = preview_win.printSegment(.{
                    .text = diff_line,
                    .style = .{ .fg = .{ .rgb = .{ 0xFF, 0x60, 0x60 } } },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            line_idx += 1;
        }
        var new_iter = std.mem.splitScalar(u8, app.tool_confirmation.new_string, '\n');
        while (new_iter.next()) |line| {
            if (prow >= preview_content_end) break;
            if (line_idx >= preview_scroll) {
                const diff_line = std.fmt.allocPrint(alloc, "+ {s}", .{line}) catch line;
                _ = preview_win.printSegment(.{
                    .text = diff_line,
                    .style = .{ .fg = .{ .rgb = .{ 0x60, 0xFF, 0x60 } } },
                }, .{ .row_offset = prow, .col_offset = 1 });
                prow += 1;
            }
            line_idx += 1;
        }
    }

    if (app.tool_confirmation.pending) {
        const confirm_options = [_]struct { label: []const u8, action: @TypeOf(app.tool_confirmation.cursor) }{
            .{ .label = "1. Yes", .action = .approve },
            .{ .label = "2. No", .action = .deny },
            .{ .label = "3. Accept all", .action = .accept_all },
        };
        for (confirm_options, 0..) |opt, idx| {
            const selected = app.tool_confirmation.cursor == opt.action;
            const text = std.fmt.allocPrint(alloc, "{s}{s}", .{ if (selected) " ❯ " else "   ", opt.label }) catch opt.label;
            _ = preview_win.printSegment(.{
                .text = text,
                .style = .{ .fg = if (selected) vaxis.Color{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else vaxis.Color{ .rgb = .{ 0x88, 0x88, 0x88 } }, .bold = selected },
            }, .{ .row_offset = sel_row + @as(u16, @intCast(idx)), .col_offset = 1 });
        }
    }
}

pub fn renderStatus(
    win: vaxis.Window,
    screen_w: u16,
    status_row: u16,
    app: *App,
    model: []const u8,
    effort: agent.llm.message.Effort,
    app_version: []const u8,
    clipboard_status: ?[]const u8,
) void {
    const status_bg: vaxis.Color = .{ .rgb = .{ 0x40, 0x40, 0x40 } };
    var status_buf: [128]u8 = undefined;
    var status_right_reserved: u16 = 0;
    const mode_label = switch (app.mode) {
        .chat => " CHAT ",
        .plan => " PLAN ",
    };

    const version_text = std.fmt.bufPrint(&status_buf, " {s} ", .{app_version}) catch " ? ";
    const version_col = screen_w -| @as(u16, @intCast(version_text.len)) -| 1;
    status_right_reserved = @as(u16, @intCast(version_text.len));

    _ = win.printSegment(.{
        .text = mode_label,
        .style = .{ .bg = .{ .rgb = .{ 0x30, 0x30, 0x30 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = 0 });

    var res = win.printSegment(.{
        .text = std.fmt.bufPrint(&status_buf, " {s} ", .{model}) catch " ? ",
        .style = .{ .bg = .{ .rgb = .{ 0x20, 0x60, 0xA0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = @as(u16, @intCast(mode_label.len + 1)) });

    if (app.tool_confirmation.cursor == .accept_all) {
        const badge = " accept-all  ctrl+a to reset ";
        const badge_col = screen_w -| @as(u16, @intCast(badge.len)) -| 1;
        status_right_reserved = @max(status_right_reserved, @as(u16, @intCast(badge.len)));
        _ = win.printSegment(.{
            .text = badge,
            .style = .{ .bg = .{ .rgb = .{ 0x20, 0x80, 0x40 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = badge_col });
    }

    if (effort != .none) {
        var effort_buf: [32]u8 = undefined;
        const effort_text = std.fmt.bufPrint(&effort_buf, " {s} ", .{effort.label()}) catch " ? ";
        const effort_col = version_col -| @as(u16, @intCast(effort_text.len));
        status_right_reserved = @max(status_right_reserved, @as(u16, @intCast(version_text.len + effort_text.len)));
        _ = win.printSegment(.{
            .text = effort_text,
            .style = .{ .bg = .{ .rgb = .{ 0x60, 0x30, 0xA0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = effort_col });
    }

    var info_buf: [128]u8 = undefined;
    const info_text = if (app.tool_status) |tool|
        std.fmt.bufPrint(&info_buf, " TOOL: {s} ", .{tool}) catch " TOOL "
    else if (app.is_loading)
        " THINKING "
    else
        " READY ";
    res = win.printSegment(.{
        .text = info_text,
        .style = .{ .bg = status_bg, .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
    }, .{ .row_offset = status_row, .col_offset = res.col });

    var footer_buf: [128]u8 = undefined;
    const footer_text = if (clipboard_status) |status|
        std.fmt.bufPrint(&footer_buf, "{s}  ctrl+q: quit", .{status}) catch " ctrl+q: quit"
    else
        " ctrl+q: quit";
    res = win.printSegment(.{
        .text = footer_text,
        .style = .{ .bg = status_bg, .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
    }, .{ .row_offset = status_row, .col_offset = res.col });
    app.context_usage.render(win, res.col, status_row, status_bg);

    if (version_col > res.col and version_col >= status_right_reserved) {
        _ = win.printSegment(.{
            .text = version_text,
            .style = .{ .bg = status_bg, .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } } },
        }, .{ .row_offset = status_row, .col_offset = version_col });
    }
}

test "wrapText handles newlines" {
    const result = wrapText("hello\nworld", 80, 10);
    try std.testing.expectEqualStrings("hello", result[0].?);
    try std.testing.expectEqualStrings("world", result[1].?);
    try std.testing.expect(result[2] == null);
}

test "wrapText handles empty lines" {
    const result = wrapText("a\n\nb", 80, 10);
    try std.testing.expectEqualStrings("a", result[0].?);
    try std.testing.expectEqualStrings("", result[1].?);
    try std.testing.expectEqualStrings("b", result[2].?);
}

test "wrapText wraps long lines" {
    const result = wrapText("hello world foo", 5, 10);
    try std.testing.expectEqualStrings("hello", result[0].?);
    try std.testing.expectEqualStrings("world", result[1].?);
    try std.testing.expectEqualStrings("foo", result[2].?);
}

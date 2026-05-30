const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig").App;
const image_attach = @import("image_attach.zig");
const attach_preview = @import("attach_preview.zig");
const chat_selection = @import("chat_selection.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const SpinnerState = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const InputLine = struct {
    start: usize,
    end: usize,
};

pub const InputView = struct {
    lines: []const InputLine,
    cursor_row: usize,
    cursor_col: usize,
    visible_start: usize,
    visible_count: usize,
    box_h: u16,
};

pub const InputLayout = struct {
    prompt: []const u8,
    view: InputView,
};

const max_input_body_lines: usize = 6;

const InputViewLineLengths = struct {
    view: InputView,

    pub fn lineLen(self: InputViewLineLengths, line_idx: usize) usize {
        const line = self.view.lines[line_idx];
        return line.end - line.start;
    }
};

fn buildInputLines(
    alloc: std.mem.Allocator,
    input: []const u8,
    first_width: usize,
    rest_width: usize,
) ![]const InputLine {
    var lines = std.ArrayList(InputLine){};
    errdefer lines.deinit(alloc);

    const first_limit = @max(first_width, 1);
    const next_limit = @max(rest_width, 1);
    var limit = first_limit;
    var line_start: usize = 0;
    var col: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\n') {
            try lines.append(alloc, .{ .start = line_start, .end = i });
            line_start = i + 1;
            col = 0;
            limit = next_limit;
            i += 1;
            continue;
        }

        if (col == limit) {
            try lines.append(alloc, .{ .start = line_start, .end = i });
            line_start = i;
            col = 0;
            limit = next_limit;
            continue;
        }

        col += 1;
        i += 1;
    }

    try lines.append(alloc, .{ .start = line_start, .end = input.len });
    return lines.toOwnedSlice(alloc);
}

fn cursorCell(input: []const u8, cursor_pos: usize, first_width: usize, rest_width: usize) struct { row: usize, col: usize } {
    const first_limit = @max(first_width, 1);
    const next_limit = @max(rest_width, 1);
    var limit = first_limit;
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;

    while (i < cursor_pos and i < input.len) {
        if (input[i] == '\n') {
            row += 1;
            col = 0;
            limit = next_limit;
            i += 1;
            continue;
        }

        if (col == limit) {
            row += 1;
            col = 0;
            limit = next_limit;
            continue;
        }

        col += 1;
        i += 1;
    }

    if (cursor_pos < input.len and input[cursor_pos] != '\n' and col == limit) {
        row += 1;
        col = 0;
    }

    return .{ .row = row, .col = col };
}

pub fn buildInputView(
    alloc: std.mem.Allocator,
    input: []const u8,
    prompt: []const u8,
    screen_width: u16,
    cursor_pos: usize,
) !InputView {
    const inner_width: usize = if (screen_width > 2) @intCast(screen_width - 2) else 1;
    const first_width: usize = if (prompt.len < inner_width) inner_width - prompt.len else 1;
    const rest_width: usize = inner_width;
    const lines = try buildInputLines(alloc, input, first_width, rest_width);
    errdefer alloc.free(lines);
    const cell = cursorCell(input, cursor_pos, first_width, rest_width);
    const visible_count: usize = @max(@as(usize, 1), @min(lines.len, max_input_body_lines));
    const visible_start = @min(if (cell.row + 1 > visible_count) cell.row + 1 - visible_count else 0, lines.len -| visible_count);

    return .{
        .lines = lines,
        .cursor_row = cell.row,
        .cursor_col = cell.col,
        .visible_start = visible_start,
        .visible_count = visible_count,
        .box_h = @as(u16, @intCast(visible_count + 2)),
    };
}

pub fn buildInputLayout(
    alloc: std.mem.Allocator,
    app: *App,
    input: []const u8,
    screen_width: u16,
    cursor_pos: usize,
) InputLayout {
    const prompt = if (app.is_loading)
        loading(app.getElapsedSeconds() orelse 0)
    else switch (app.mode) {
        .shell => "! ",
        else => "> ",
    };
    const fallback: InputView = .{
        .lines = &.{},
        .cursor_row = 0,
        .cursor_col = 0,
        .visible_start = 0,
        .visible_count = 1,
        .box_h = 3,
    };
    var view = buildInputView(alloc, input, prompt, screen_width, cursor_pos) catch fallback;
    if (app.pending_attachments.items.len > 0) view.box_h += 1;
    return .{
        .prompt = prompt,
        .view = view,
    };
}

pub fn renderInput(
    input_win: vaxis.Window,
    prompt: []const u8,
    input: []const u8,
    cursor_pos: usize,
    view: InputView,
    app: *App,
    selection_bounds: ?chat_selection.InputSelectionBounds,
) void {
    const show_prompt = view.visible_start == 0;
    var prompt_width: u16 = 0;
    if (show_prompt) {
        _ = input_win.printSegment(.{
            .text = prompt,
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });
        prompt_width = @intCast(prompt.len);

        var chip_col: u16 = 1 + prompt_width;
        var image_idx: u32 = 1;
        var file_idx: u32 = 1;
        var buf_off: usize = 0;
        for (app.pending_attachments.items) |path| {
            const is_image = image_attach.mimeFromPath(path) != null;
            const remaining = chipBuf[buf_off..];
            const chip = if (is_image)
                std.fmt.bufPrint(remaining, "[Image {d}]", .{image_idx}) catch "[Image]"
            else
                std.fmt.bufPrint(remaining, "{s}", .{path}) catch path;
            buf_off += chip.len;
            if (is_image) image_idx += 1 else file_idx += 1;
            const chip_style: vaxis.Style = if (is_image) .{
                .fg = .{ .rgb = .{ 0x00, 0x00, 0x00 } },
                .bg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } },
                .bold = true,
            } else .{};
            const r = input_win.printSegment(.{
                .text = chip,
                .style = chip_style,
            }, .{ .row_offset = 0, .col_offset = chip_col });
            chip_col = r.col;
            const r2 = input_win.printSegment(.{
                .text = " ",
                .style = .{},
            }, .{ .row_offset = 0, .col_offset = chip_col });
            chip_col = r2.col;
        }
        prompt_width = chip_col - 1;
    }

    const visible_end = @min(view.visible_start + view.visible_count, view.lines.len);
    for (view.lines[view.visible_start..visible_end], 0..) |line, row_idx| {
        const render_row: u16 = @intCast(row_idx);
        const logical_row = view.visible_start + row_idx;
        const line_text = input[line.start..line.end];
        const text_col: u16 = if (show_prompt and row_idx == 0)
            1 + prompt_width
        else
            1;
        const cursor_on_row = logical_row == view.cursor_row;
        const cursor_is_text = cursor_pos < input.len and input[cursor_pos] != '\n';
        const cursor_col = @min(view.cursor_col, line_text.len);

        if (cursor_on_row) {
            if (cursor_col > 0) {
                _ = input_win.printSegment(.{
                    .text = line_text[0..cursor_col],
                    .style = .{ .bold = true },
                }, .{ .row_offset = render_row, .col_offset = text_col });
            }

            const cursor_char: []const u8 = if (cursor_is_text and cursor_col < line_text.len) line_text[cursor_col .. cursor_col + 1] else " ";
            _ = input_win.printSegment(.{
                .text = cursor_char,
                .style = .{ .bold = true, .reverse = true },
            }, .{ .row_offset = render_row, .col_offset = text_col + @as(u16, @intCast(cursor_col)) });

            if (cursor_is_text) {
                if (cursor_col + 1 < line_text.len) {
                    _ = input_win.printSegment(.{
                        .text = line_text[cursor_col + 1 ..],
                        .style = .{ .bold = true },
                    }, .{ .row_offset = render_row, .col_offset = text_col + @as(u16, @intCast(cursor_col)) + 1 });
                }
            }
        } else {
            _ = input_win.printSegment(.{
                .text = line_text,
                .style = .{ .bold = true },
            }, .{ .row_offset = render_row, .col_offset = text_col });
        }
    }

    if (selection_bounds) |bounds| {
        applyInputSelectionHighlight(input_win, prompt_width, view, bounds);
    }
}

fn inputTextCol(prompt_width: u16, visible_row: usize, visible_start: usize) u16 {
    return if (visible_start == 0 and visible_row == 0)
        1 + prompt_width
    else
        1;
}

pub fn inputPointFromMouse(
    mouse: vaxis.Mouse,
    input_win: vaxis.Window,
    prompt: []const u8,
    view: InputView,
    app: *App,
) ?chat_selection.InputTextPoint {
    const hit = vaxis.Window.hasMouse(input_win, mouse) orelse return null;
    const row: usize = @intCast(hit.row - input_win.y_off);
    if (row >= view.visible_count) return null;

    const line_idx = view.visible_start + row;
    if (line_idx >= view.lines.len) return null;

    const line = view.lines[line_idx];
    const line_len = line.end - line.start;
    if (line_len == 0) return null;

    const prompt_width = renderedPromptWidth(prompt, view, app);
    const text_col = inputTextCol(prompt_width, row, view.visible_start);
    const col: usize = @intCast(hit.col - input_win.x_off);
    const line_col = if (col <= text_col) 0 else @min(col - text_col, line_len - 1);

    return .{ .line = line_idx, .col = line_col };
}

pub fn handleInputMouseSelection(
    allocator: std.mem.Allocator,
    mouse: vaxis.Mouse,
    selection: *chat_selection.InputSelectionState,
    input_win: vaxis.Window,
    prompt: []const u8,
    input: []const u8,
    view: InputView,
    app: *App,
) !chat_selection.SelectionActionResult {
    switch (mouse.type) {
        .press => {
            var result: chat_selection.SelectionActionResult = .{ .clear_status = true };
            if (inputPointFromMouse(mouse, input_win, prompt, view, app)) |point| {
                selection.anchor = point;
                selection.focus = point;
                selection.dragging = true;
                result.needs_redraw = true;
            } else {
                const had_selection = selection.anchor != null or selection.focus != null;
                selection.clear();
                result.needs_redraw = had_selection;
            }
            return result;
        },
        .drag => {
            if (selection.dragging) {
                if (inputPointFromMouse(mouse, input_win, prompt, view, app)) |point| {
                    selection.focus = point;
                    return .{ .needs_redraw = true };
                }
            }
        },
        .release => {
            if (selection.dragging) {
                selection.dragging = false;
                if (inputPointFromMouse(mouse, input_win, prompt, view, app)) |point| {
                    selection.focus = point;
                }

                if (selection.bounds(InputViewLineLengths{ .view = view })) |bounds| {
                    const text = try selectedInputText(allocator, input, view, bounds);
                    if (text.len == 0) {
                        allocator.free(text);
                        return .{ .status = " nothing selected ", .needs_redraw = true };
                    }
                    return .{ .copied_text = text, .needs_redraw = true };
                }

                return .{ .status = " drag to copy ", .needs_redraw = true };
            }
        },
        else => {},
    }

    return .{};
}

pub fn inputSelectionBounds(
    selection: chat_selection.InputSelectionState,
    view: InputView,
) ?chat_selection.InputSelectionBounds {
    return selection.bounds(InputViewLineLengths{ .view = view });
}

fn renderedPromptWidth(prompt: []const u8, view: InputView, app: *App) u16 {
    if (view.visible_start != 0) return 0;

    var width: u16 = @intCast(prompt.len);
    for (app.pending_attachments.items) |path| {
        const is_image = image_attach.mimeFromPath(path) != null;
        width += if (is_image) "[Image 1] ".len else "[File 1] ".len;
    }
    return width;
}

fn inputSelectionRangeForLine(bounds: chat_selection.InputSelectionBounds, line_idx: usize, line_len: usize) ?struct { start: usize, end: usize } {
    if (line_len == 0) return null;
    if (line_idx < bounds.start.line or line_idx > bounds.end.line) return null;

    var start_col: usize = 0;
    var end_col: usize = line_len;

    if (bounds.start.line == bounds.end.line) {
        start_col = bounds.start.col;
        end_col = bounds.end.col;
    } else if (line_idx == bounds.start.line) {
        start_col = bounds.start.col;
    } else if (line_idx == bounds.end.line) {
        end_col = bounds.end.col;
    }

    start_col = @min(start_col, line_len);
    end_col = @min(end_col, line_len);
    if (start_col >= end_col) return null;

    return .{ .start = start_col, .end = end_col };
}

pub fn selectedInputText(
    allocator: std.mem.Allocator,
    input: []const u8,
    view: InputView,
    bounds: chat_selection.InputSelectionBounds,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var line_idx = bounds.start.line;
    while (line_idx <= bounds.end.line) : (line_idx += 1) {
        const line = view.lines[line_idx];
        const line_len = line.end - line.start;
        const range = inputSelectionRangeForLine(bounds, line_idx, line_len) orelse continue;

        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, input[line.start + range.start .. line.start + range.end]);
    }

    return out.toOwnedSlice(allocator);
}

fn applyInputSelectionHighlight(
    input_win: vaxis.Window,
    prompt_width: u16,
    view: InputView,
    bounds: chat_selection.InputSelectionBounds,
) void {
    const visible_end = @min(view.visible_start + view.visible_count, view.lines.len);
    for (view.lines[view.visible_start..visible_end], 0..) |line, row_idx| {
        const line_len = line.end - line.start;
        const range = inputSelectionRangeForLine(bounds, view.visible_start + row_idx, line_len) orelse continue;
        const text_col = inputTextCol(prompt_width, row_idx, view.visible_start);
        const start_col: u16 = @intCast(@as(usize, text_col) + range.start);
        const end_col: u16 = @intCast(@as(usize, text_col) + range.end);

        var col = start_col;
        while (col < end_col and col < input_win.width) : (col += 1) {
            var cell: vaxis.Cell = input_win.readCell(col, @intCast(row_idx)) orelse .{
                .char = .{ .grapheme = " ", .width = 1 },
            };
            cell.style.reverse = true;
            input_win.writeCell(col, @intCast(row_idx), cell);
        }
    }
}

var loadingBuf: [32]u8 = undefined;
var chipBuf: [512]u8 = undefined;

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

pub fn renderHeader(win: vaxis.Window, cwd: []const u8) void {
    const title = " Zigent - AI Coding Agent ";
    _ = win.printSegment(.{
        .text = title,
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = 0, .col_offset = 0 });
    _ = win.printSegment(.{
        .text = cwd,
        .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
    }, .{ .row_offset = 0, .col_offset = @intCast(title.len) });
}

pub fn renderChatLines(chat_win: vaxis.Window, rendered_lines: anytype, scroll_offset: usize) usize {
    const chat_h = chat_win.height;
    const total_lines = rendered_lines.len;
    const start = if (scroll_offset < total_lines) scroll_offset else 0;

    var row: u16 = 0;
    for (rendered_lines[start..total_lines]) |line| {
        if (row >= chat_h) break;
        switch (line.entry) {
            .plain => |p| {
                if (p.is_first) {
                    const color: [3]u8 = if (std.mem.eql(u8, p.prefix, "AI: ")) .{ 0x60, 0xA0, 0xF0 } else .{ 0x60, 0xD0, 0x60 };
                    _ = chat_win.printSegment(.{
                        .text = p.prefix,
                        .style = .{ .fg = .{ .rgb = color }, .bold = true },
                    }, .{ .row_offset = row, .col_offset = 1 });
                }
                const prefix_len = @as(u16, @intCast(p.prefix.len));
                if (p.text.len > 0) {
                    _ = chat_win.printSegment(.{ .text = p.text }, .{ .row_offset = row, .col_offset = 1 + prefix_len });
                }
            },
            .styled => |sline| {
                if (sline.block_bg) |bg| {
                    var c: u16 = 1;
                    while (c < chat_win.width -| 1) : (c += 1) {
                        chat_win.writeCell(c, row, .{
                            .char = .{ .grapheme = " ", .width = 1 },
                            .style = .{ .bg = bg },
                        });
                    }
                }

                var col: u16 = 1 + sline.indent;
                for (sline.spans) |span| {
                    var style = span.style;
                    if (sline.block_bg) |bg| style.bg = bg;
                    const result = chat_win.printSegment(.{
                        .text = span.text,
                        .style = style,
                    }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
                    col = result.col;
                }
            },
            .thinking => |th| {
                if (th.is_header) {
                    _ = chat_win.printSegment(.{
                        .text = "Thinking:",
                        .style = .{ .fg = .{ .rgb = .{ 0xCC, 0x80, 0x30 } }, .italic = true, .bold = true },
                    }, .{ .row_offset = row, .col_offset = 2 });
                } else if (th.text.len > 0) {
                    _ = chat_win.printSegment(.{
                        .text = th.text,
                        .style = .{ .fg = .{ .rgb = .{ 0x77, 0x77, 0x77 } } },
                    }, .{ .row_offset = row, .col_offset = 2 });
                }
            },
            .notice => |notice| {
                _ = chat_win.printSegment(.{
                    .text = notice.text,
                    .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
                }, .{ .row_offset = row, .col_offset = line.start_col });
            },
        }
        row += 1;
    }

    return start;
}

pub fn renderTools(alloc: std.mem.Allocator, win: vaxis.Window, screen_w: u16, preview_y: u16, preview_h: u16, app: *const App, preview_scroll: usize) void {
    const show_grep_panel = !app.tool_confirmation.pending and app.grep_status.pattern.len > 0;
    const show_glob_panel = !app.tool_confirmation.pending and app.glob_status.pattern.len > 0;
    const show_web_panel = !app.tool_confirmation.pending and app.web_status.label.len > 0;

    if (!(app.tool_confirmation.pending or show_grep_panel or show_glob_panel or show_web_panel)) return;

    const is_write = std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file");
    const is_bash = std.mem.eql(u8, app.tool_confirmation.tool_name, "bash");
    const is_mcp = std.mem.startsWith(u8, app.tool_confirmation.tool_name, "mcp__");
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
        if (is_bash) "Run:" else if (is_mcp) "MCP Tool:" else if (is_search_preview) (if (is_web_preview) "Web Tool:" else if (is_grep) "Grep Tool (params):" else "Glob Tool (params):") else if (is_write) "New file:" else "Editing:",
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
    } else if (is_mcp) {
        var line_iter = std.mem.splitScalar(u8, app.tool_confirmation.content, '\n');
        var line_idx: usize = 0;
        var prow: u16 = 1;
        while (line_iter.next()) |line| {
            if (prow >= preview_content_end) break;
            if (line_idx >= preview_scroll) {
                _ = preview_win.printSegment(.{
                    .text = line,
                    .style = .{ .fg = .{ .rgb = .{ 0xA0, 0xD0, 0xFF } } },
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
    show_exit: bool,
) void {
    var status_right_reserved: u16 = 0;
    const mode_label = app.mode.label();
    const version_text_len: u16 = @intCast(app_version.len + 2);

    const version_col = screen_w -| version_text_len -| 1;
    status_right_reserved = version_text_len;

    _ = win.printSegment(.{
        .text = mode_label,
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = 0 });

    var res = win.printSegment(.{
        .text = " ",
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = @as(u16, @intCast(mode_label.len + 1)) });
    res = win.printSegment(.{
        .text = model,
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = res.col });
    res = win.printSegment(.{
        .text = " ",
        .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
    }, .{ .row_offset = status_row, .col_offset = res.col });

    if (app.tool_confirmation.cursor == .accept_all) {
        const badge = " accept-all  ctrl+a to reset ";
        const badge_col = screen_w -| @as(u16, @intCast(badge.len)) -| 1;
        status_right_reserved = @max(status_right_reserved, @as(u16, @intCast(badge.len)));
        _ = win.printSegment(.{
            .text = badge,
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = badge_col });
    }

    if (effort != .none) {
        const effort_label = effort.label();
        const effort_text_len: u16 = @intCast(effort_label.len + 2);
        const effort_col = version_col -| effort_text_len;
        status_right_reserved = @max(status_right_reserved, version_text_len + effort_text_len);
        var effort_res = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = effort_col });
        effort_res = win.printSegment(.{
            .text = effort_label,
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = effort_res.col });
        _ = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = effort_res.col });
    }

    if (app.tool_status) |tool| {
        res = win.printSegment(.{
            .text = " TOOL: ",
            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
        res = win.printSegment(.{
            .text = tool,
            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
        res = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
    } else {
        res = win.printSegment(.{
            .text = if (app.is_loading) " THINKING " else " READY ",
            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
    }

    if (clipboard_status) |status| {
        res = win.printSegment(.{
            .text = status,
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
        res = win.printSegment(.{
            .text = "  ctrl+q: quit",
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
    } else {
        res = win.printSegment(.{
            .text = " ctrl+q: quit",
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
    }
    if (show_exit) {
        res = win.printSegment(.{
            .text = "  ctrl+c again to exit ",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0x88 } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });
    }
    app.context_usage.render(win, res.col, status_row, .default);

    if (version_col > res.col and version_col >= status_right_reserved) {
        var version_res = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } } },
        }, .{ .row_offset = status_row, .col_offset = version_col });
        version_res = win.printSegment(.{
            .text = app_version,
            .style = .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } } },
        }, .{ .row_offset = status_row, .col_offset = version_res.col });
        _ = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } } },
        }, .{ .row_offset = status_row, .col_offset = version_res.col });
    }
}

pub fn renderAttachPreview(
    alloc: std.mem.Allocator,
    win: vaxis.Window,
    screen_w: u16,
    preview_y: u16,
    preview_h: u16,
    app: *const App,
    pending_images: []const attach_preview.PendingImage,
    show_images: bool,
    preview_scroll: usize,
) void {
    if (preview_h == 0 or app.pending_attachments.items.len == 0) return;
    if (app.tool_confirmation.pending) return;
    if (app.grep_status.pattern.len > 0) return;
    if (app.glob_status.pattern.len > 0) return;
    if (app.web_status.label.len > 0) return;

    const box = win.child(.{
        .x_off = 0,
        .y_off = preview_y,
        .width = screen_w,
        .height = preview_h,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    _ = box.printSegment(.{
        .text = " Attachments ",
        .style = .{
            .fg = .{ .rgb = .{ 0x00, 0x00, 0x00 } },
            .bg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } },
            .bold = true,
        },
    }, .{ .row_offset = 0, .col_offset = 1 });

    const inner_h: u16 = if (box.height > 2) box.height - 2 else 0;
    const lines = attach_preview.build(alloc, app.pending_attachments.items, show_images) catch return;

    var total_rows: usize = 0;
    for (lines) |l| total_rows += switch (l.kind) {
        .image => attach_preview.image_preview_rows,
        else => 1,
    };
    const max_scroll: usize = if (total_rows > inner_h) total_rows - inner_h else 0;
    const effective_scroll: usize = @min(preview_scroll, max_scroll);

    var row_index: usize = 0;
    var row: u16 = 1;
    for (lines) |line| {
        const block_rows: u16 = switch (line.kind) {
            .image => attach_preview.image_preview_rows,
            else => 1,
        };

        if (row_index + block_rows <= effective_scroll) {
            row_index += block_rows;
            continue;
        }

        if (row > inner_h) break;
        if (line.kind == .image) {
            const remaining = inner_h - row + 1;
            const skipped_rows = effective_scroll -| row_index;
            const image_h = @min(attach_preview.image_preview_rows -| @as(u16, @intCast(skipped_rows)), remaining);
            if (image_h == 0) {
                row_index += attach_preview.image_preview_rows;
                continue;
            }
            const image_win = box.child(.{
                .x_off = 1,
                .y_off = row,
                .width = box.width -| 2,
                .height = image_h,
            });

            if (attach_preview.findPendingImage(pending_images, line.text)) |pending_image| {
                pending_image.image.draw(image_win, .{ .scale = .contain }) catch {
                    _ = box.printSegment(.{
                        .text = "   [image preview unavailable]",
                        .style = .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } }, .italic = true },
                    }, .{ .row_offset = row, .col_offset = 1 });
                    row += 1;
                    row_index += attach_preview.image_preview_rows;
                    continue;
                };
            } else {
                _ = box.printSegment(.{
                    .text = "   [loading image preview]",
                    .style = .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } }, .italic = true },
                }, .{ .row_offset = row, .col_offset = 1 });
                row += 1;
                row_index += attach_preview.image_preview_rows;
                continue;
            }

            row += image_h;
            row_index += attach_preview.image_preview_rows;
            continue;
        }
        const style: vaxis.Style = switch (line.kind) {
            .header => .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
            .placeholder => .{ .fg = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } }, .italic = true },
            .content => .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
            .image => unreachable,
        };
        _ = box.printSegment(.{ .text = line.text, .style = style }, .{ .row_offset = row, .col_offset = 1 });
        row += 1;
        row_index += 1;
    }
}

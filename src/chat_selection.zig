const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig");
const ui = @import("ui.zig");

const Allocator = std.mem.Allocator;
const WidthMethod = vaxis.gwidth.Method;

pub const PlainRenderedLine = struct {
    text: []const u8,
    prefix: []const u8,
    is_first: bool,
};

pub const RenderedLine = struct {
    text: []const u8,
    display_cols: usize,
    start_col: u16 = 1,
    entry: union(enum) {
        plain: PlainRenderedLine,
        styled: agent.markdown.StyledLine,
    },
};

pub const TextPoint = struct {
    line: usize,
    col: usize,
};

pub const SelectionBounds = struct {
    start: TextPoint,
    end: TextPoint,
};

pub const LineSelectionRange = struct {
    start: usize,
    end: usize,
};

pub const SelectionState = struct {
    anchor: ?TextPoint = null,
    focus: ?TextPoint = null,
    dragging: bool = false,

    pub fn clear(self: *SelectionState) void {
        self.anchor = null;
        self.focus = null;
        self.dragging = false;
    }

    pub fn bounds(self: SelectionState, lines: []const RenderedLine) ?SelectionBounds {
        const anchor = self.anchor orelse return null;
        const focus = self.focus orelse return null;
        const ordering = compareTextPoints(anchor, focus);
        if (ordering == .eq) return null;

        if (ordering == .lt) {
            return .{
                .start = anchor,
                .end = exclusivePoint(focus, lines),
            };
        }

        return .{
            .start = focus,
            .end = exclusivePoint(anchor, lines),
        };
    }
};

fn compareTextPoints(a: TextPoint, b: TextPoint) std.math.Order {
    if (a.line < b.line) return .lt;
    if (a.line > b.line) return .gt;
    if (a.col < b.col) return .lt;
    if (a.col > b.col) return .gt;
    return .eq;
}

fn exclusivePoint(point: TextPoint, lines: []const RenderedLine) TextPoint {
    const line = lines[point.line];
    return .{
        .line = point.line,
        .col = @min(point.col + 1, line.display_cols),
    };
}

pub fn buildRenderedLines(
    app: *App,
    allocator: Allocator,
    chat_width: u16,
    width_method: WidthMethod,
) ![]RenderedLine {
    var lines = std.ArrayList(RenderedLine){};
    defer lines.deinit(allocator);

    for (app.messages.items) |*msg| {
        if (msg.role == .assistant) {
            const ai_label = try buildPlainLineText(allocator, "AI: ", "", true);
            try lines.append(allocator, .{
                .text = ai_label,
                .display_cols = displayWidth(ai_label, width_method),
                .entry = .{ .plain = .{
                    .text = "",
                    .prefix = "AI: ",
                    .is_first = true,
                } },
            });

            const styled = app.getStyledLines(msg) catch &.{};
            for (styled) |sline| {
                const rendered = try buildStyledLineText(allocator, sline);
                try lines.append(allocator, .{
                    .text = rendered,
                    .display_cols = displayWidth(rendered, width_method),
                    .entry = .{ .styled = sline },
                });
            }
        } else {
            const prefix = "You: ";
            const prefix_len = @as(u16, @intCast(prefix.len));
            const user_wrap_w = if (chat_width > prefix_len + 3) chat_width - prefix_len - 3 else 10;
            const wrapped = ui.wrapText(msg.content, user_wrap_w, 512);

            for (wrapped, 0..) |maybe_line, li| {
                const line = maybe_line orelse break;
                const is_first = li == 0;
                const rendered = try buildPlainLineText(allocator, prefix, line, is_first);
                try lines.append(allocator, .{
                    .text = rendered,
                    .display_cols = displayWidth(rendered, width_method),
                    .entry = .{ .plain = .{
                        .text = line,
                        .prefix = prefix,
                        .is_first = is_first,
                    } },
                });
            }
        }
    }

    return lines.toOwnedSlice(allocator);
}

fn buildPlainLineText(allocator: Allocator, prefix: []const u8, text: []const u8, is_first: bool) ![]const u8 {
    const rendered = try allocator.alloc(u8, prefix.len + text.len);
    if (is_first) {
        @memcpy(rendered[0..prefix.len], prefix);
    } else {
        @memset(rendered[0..prefix.len], ' ');
    }
    @memcpy(rendered[prefix.len..], text);
    return rendered;
}

fn buildStyledLineText(allocator: Allocator, line: agent.markdown.StyledLine) ![]const u8 {
    var total_len: usize = line.indent;
    for (line.spans) |span| total_len += span.text.len;

    const rendered = try allocator.alloc(u8, total_len);
    @memset(rendered[0..line.indent], ' ');

    var offset: usize = line.indent;
    for (line.spans) |span| {
        @memcpy(rendered[offset .. offset + span.text.len], span.text);
        offset += span.text.len;
    }

    return rendered;
}

fn displayWidth(text: []const u8, width_method: WidthMethod) usize {
    return @intCast(vaxis.gwidth.gwidth(text, width_method));
}

pub fn pointFromMouse(
    mouse: vaxis.Mouse,
    chat_win: vaxis.Window,
    scroll_offset: usize,
    rendered_lines: []const RenderedLine,
) ?TextPoint {
    const hit = vaxis.Window.hasMouse(chat_win, mouse) orelse return null;
    const row: usize = @intCast(hit.row - chat_win.y_off);
    const line_idx = scroll_offset + row;
    if (line_idx >= rendered_lines.len) return null;

    const line = rendered_lines[line_idx];
    if (line.display_cols == 0) return null;

    const col: usize = @intCast(hit.col - chat_win.x_off);
    const line_col = if (col <= line.start_col) 0 else @min(col - line.start_col, line.display_cols - 1);

    return .{ .line = line_idx, .col = line_col };
}

pub fn selectionRangeForLine(bounds: SelectionBounds, line_idx: usize, display_cols: usize) ?LineSelectionRange {
    if (display_cols == 0) return null;
    if (line_idx < bounds.start.line or line_idx > bounds.end.line) return null;

    var start_col: usize = 0;
    var end_col: usize = display_cols;

    if (bounds.start.line == bounds.end.line) {
        start_col = bounds.start.col;
        end_col = bounds.end.col;
    } else if (line_idx == bounds.start.line) {
        start_col = bounds.start.col;
    } else if (line_idx == bounds.end.line) {
        end_col = bounds.end.col;
    }

    start_col = @min(start_col, display_cols);
    end_col = @min(end_col, display_cols);
    if (start_col >= end_col) return null;

    return .{ .start = start_col, .end = end_col };
}

pub fn applySelectionHighlight(
    chat_win: vaxis.Window,
    row: u16,
    line: RenderedLine,
    range: LineSelectionRange,
) void {
    const start_col: u16 = @intCast(@as(usize, line.start_col) + range.start);
    const end_col: u16 = @intCast(@as(usize, line.start_col) + range.end);

    var col = start_col;
    while (col < end_col and col < chat_win.width) : (col += 1) {
        var cell: vaxis.Cell = chat_win.readCell(col, row) orelse .{
            .char = .{ .grapheme = " ", .width = 1 },
        };
        cell.style.reverse = true;
        chat_win.writeCell(col, row, cell);
    }
}

fn sliceByDisplayColumns(
    allocator: Allocator,
    text: []const u8,
    start_col: usize,
    end_col: usize,
    width_method: WidthMethod,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var col: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width = @max(1, vaxis.gwidth.gwidth(bytes, width_method));
        const next_col = col + width;

        if (next_col > start_col and col < end_col) {
            try out.appendSlice(allocator, bytes);
        }
        if (next_col >= end_col) break;
        col = next_col;
    }

    return out.toOwnedSlice(allocator);
}

pub fn selectedText(
    allocator: Allocator,
    lines: []const RenderedLine,
    bounds: SelectionBounds,
    width_method: WidthMethod,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var line_idx = bounds.start.line;
    while (line_idx <= bounds.end.line) : (line_idx += 1) {
        const range = selectionRangeForLine(bounds, line_idx, lines[line_idx].display_cols) orelse continue;
        const segment = try sliceByDisplayColumns(allocator, lines[line_idx].text, range.start, range.end, width_method);
        defer allocator.free(segment);

        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, segment);
    }

    return out.toOwnedSlice(allocator);
}

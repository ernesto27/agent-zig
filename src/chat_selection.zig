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

pub const ThinkingLine = struct {
    text: []const u8,
    is_header: bool,
};

pub const StyledRenderedLine = struct {
    spans: []const agent.markdown.StyledSpan,
    indent: u16,
    block_bg: ?vaxis.Cell.Color,
};

pub const RenderedLine = struct {
    text: []const u8,
    display_cols: usize,
    start_col: u16 = 1,
    entry: union(enum) {
        plain: PlainRenderedLine,
        styled: StyledRenderedLine,
        thinking: ThinkingLine,
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

            if (msg.thinking) |th| {
                // "Thinking:" header
                try lines.append(allocator, .{
                    .text = "Thinking:",
                    .display_cols = displayWidth("Thinking:", width_method),
                    .entry = .{ .thinking = .{ .text = "Thinking:", .is_header = true } },
                });
                // Wrapped thinking content
                const wrap_w = if (chat_width > 4) chat_width - 4 else 10;
                const wrapped = ui.wrapText(th, wrap_w, 512);
                for (wrapped) |maybe_line| {
                    const line = maybe_line orelse break;
                    const rendered = try allocator.dupe(u8, line);
                    try lines.append(allocator, .{
                        .text = rendered,
                        .display_cols = displayWidth(rendered, width_method),
                        .entry = .{ .thinking = .{ .text = line, .is_header = false } },
                    });
                }
                // Blank separator before response
                try lines.append(allocator, .{
                    .text = "",
                    .display_cols = 0,
                    .entry = .{ .thinking = .{ .text = "", .is_header = false } },
                });
            }

            const styled = app.getStyledLines(msg) catch &.{};
            const styled_wrap_w: usize = @max(1, @as(usize, chat_width) -| 2);
            for (styled) |sline| {
                const wrapped_lines = try wrapStyledLine(allocator, sline, styled_wrap_w, width_method);
                for (wrapped_lines) |wrapped_line| {
                    const rendered = try buildWrappedStyledLineText(allocator, wrapped_line);
                    try lines.append(allocator, .{
                        .text = rendered,
                        .display_cols = displayWidth(rendered, width_method),
                        .entry = .{ .styled = wrapped_line },
                    });
                }
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

fn buildWrappedStyledLineText(allocator: Allocator, line: StyledRenderedLine) ![]const u8 {
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

const StyledPiece = struct {
    text: []const u8,
    style: vaxis.Cell.Style,
    width: usize,
    is_space: bool,
};

fn wrapStyledLine(
    allocator: Allocator,
    line: agent.markdown.StyledLine,
    width: usize,
    width_method: WidthMethod,
) ![]const StyledRenderedLine {
    if (line.spans.len == 0) {
        const empty = try allocator.alloc(StyledRenderedLine, 1);
        empty[0] = .{
            .spans = try allocator.alloc(agent.markdown.StyledSpan, 0),
            .indent = line.indent,
            .block_bg = line.block_bg,
        };
        return empty;
    }

    var pieces = std.ArrayList(StyledPiece){};
    defer pieces.deinit(allocator);
    try collectStyledPieces(allocator, line.spans, width_method, &pieces);

    if (pieces.items.len == 0) {
        const empty = try allocator.alloc(StyledRenderedLine, 1);
        empty[0] = .{
            .spans = try allocator.alloc(agent.markdown.StyledSpan, 0),
            .indent = line.indent,
            .block_bg = line.block_bg,
        };
        return empty;
    }

    var wrapped = std.ArrayList(StyledRenderedLine){};
    defer wrapped.deinit(allocator);

    const available_width = @max(1, width -| line.indent);
    const prefer_word_breaks = line.block_bg == null;

    var line_start: usize = 0;
    var idx: usize = 0;
    while (idx < pieces.items.len) {
        var current_width: usize = 0;
        var last_space: ?usize = null;

        while (idx < pieces.items.len) : (idx += 1) {
            const piece = pieces.items[idx];
            const next_width = current_width + piece.width;
            if (current_width > 0 and next_width > available_width) break;
            current_width = next_width;
            if (prefer_word_breaks and piece.is_space) last_space = idx;
        }

        var line_end = idx;
        if (idx < pieces.items.len) {
            if (prefer_word_breaks) {
                if (last_space) |space_idx| {
                    if (space_idx > line_start) {
                        line_end = space_idx;
                        idx = space_idx + 1;
                        while (idx < pieces.items.len and pieces.items[idx].is_space) : (idx += 1) {}
                    }
                }
            }

            if (line_end == line_start) {
                line_end = @min(line_start + 1, pieces.items.len);
                idx = line_end;
            }
        }

        try wrapped.append(allocator, try makeWrappedStyledLine(allocator, line, pieces.items[line_start..line_end]));
        line_start = idx;
        while (line_start < pieces.items.len and pieces.items[line_start].is_space) : (line_start += 1) {}
        idx = line_start;
    }

    return wrapped.toOwnedSlice(allocator);
}

fn collectStyledPieces(
    allocator: Allocator,
    spans: []const agent.markdown.StyledSpan,
    width_method: WidthMethod,
    pieces: *std.ArrayList(StyledPiece),
) !void {
    for (spans) |span| {
        var iter = vaxis.unicode.graphemeIterator(span.text);
        while (iter.next()) |grapheme| {
            const bytes = grapheme.bytes(span.text);
            try pieces.append(allocator, .{
                .text = bytes,
                .style = span.style,
                .width = @max(1, vaxis.gwidth.gwidth(bytes, width_method)),
                .is_space = std.mem.eql(u8, bytes, " "),
            });
        }
    }
}

fn makeWrappedStyledLine(
    allocator: Allocator,
    original: agent.markdown.StyledLine,
    pieces: []const StyledPiece,
) !StyledRenderedLine {
    var spans = std.ArrayList(agent.markdown.StyledSpan){};
    defer spans.deinit(allocator);

    var current_style: ?vaxis.Cell.Style = null;
    var current_bytes = std.ArrayList(u8){};
    defer current_bytes.deinit(allocator);

    for (pieces) |piece| {
        if (current_style) |style| {
            if (!stylesEqual(style, piece.style)) {
                try spans.append(allocator, .{
                    .text = try current_bytes.toOwnedSlice(allocator),
                    .style = style,
                });
                current_bytes = std.ArrayList(u8){};
            }
        }

        if (current_style == null or !stylesEqual(current_style.?, piece.style)) {
            current_style = piece.style;
        }

        try current_bytes.appendSlice(allocator, piece.text);
    }

    if (current_style) |style| {
        try spans.append(allocator, .{
            .text = try current_bytes.toOwnedSlice(allocator),
            .style = style,
        });
    }

    return .{
        .spans = try spans.toOwnedSlice(allocator),
        .indent = original.indent,
        .block_bg = original.block_bg,
    };
}

fn stylesEqual(a: vaxis.Cell.Style, b: vaxis.Cell.Style) bool {
    return std.meta.eql(a, b);
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

test "wrapStyledLine wraps long assistant paragraph" {
    const allocator = std.testing.allocator;
    const width_method = std.enums.values(WidthMethod)[0];

    const spans = try allocator.alloc(agent.markdown.StyledSpan, 1);
    defer allocator.free(spans[0].text);
    defer allocator.free(spans);
    spans[0] = .{ .text = try allocator.dupe(u8, "hello world from zig"), .style = .{} };

    const wrapped = try wrapStyledLine(allocator, .{ .spans = spans, .indent = 0, .block_bg = null }, 8, width_method);
    defer {
        for (wrapped) |line| {
            for (line.spans) |span| allocator.free(span.text);
            allocator.free(line.spans);
        }
        allocator.free(wrapped);
    }

    try std.testing.expectEqual(@as(usize, 3), wrapped.len);
    try std.testing.expectEqualStrings("hello", wrapped[0].spans[0].text);
    try std.testing.expectEqualStrings("world", wrapped[1].spans[0].text);
    try std.testing.expectEqualStrings("from zig", wrapped[2].spans[0].text);
}

test "wrapStyledLine preserves indent and styles" {
    const allocator = std.testing.allocator;
    const width_method = std.enums.values(WidthMethod)[0];

    const spans = try allocator.alloc(agent.markdown.StyledSpan, 2);
    defer {
        allocator.free(spans[0].text);
        allocator.free(spans[1].text);
        allocator.free(spans);
    }
    spans[0] = .{ .text = try allocator.dupe(u8, "bold text"), .style = .{ .bold = true } };
    spans[1] = .{ .text = try allocator.dupe(u8, " tail"), .style = .{} };

    const wrapped = try wrapStyledLine(allocator, .{ .spans = spans, .indent = 2, .block_bg = null }, 8, width_method);
    defer {
        for (wrapped) |line| {
            for (line.spans) |span| allocator.free(span.text);
            allocator.free(line.spans);
        }
        allocator.free(wrapped);
    }

    try std.testing.expect(wrapped.len >= 2);
    try std.testing.expectEqual(@as(u16, 2), wrapped[0].indent);
    try std.testing.expect(wrapped[0].spans[0].style.bold);
}

const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;
const Style = vaxis.Cell.Style;
const Color = vaxis.Cell.Color;

// ── Colors ───────────────────────────────────────────────────────────

const style_h1: Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x60, 0xD0, 0xD0 } } };
const style_h2: Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x40, 0xA0, 0xC0 } } };
const style_h3: Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x80, 0x80, 0xC0 } } };
const style_bold: Style = .{ .bold = true };
const style_italic: Style = .{ .italic = true };
const style_bold_italic: Style = .{ .bold = true, .italic = true };
const style_inline_code: Style = .{
    .bg = .{ .rgb = .{ 0x3A, 0x3A, 0x3A } },
    .fg = .{ .rgb = .{ 0xFF, 0xA0, 0x60 } },
};
const style_code_text: Style = .{
    .fg = .{ .rgb = .{ 0xD0, 0xD0, 0xD0 } },
};
const code_bg: Color = .{ .rgb = .{ 0x1A, 0x1A, 0x2E } };
const style_bullet: Style = .{
    .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } },
    .bold = true,
};
const style_lang_label: Style = .{
    .fg = .{ .rgb = .{ 0x70, 0x70, 0x90 } },
    .italic = true,
};

// ── Public types ─────────────────────────────────────────────────────

pub const StyledSpan = struct {
    text: []const u8,
    style: Style,
};

pub const StyledLine = struct {
    spans: []const StyledSpan,
    indent: u16,
    block_bg: ?Color,
};

// ── Public API ───────────────────────────────────────────────────────

pub fn parse(allocator: Allocator, content: []const u8) ![]const StyledLine {
    if (content.len == 0) return try allocator.alloc(StyledLine, 0);

    var lines = std.ArrayListUnmanaged(StyledLine){};
    errdefer {
        for (lines.items) |line| freeLine(allocator, line);
        lines.deinit(allocator);
    }

    var in_code_block = false;
    var code_lang: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        // ── Code fence toggle ────────────────────────────────
        if (std.mem.startsWith(u8, raw_line, "```")) {
            if (!in_code_block) {
                in_code_block = true;
                const lang = std.mem.trim(u8, raw_line[3..], " \t\r");
                code_lang = if (lang.len > 0) lang else null;
                // Emit language label line
                if (code_lang) |l| {
                    var spans = std.ArrayListUnmanaged(StyledSpan){};
                    try appendSpan(allocator, &spans, l, style_lang_label);
                    try lines.append(allocator, .{
                        .spans = try spans.toOwnedSlice(allocator),
                        .indent = 2,
                        .block_bg = code_bg,
                    });
                }
            } else {
                in_code_block = false;
                code_lang = null;
            }
            continue;
        }

        // ── Inside code block ────────────────────────────────
        if (in_code_block) {
            var spans = std.ArrayListUnmanaged(StyledSpan){};
            if (raw_line.len > 0) {
                try appendSpan(allocator, &spans, raw_line, style_code_text);
            }
            try lines.append(allocator, .{
                .spans = try spans.toOwnedSlice(allocator),
                .indent = 2,
                .block_bg = code_bg,
            });
            continue;
        }

        // ── Heading ──────────────────────────────────────────
        if (parseHeading(raw_line)) |h| {
            var spans = std.ArrayListUnmanaged(StyledSpan){};
            const heading_style = switch (h.level) {
                1 => style_h1,
                2 => style_h2,
                else => style_h3,
            };
            try parseInlineSpans(allocator, &spans, h.text, heading_style);
            try lines.append(allocator, .{
                .spans = try spans.toOwnedSlice(allocator),
                .indent = 0,
                .block_bg = null,
            });
            continue;
        }

        // ── Bullet list ──────────────────────────────────────
        if (parseBullet(raw_line)) |b| {
            var spans = std.ArrayListUnmanaged(StyledSpan){};
            try appendSpan(allocator, &spans, "• ", style_bullet);
            try parseInlineSpans(allocator, &spans, b.text, .{});
            try lines.append(allocator, .{
                .spans = try spans.toOwnedSlice(allocator),
                .indent = @intCast(b.depth * 2),
                .block_bg = null,
            });
            continue;
        }

        // ── Numbered list ────────────────────────────────────
        if (parseNumbered(raw_line)) |n| {
            var spans = std.ArrayListUnmanaged(StyledSpan){};
            try appendSpan(allocator, &spans, n.prefix, style_bullet);
            try parseInlineSpans(allocator, &spans, n.text, .{});
            try lines.append(allocator, .{
                .spans = try spans.toOwnedSlice(allocator),
                .indent = @intCast(n.depth * 2),
                .block_bg = null,
            });
            continue;
        }

        // ── Normal paragraph line ────────────────────────────
        var spans = std.ArrayListUnmanaged(StyledSpan){};
        if (raw_line.len > 0) {
            try parseInlineSpans(allocator, &spans, raw_line, .{});
        }
        try lines.append(allocator, .{
            .spans = try spans.toOwnedSlice(allocator),
            .indent = 0,
            .block_bg = null,
        });
    }

    return lines.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: Allocator, lines: []const StyledLine) void {
    for (lines) |line| freeLine(allocator, line);
    allocator.free(lines);
}

fn freeLine(allocator: Allocator, line: StyledLine) void {
    for (line.spans) |span| allocator.free(span.text);
    allocator.free(line.spans);
}

// ── Line-level parsers ───────────────────────────────────────────────

const Heading = struct { level: usize, text: []const u8 };

fn parseHeading(line: []const u8) ?Heading {
    var level: usize = 0;
    for (line) |ch| {
        if (ch == '#') level += 1 else break;
    }
    if (level == 0 or level > 6) return null;
    if (line.len <= level or line[level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trim(u8, line[level + 1 ..], " \t\r") };
}

const Bullet = struct { text: []const u8, depth: usize };

fn parseBullet(line: []const u8) ?Bullet {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const depth = i / 2;
    if (i + 1 < line.len and (line[i] == '-' or line[i] == '*') and line[i + 1] == ' ') {
        return .{ .text = line[i + 2 ..], .depth = depth };
    }
    return null;
}

const Numbered = struct { prefix: []const u8, text: []const u8, depth: usize };

fn parseNumbered(line: []const u8) ?Numbered {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const depth = i / 2;
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    if (i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
        return .{ .prefix = line[start .. i + 2], .text = line[i + 2 ..], .depth = depth };
    }
    return null;
}

// ── Inline parser (bold, italic, inline code) ────────────────────────

fn parseInlineSpans(allocator: Allocator, spans: *std.ArrayListUnmanaged(StyledSpan), text: []const u8, base: Style) !void {
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < text.len) {
        // ── Inline code: `...` ───────────────────────────
        if (text[i] == '`') {
            if (i > plain_start) try appendSpan(allocator, spans, text[plain_start..i], base);
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`');
            if (end) |e| {
                if (e > i + 1) try appendSpan(allocator, spans, text[i + 1 .. e], style_inline_code);
                i = e + 1;
                plain_start = i;
                continue;
            }
        }

        // ── Bold+italic: ***...*** ───────────────────────
        if (i + 2 < text.len and text[i] == '*' and text[i + 1] == '*' and text[i + 2] == '*') {
            if (i > plain_start) try appendSpan(allocator, spans, text[plain_start..i], base);
            if (findClosing(text, i + 3, "***")) |e| {
                try appendSpan(allocator, spans, text[i + 3 .. e], mergeStyle(base, style_bold_italic));
                i = e + 3;
                plain_start = i;
                continue;
            }
        }

        // ── Bold: **...** ────────────────────────────────
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (i > plain_start) try appendSpan(allocator, spans, text[plain_start..i], base);
            if (findClosing(text, i + 2, "**")) |e| {
                try appendSpan(allocator, spans, text[i + 2 .. e], mergeStyle(base, style_bold));
                i = e + 2;
                plain_start = i;
                continue;
            }
        }

        // ── Italic: *...* ────────────────────────────────
        if (text[i] == '*') {
            if (i > plain_start) try appendSpan(allocator, spans, text[plain_start..i], base);
            if (findClosing(text, i + 1, "*")) |e| {
                try appendSpan(allocator, spans, text[i + 1 .. e], mergeStyle(base, style_italic));
                i = e + 1;
                plain_start = i;
                continue;
            }
        }

        i += 1;
    }

    if (plain_start < text.len) {
        try appendSpan(allocator, spans, text[plain_start..], base);
    }
}

fn findClosing(text: []const u8, start: usize, marker: []const u8) ?usize {
    var i = start;
    while (i + marker.len <= text.len) : (i += 1) {
        if (std.mem.eql(u8, text[i .. i + marker.len], marker)) return i;
    }
    return null;
}

fn mergeStyle(base: Style, overlay: Style) Style {
    var result = base;
    if (overlay.bold) result.bold = true;
    if (overlay.italic) result.italic = true;
    if (overlay.strikethrough) result.strikethrough = true;
    if (overlay.fg != .default) result.fg = overlay.fg;
    if (overlay.bg != .default) result.bg = overlay.bg;
    return result;
}

fn appendSpan(allocator: Allocator, spans: *std.ArrayListUnmanaged(StyledSpan), text: []const u8, style: Style) !void {
    const copy = try allocator.dupe(u8, text);
    errdefer allocator.free(copy);
    try spans.append(allocator, .{ .text = copy, .style = style });
}

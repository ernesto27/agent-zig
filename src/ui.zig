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

const std = @import("std");

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

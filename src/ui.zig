const std = @import("std");
const vaxis = @import("vaxis");
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

    const result = std.fmt.bufPrint(&loadingBuf, "{s}({d}s) ", .{ frame, elapsed_secs }) catch return frame;
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

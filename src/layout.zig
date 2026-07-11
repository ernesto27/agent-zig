const std = @import("std");
const App = @import("App.zig").App;
const attach_preview = @import("attach_preview.zig");
const code_modal = @import("code_modal.zig");

pub const Layout = struct {
    chat_y: u16,
    preview_h: u16,
    chat_h_total: u16,
    preview_y: u16,
    loading_h: u16,
    loading_y: u16,
    queue_h: u16,
    queue_y: u16,
    input_y: u16,
    /// Width of the task sidebar column carved out of the chat row, or 0 when
    /// hidden. The chat window uses `screen_width - sidebar_w`.
    sidebar_w: u16,
};

/// Max queued-message rows shown at once (the rest are off-screen but still sent).
pub const max_queue_visible: u16 = 5;

/// Fixed width of the task sidebar column when shown.
pub const sidebar_width: u16 = 40;
/// Chat must keep at least this many columns; below `sidebar_width + this` the
/// sidebar is suppressed so a narrow terminal isn't crushed.
pub const min_chat_width: u16 = 40;

pub fn wrappedRows(text: []const u8, width: u16) usize {
    if (width == 0) return 1;
    var rows: usize = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        rows += @max(1, (line.len + width - 1) / width);
    }
    return @max(rows, 1);
}

pub fn compute(screen_width: u16, screen_height: u16, app: *App, input_box_h: u16, show_images: bool) Layout {
    const chat_y: u16 = 1;
    const min_chat_h: u16 = 1;
    const show_grep_panel = app.grep_status.pattern.len > 0 or
        (app.tool_confirmation.pending and app.tool_confirmation.tool == .grep);
    const show_glob_panel = app.glob_status.pattern.len > 0 or
        (app.tool_confirmation.pending and app.tool_confirmation.tool == .glob);
    const show_web_panel = app.web_status.label.len > 0;

    const loading_h: u16 = if (app.loading.active) 1 else 0;

    // Reserve rows for the queued-message ("Steering:") list — hidden while a
    // tool confirmation is pending so it doesn't fight the confirmation panel.
    const queue_h: u16 = if (app.tool_confirmation.pending)
        0
    else
        @min(@as(u16, @intCast(app.message_queue.getAll().len)), max_queue_visible);

    const max_preview_h = screen_height -| (chat_y + min_chat_h + input_box_h + loading_h + queue_h + 1);

    const is_code_confirm = code_modal.isCodeConfirmation(app);

    const requested_preview_h: u16 = if (is_code_confirm) 0 else if (app.tool_confirmation.pending) blk: {
        const content_lines: usize = if (std.mem.startsWith(u8, app.tool_confirmation.tool_name, "mcp__"))
            std.mem.count(u8, app.tool_confirmation.content, "\n") + 1
        else if (app.tool_confirmation.tool == .grep or app.tool_confirmation.tool == .glob)
            3
        else if (app.tool_confirmation.tool == .bash)
            wrappedRows(app.tool_confirmation.file_path, screen_width -| 4)
        else
            1;
        const is_bash_conf = app.tool_confirmation.tool == .bash;
        const chrome: usize = if (is_bash_conf) 8 else 6;
        const cap: usize = if (is_bash_conf) 24 else 20;
        const needed: u16 = @intCast(@min(content_lines + chrome, cap));
        break :blk @max(needed, 8);
    } else if (show_grep_panel or show_glob_panel) 7 else if (show_web_panel) 3 else if (app.pending_attachments.items.len > 0)
        attach_preview.requestedHeight(app.pending_attachments.items, show_images)
    else
        0;

    const preview_h: u16 = @min(requested_preview_h, max_preview_h);

    const exit_hint_h: u16 = 0;
    const chat_h_total: u16 = if (screen_height > 1 + input_box_h + preview_h + loading_h + queue_h + 1 + exit_hint_h)
        screen_height - 1 - input_box_h - preview_h - loading_h - queue_h - 1 - exit_hint_h
    else
        1;
    const preview_y: u16 = chat_y + chat_h_total;
    const queue_y: u16 = preview_y + preview_h;
    const loading_y: u16 = queue_y + queue_h;
    const input_y: u16 = loading_y + loading_h;

    const sidebar_fits = screen_width >= min_chat_width + sidebar_width;
    const has_pending_work = !app.tasks.isEmpty() and !app.tasks.allCompleted();
    const sidebar_w: u16 = if (has_pending_work and sidebar_fits) sidebar_width else 0;

    return .{
        .chat_y = chat_y,
        .preview_h = preview_h,
        .chat_h_total = chat_h_total,
        .preview_y = preview_y,
        .loading_h = loading_h,
        .loading_y = loading_y,
        .queue_h = queue_h,
        .queue_y = queue_y,
        .input_y = input_y,
        .sidebar_w = sidebar_w,
    };
}

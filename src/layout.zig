const std = @import("std");
const App = @import("App.zig").App;
const attach_preview = @import("attach_preview.zig");

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
};

/// Max queued-message rows shown at once (the rest are off-screen but still sent).
pub const max_queue_visible: u16 = 5;

pub fn compute(screen_height: u16, app: *App, input_box_h: u16, show_images: bool) Layout {
    const chat_y: u16 = 1;
    const min_chat_h: u16 = 1;
    const show_grep_panel = app.grep_status.pattern.len > 0 or
        (app.tool_confirmation.pending and std.mem.eql(u8, app.tool_confirmation.tool_name, "grep"));
    const show_glob_panel = app.glob_status.pattern.len > 0 or
        (app.tool_confirmation.pending and std.mem.eql(u8, app.tool_confirmation.tool_name, "glob"));
    const show_web_panel = app.web_status.label.len > 0;

    const loading_h: u16 = if (app.is_loading) 1 else 0;

    // Reserve rows for the queued-message ("Steering:") list — hidden while a
    // tool confirmation is pending so it doesn't fight the confirmation panel.
    const queue_h: u16 = if (app.tool_confirmation.pending)
        0
    else
        @min(@as(u16, @intCast(app.message_queue.getAll().len)), max_queue_visible);

    const max_preview_h = screen_height -| (chat_y + min_chat_h + input_box_h + loading_h + queue_h + 1);

    const requested_preview_h: u16 = if (app.tool_confirmation.pending) blk: {
        const content_lines: usize = if (std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file"))
            std.mem.count(u8, app.tool_confirmation.content, "\n") + 1
        else if (std.mem.eql(u8, app.tool_confirmation.tool_name, "edit_file"))
            std.mem.count(u8, app.tool_confirmation.old_string, "\n") +
                std.mem.count(u8, app.tool_confirmation.new_string, "\n") + 2
        else if (std.mem.startsWith(u8, app.tool_confirmation.tool_name, "mcp__"))
            std.mem.count(u8, app.tool_confirmation.content, "\n") + 1
        else if (std.mem.eql(u8, app.tool_confirmation.tool_name, "grep") or std.mem.eql(u8, app.tool_confirmation.tool_name, "glob"))
            4
        else
            1;
        const needed: u16 = @intCast(@min(content_lines + 6, 20));
        break :blk @max(needed, 8);
    } else if (show_grep_panel or show_glob_panel) 8
      else if (show_web_panel) 3
      else if (app.pending_attachments.items.len > 0)
          attach_preview.requestedHeight(app.pending_attachments.items, show_images)
      else 0;

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
    };
}

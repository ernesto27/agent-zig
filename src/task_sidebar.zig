const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig").App;
const palette = @import("theme");

const left_pad: u16 = 1;
const glyph_cols: u16 = 4;

fn statusColor(status: agent.tasks.Status) vaxis.Color {
    return switch (status) {
        .pending => palette.dim,
        .in_progress => palette.accent,
        .completed => palette.green,
    };
}

/// Render the task sidebar into a bordered panel. Called from the main draw
/// path while the App mutex is held, so `app.tasks` is a stable snapshot and its
/// strings outlive `vx.render`. The header is allocated in the frame arena,
/// which also outlives the render.
pub fn render(
    frame_alloc: std.mem.Allocator,
    win: vaxis.Window,
    app: *App,
    x_off: u16,
    y_off: u16,
    width: u16,
    height: u16,
) void {
    const panel = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    const s = app.tasks.summary();
    const header = std.fmt.allocPrint(frame_alloc, "Tasks {d}/{d}", .{ s.completed, s.total }) catch "Tasks";
    _ = panel.printSegment(
        .{ .text = header, .style = .{ .fg = palette.white, .bold = true } },
        .{ .row_offset = 0, .col_offset = left_pad },
    );

    const content_max: usize = panel.width -| (left_pad + glyph_cols + 1);
    var row: u16 = 2;
    for (app.tasks.items.items) |task| {
        if (row >= panel.height) break;
        _ = panel.printSegment(
            .{ .text = task.status.glyph(), .style = .{ .fg = statusColor(task.status) } },
            .{ .row_offset = row, .col_offset = left_pad },
        );
        const text = agent.utils.truncate(task.content, content_max, 1);
        const style: vaxis.Style = if (task.status == .completed)
            .{ .fg = palette.dim }
        else
            .{ .fg = palette.light };
        _ = panel.printSegment(
            .{ .text = text, .style = style },
            .{ .row_offset = row, .col_offset = left_pad + glyph_cols, .wrap = .none },
        );
        row += 1;
    }
}

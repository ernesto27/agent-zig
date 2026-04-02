const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig");
const ui = @import("ui.zig");
const at_picker_mod = @import("at_picker.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

// File logger — written before main() opens the log file
var log_file: ?std.fs.File = null;

pub const std_options: std.Options = .{ .logFn = logToFile };

fn logToFile(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const f = log_file orelse return;
    const prefix = comptime "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ ") ";
    var buf: [1024 * 1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
    f.writeAll(msg) catch {};
}

pub fn main() !void {
    log_file = try std.fs.cwd().createFile("agent.log", .{ .truncate = true });
    defer log_file.?.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const parsed_config = agent.config.load(alloc) catch {
        std.debug.print("Failed to load config. Create ~/.config/agent-zig/config.jhison\n", .{});
        return;
    };
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var at_picker = at_picker_mod.AtPicker.init();
    defer at_picker.deinit(alloc);

    var llm_client = agent.llm.Client.init(alloc, .{
        .base_url = config.baseUrl,
        .api_key = config.apiKey,
        .model = config.model,
    });
    defer llm_client.deinit();

    var app = App.init(alloc, &llm_client);
    defer app.deinit();

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: EventLoop = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    defer vx.exitAltScreen(tty.writer()) catch {};
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);
    try vx.setMouseMode(tty.writer(), true);

    if (!vx.state.in_band_resize) try loop.init();

    var running = true;
    var scroll_offset: usize = 0;
    var auto_scroll = true;
    var preview_scroll: usize = 0;
    var input = std.ArrayList(u8){};
    defer input.deinit(alloc);
    var cursor_pos: usize = 0;
    var history = std.ArrayList([]const u8){};
    defer {
        for (history.items) |s| alloc.free(s);
        history.deinit(alloc);
    }
    var history_idx: ?usize = null;
    var draft = std.ArrayList(u8){};
    defer draft.deinit(alloc);

    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
                    running = false;
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (at_picker.active) {
                        at_picker.reset(alloc);
                    }
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (at_picker.active) {
                        if (at_picker.selected > 0) at_picker.selected -= 1;
                    } else if (!app.tool_confirmation.pending and history.items.len > 0) {
                        if (history_idx == null) {
                            draft.clearRetainingCapacity();
                            try draft.appendSlice(alloc, input.items);
                            history_idx = history.items.len - 1;
                        } else if (history_idx.? > 0) {
                            history_idx = history_idx.? - 1;
                        }
                        input.clearRetainingCapacity();
                        try input.appendSlice(alloc, history.items[history_idx.?]);
                        cursor_pos = input.items.len;
                    }
                } else if (key.matches(vaxis.Key.down, .{})) {
                    if (at_picker.active) {
                        if (at_picker.selected + 1 < at_picker.results.items.len)
                            at_picker.selected += 1;
                    } else if (!app.tool_confirmation.pending and history_idx != null) {
                        if (history_idx.? + 1 < history.items.len) {
                            history_idx = history_idx.? + 1;
                            input.clearRetainingCapacity();
                            try input.appendSlice(alloc, history.items[history_idx.?]);
                        } else {
                            history_idx = null;
                            input.clearRetainingCapacity();
                            try input.appendSlice(alloc, draft.items);
                        }
                        cursor_pos = input.items.len;
                    }
                } else if (key.matches(vaxis.Key.left, .{})) {
                    if (cursor_pos > 0) cursor_pos -= 1;
                } else if (key.matches(vaxis.Key.right, .{})) {
                    if (cursor_pos < input.items.len) cursor_pos += 1;
                } else if (key.matches('y', .{})) {
                    if (app.tool_confirmation.pending) {
                        app.mutex.lock();
                        app.tool_confirmation.approved = true;
                        app.tool_confirmation.pending = false;
                        app.mutex.unlock();
                        app.tool_confirmation.cond.signal();
                    } else if (!app.is_loading) {
                        try input.insertSlice(alloc, cursor_pos, "y");
                        cursor_pos += 1;
                    }
                } else if (key.matches('n', .{})) {
                    if (app.tool_confirmation.pending) {
                        app.mutex.lock();
                        var deny_buf: [256]u8 = undefined;
                        const action = if (std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file")) "write" else "edit";
                        const deny_text = std.fmt.bufPrint(&deny_buf, "Permission denied: agent cannot {s} '{s}'", .{
                            action,
                            app.tool_confirmation.file_path,
                        }) catch "Permission denied";
                        try app.messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, deny_text) });
                        app.tool_confirmation.approved = false;
                        app.tool_confirmation.pending = false;
                        app.mutex.unlock();
                        app.tool_confirmation.cond.signal();
                    } else if (!app.is_loading) {
                        try input.insertSlice(alloc, cursor_pos, "n");
                        cursor_pos += 1;
                    }
                } else if (key.codepoint == 127 or key.codepoint == 8) {
                    if (cursor_pos > 0) {
                        _ = input.orderedRemove(cursor_pos - 1);
                        cursor_pos -= 1;
                        if (at_picker.active) {
                            if (cursor_pos <= at_picker.at_start) {
                                at_picker.reset(alloc);
                            } else {
                                at_picker.query.clearRetainingCapacity();
                                const after_at = input.items[at_picker.at_start + 1 .. cursor_pos];
                                try at_picker.query.appendSlice(alloc, after_at);
                                try at_picker.refresh(alloc);
                            }
                        }
                    }
                } else if (key.text) |txt| {
                    if (txt.len > 0) {
                        try input.insertSlice(alloc, cursor_pos, txt);
                        cursor_pos += txt.len;

                        if (std.mem.eql(u8, txt, "@") and !at_picker.active) {
                            at_picker.active = true;
                            at_picker.at_start = cursor_pos - 1;
                            try at_picker.refresh(alloc);
                        } else if (at_picker.active) {
                            at_picker.query.clearRetainingCapacity();
                            const after_at = input.items[at_picker.at_start + 1 .. cursor_pos];
                            try at_picker.query.appendSlice(alloc, after_at);
                            try at_picker.refresh(alloc);
                        }
                    }
                } else if (key.matches('\r', .{}) or key.matches('\n', .{})) {
                    if (at_picker.active and at_picker.results.items.len > 0) {
                        // Confirm file selection — do NOT submit message
                        const picked_path = at_picker.results.items[at_picker.selected];

                        // Track the pick BEFORE reset() frees results
                        try at_picker.addPicked(alloc, picked_path);

                        // Replace '@query' with '@full/relative/path'
                        var replacement = std.ArrayList(u8){};
                        defer replacement.deinit(alloc);
                        try replacement.append(alloc, '@');
                        try replacement.appendSlice(alloc, picked_path);

                        const span_len = cursor_pos - at_picker.at_start;
                        var i: usize = 0;
                        while (i < span_len) : (i += 1) {
                            _ = input.orderedRemove(at_picker.at_start);
                        }
                        try input.insertSlice(alloc, at_picker.at_start, replacement.items);
                        cursor_pos = at_picker.at_start + replacement.items.len;

                        at_picker.reset(alloc);
                    } else if (input.items.len > 0 and !app.is_loading) {
                        app.mutex.lock();

                        const picked = at_picker.takePicked(alloc, input.items);
                        defer alloc.free(picked);
                        for (picked) |p| app.pending_attachments.append(alloc, p) catch alloc.free(p);

                        const user_text = try alloc.dupe(u8, input.items);
                        try app.messages.append(alloc, .{ .role = .user, .content = user_text });
                        try app.messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "") });
                        app.is_loading = true;
                        app.mutex.unlock();

                        try history.append(alloc, try alloc.dupe(u8, input.items));
                        history_idx = null;
                        draft.clearRetainingCapacity();
                        input.clearRetainingCapacity();
                        auto_scroll = true;
                        cursor_pos = 0;

                        // Spawn background thread
                        const thread = try std.Thread.spawn(.{}, App.fetchAiResponse, .{ &app, &loop });
                        thread.detach();
                    }
                }
                app.needs_redraw = true;
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    if (app.tool_confirmation.pending) {
                        if (preview_scroll > 0) preview_scroll -|= 3;
                    } else {
                        if (scroll_offset > 0) scroll_offset -|= 3;
                        auto_scroll = false;
                    }
                    app.needs_redraw = true;
                } else if (mouse.button == .wheel_down) {
                    if (app.tool_confirmation.pending) {
                        preview_scroll += 3;
                    } else {
                        scroll_offset += 3;
                    }
                    app.needs_redraw = true;
                }
            },
            .winsize => |ws| {
                if (ws.rows != vx.screen.height or ws.cols != vx.screen.width) {
                    try vx.resize(alloc, tty.writer(), ws);
                }
                app.needs_redraw = true;
            },
            else => {},
        }

        if (!app.needs_redraw or !running) continue;

        app.mutex.lock();
        var win = vx.window();
        win.clear();

        // Header
        _ = win.printSegment(.{
            .text = " Zigent - AI Coding Agent ",
            .style = .{ .bg = .{ .rgb = .{ 0x30, 0x80, 0xD0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 0 });

        // Layout constants
        const input_box_h: u16 = 3; // top border + 1 content row + bottom border
        const chat_y: u16 = 1;
        const preview_h: u16 = if (app.tool_confirmation.pending) 14 else 0;
        const chat_h_total: u16 = if (vx.screen.height > 1 + input_box_h + preview_h + 1) vx.screen.height - 1 - input_box_h - preview_h - 1 else 1;
        const preview_y: u16 = chat_y + chat_h_total;
        const input_y: u16 = preview_y + preview_h;

        // Chat area
        const chat_win = win.child(.{
            .x_off = 0,
            .y_off = chat_y,
            .width = vx.screen.width,
            .height = chat_h_total,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const chat_h = chat_win.height;

        // Pre-compute all lines for scrolling
        const LineEntry = union(enum) {
            plain: struct { text: []const u8, prefix: []const u8, is_first: bool },
            styled: agent.markdown.StyledLine,
        };
        const max_total_lines = 2048;
        var all_lines: [max_total_lines]LineEntry = undefined;
        var total_lines: usize = 0;

        for (app.messages.items) |*msg| {
            if (msg.role == .assistant) {
                // AI label
                if (total_lines < max_total_lines) {
                    all_lines[total_lines] = .{ .plain = .{
                        .text = "",
                        .prefix = "AI: ",
                        .is_first = true,
                    } };
                    total_lines += 1;
                }
                // Styled markdown lines
                const styled = app.getStyledLines(msg) catch &.{};
                for (styled) |sline| {
                    if (total_lines >= max_total_lines) break;
                    all_lines[total_lines] = .{ .styled = sline };
                    total_lines += 1;
                }
            } else {
                // User messages — plain text
                const prefix = "You: ";
                const prefix_len = @as(u16, @intCast(prefix.len));
                const user_wrap_w = if (chat_win.width > prefix_len + 3) chat_win.width - prefix_len - 3 else 10;
                const wrapped = ui.wrapText(msg.content, user_wrap_w, 512);
                for (wrapped, 0..) |maybe_line, li| {
                    const line = maybe_line orelse break;
                    if (total_lines >= max_total_lines) break;
                    all_lines[total_lines] = .{ .plain = .{
                        .text = line,
                        .prefix = prefix,
                        .is_first = li == 0,
                    } };
                    total_lines += 1;
                }
            }
        }

        // Clamp scroll_offset and handle auto-scroll
        const max_scroll = if (total_lines > chat_h) total_lines - chat_h else 0;
        if (auto_scroll) {
            scroll_offset = max_scroll;
        } else if (scroll_offset >= max_scroll) {
            scroll_offset = max_scroll;
            auto_scroll = true;
        }

        var row: u16 = 0;
        const start = if (scroll_offset < total_lines) scroll_offset else 0;
        for (all_lines[start..total_lines]) |entry| {
            if (row >= chat_h) break;
            switch (entry) {
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
                    // Fill background for code blocks
                    if (sline.block_bg) |bg| {
                        var c: u16 = 1;
                        while (c < chat_win.width -| 1) : (c += 1) {
                            chat_win.writeCell(c, row, .{
                                .char = .{ .grapheme = " ", .width = 1 },
                                .style = .{ .bg = bg },
                            });
                        }
                    }
                    // Print styled spans
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
            }
            row += 1;
        }

        // Input box with border
        // Preview panel
        if (app.tool_confirmation.pending) {
            const is_write = std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file");
            const preview_win = win.child(.{
                .x_off = 0,
                .y_off = preview_y,
                .width = vx.screen.width,
                .height = preview_h,
                .border = .{ .where = .all, .glyphs = .single_rounded },
            });
            var title_buf: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, " {s} {s} ", .{
                if (is_write) "New file:" else "Editing:",
                app.tool_confirmation.file_path,
            }) catch " Preview ";
            _ = preview_win.printSegment(.{
                .text = title,
                .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true, .bg = .{ .rgb = .{ 0x30, 0x60, 0xA0 } } },
            }, .{ .row_offset = 0, .col_offset = 1 });

            const preview_content_h = if (preview_win.height > 1) preview_win.height - 1 else 0;

            if (is_write) {
                var line_iter = std.mem.splitScalar(u8, app.tool_confirmation.content, '\n');
                var line_idx: usize = 0;
                var prow: u16 = 1;
                while (line_iter.next()) |line| {
                    if (prow >= preview_content_h) break;
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
                    if (prow >= preview_content_h) break;
                    if (line_idx >= preview_scroll) {
                        var diff_buf: [512]u8 = undefined;
                        const diff_line = std.fmt.bufPrint(&diff_buf, "- {s}", .{line}) catch line;
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
                    if (prow >= preview_content_h) break;
                    if (line_idx >= preview_scroll) {
                        var diff_buf: [512]u8 = undefined;
                        const diff_line = std.fmt.bufPrint(&diff_buf, "+ {s}", .{line}) catch line;
                        _ = preview_win.printSegment(.{
                            .text = diff_line,
                            .style = .{ .fg = .{ .rgb = .{ 0x60, 0xFF, 0x60 } } },
                        }, .{ .row_offset = prow, .col_offset = 1 });
                        prow += 1;
                    }
                    line_idx += 1;
                }
            }
        }

        // @picker overlay — rendered above the input box
        if (at_picker.active and at_picker.results.items.len > 0) {
            const n: u16 = @intCast(@min(at_picker.results.items.len, at_picker_mod.MAX_RESULTS));
            const picker_h: u16 = n + 2; // +2 for border
            const picker_y: u16 = if (input_y >= picker_h) input_y - picker_h else 0;
            const picker_win = win.child(.{
                .x_off = 0,
                .y_off = picker_y,
                .width = vx.screen.width,
                .height = picker_h,
                .border = .{ .where = .all, .glyphs = .single_rounded },
            });

            for (at_picker.results.items, 0..) |path, idx| {
                const picker_row: u16 = @intCast(idx);
                if (picker_row >= n) break;
                const is_selected = idx == at_picker.selected;
                const style: vaxis.Style = if (is_selected)
                    .{ .bg = .{ .rgb = .{ 0x30, 0x60, 0xA0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true }
                else
                    .{ .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } };
                const prefix: []const u8 = if (is_selected) " > " else "   ";
                const res = picker_win.printSegment(.{ .text = prefix, .style = style }, .{ .row_offset = picker_row, .col_offset = 0 });
                _ = picker_win.printSegment(.{ .text = path, .style = style }, .{ .row_offset = picker_row, .col_offset = res.col });
            }
        }

        const input_win = win.child(.{
            .x_off = 0,
            .y_off = input_y,
            .width = vx.screen.width,
            .height = input_box_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        if (app.tool_confirmation.pending) {
            var confirm_buf: [256]u8 = undefined;
            const action = if (std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file")) "write" else "edit";
            const confirm_text = std.fmt.bufPrint(&confirm_buf, " Allow agent to {s} '{s}'?  y = yes   n = no   scroll = preview", .{
                action,
                app.tool_confirmation.file_path,
            }) catch " Allow file change?  y = yes   n = no";
            _ = input_win.printSegment(.{
                .text = confirm_text,
                .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
            }, .{ .row_offset = 0, .col_offset = 1 });
        } else {
            const prompt = if (app.is_loading) "... " else "> ";
            _ = input_win.printSegment(.{
                .text = prompt,
                .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
            }, .{ .row_offset = 0, .col_offset = 1 });
            const text_col: u16 = 1 + @as(u16, @intCast(prompt.len));
            if (cursor_pos > 0) {
                _ = input_win.printSegment(.{
                    .text = input.items[0..cursor_pos],
                    .style = .{ .bold = true },
                }, .{ .row_offset = 0, .col_offset = text_col });
            }
            const cursor_char: []const u8 = if (cursor_pos < input.items.len) input.items[cursor_pos .. cursor_pos + 1] else " ";
            _ = input_win.printSegment(.{
                .text = cursor_char,
                .style = .{ .bold = true, .reverse = true },
            }, .{ .row_offset = 0, .col_offset = text_col + @as(u16, @intCast(cursor_pos)) });
            if (cursor_pos < input.items.len) {
                _ = input_win.printSegment(.{
                    .text = input.items[cursor_pos + 1 ..],
                    .style = .{ .bold = true },
                }, .{ .row_offset = 0, .col_offset = text_col + @as(u16, @intCast(cursor_pos)) + 1 });
            }
        }

        // Status
        var status_buf: [128]u8 = undefined;
        const status_text = if (app.tool_status) |tool| blk: {
            break :blk std.fmt.bufPrint(&status_buf, " messages: {d} | TOOL: {s} | ctrl+q: quit ", .{ app.messages.items.len, tool }) catch "status";
        } else blk: {
            break :blk std.fmt.bufPrint(&status_buf, " messages: {d} | {s} | ctrl+q: quit ", .{ app.messages.items.len, if (app.is_loading) "THINKING" else "READY" }) catch "status";
        };
        _ = win.printSegment(.{ .text = status_text, .style = .{ .bg = .{ .rgb = .{ 0x40, 0x40, 0x40 } }, .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } } }, .{ .row_offset = if (vx.screen.height == 0) 0 else vx.screen.height - 1, .col_offset = 0 });

        try vx.render(tty.writer());
        app.needs_redraw = false;
        app.mutex.unlock();
    }
}

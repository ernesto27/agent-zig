const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig");
const chat_selection = @import("chat_selection.zig");
const layout_mod = @import("layout.zig");
const ui = @import("ui.zig");
const at_picker_mod = @import("at_picker.zig");
const command_picker_mod = @import("command_picker.zig");
const model_picker_mod = @import("model_picker.zig");
const provider_picker_mod = @import("provider_picker.zig");

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

fn runSlashCommand(
    alloc: std.mem.Allocator,
    action: command_picker_mod.CommandAction,
    input: *std.ArrayList(u8),
    cursor_pos: *usize,
    model_picker: *model_picker_mod.ModelPicker,
    provider_picker: *provider_picker_mod.ProviderPicker,
) !void {
    input.clearRetainingCapacity();
    cursor_pos.* = 0;

    switch (action) {
        .provider => provider_picker.open(),
        .model => try model_picker.open(alloc),
    }
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

    var model_picker = model_picker_mod.ModelPicker.init();
    defer model_picker.deinit(alloc);

    var provider_picker = provider_picker_mod.ProviderPicker.init();
    defer provider_picker.deinit(alloc);

    var command_picker = command_picker_mod.CommandPicker.init();
    defer command_picker.deinit(alloc);

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
    var selection: chat_selection.SelectionState = .{};
    var clipboard_status: ?[]const u8 = null;

    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
                    running = false;
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (at_picker.active) {
                        at_picker.reset(alloc);
                    } else if (command_picker.active) {
                        command_picker.reset(alloc);
                    } else if (model_picker.active) {
                        model_picker.reset(alloc);
                    } else if (provider_picker.active) {
                        provider_picker.reset(alloc);
                    }
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (at_picker.active) {
                        if (at_picker.selected > 0) at_picker.selected -= 1;
                    } else if (command_picker.active) {
                        if (command_picker.selected > 0) command_picker.selected -= 1;
                    } else if (model_picker.active) {
                        if (model_picker.selected > 0) model_picker.selected -= 1;
                    } else if (provider_picker.active and provider_picker.phase == .list) {
                        if (provider_picker.selected > 0) provider_picker.selected -= 1;
                    } else if (app.tool_confirmation.pending) {
                        app.tool_confirmation.cursor = 0;
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
                        try command_picker.updateFromInput(alloc, input.items);
                    }
                } else if (key.matches(vaxis.Key.down, .{})) {
                    if (at_picker.active) {
                        if (at_picker.selected + 1 < at_picker.results.items.len)
                            at_picker.selected += 1;
                    } else if (command_picker.active) {
                        if (command_picker.selected + 1 < command_picker.results.items.len)
                            command_picker.selected += 1;
                    } else if (model_picker.active) {
                        if (model_picker.selected + 1 < model_picker.results.items.len)
                            model_picker.selected += 1;
                    } else if (provider_picker.active and provider_picker.phase == .list) {
                        if (provider_picker.selected + 1 < model_picker_mod.providers.len)
                            provider_picker.selected += 1;
                    } else if (app.tool_confirmation.pending) {
                        app.tool_confirmation.cursor = 1;
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
                        try command_picker.updateFromInput(alloc, input.items);
                    }
                } else if (key.matches(vaxis.Key.left, .{})) {
                    if (cursor_pos > 0) cursor_pos -= 1;
                } else if (key.matches(vaxis.Key.right, .{})) {
                    if (cursor_pos < input.items.len) cursor_pos += 1;
                } else if (key.codepoint == 127 or key.codepoint == 8) {
                    if (provider_picker.active and provider_picker.phase == .key_input) {
                        if (provider_picker.key_input.items.len > 0)
                            _ = provider_picker.key_input.orderedRemove(provider_picker.key_input.items.len - 1);
                    } else if (model_picker.active) {
                        if (model_picker.query.items.len > 0) {
                            _ = model_picker.query.orderedRemove(model_picker.query.items.len - 1);
                            try model_picker.refresh(alloc);
                        }
                    } else if (cursor_pos > 0) {
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
                        try command_picker.updateFromInput(alloc, input.items);
                    }
                } else if (key.text) |txt| {
                    if (provider_picker.active and provider_picker.phase == .key_input) {
                        try provider_picker.key_input.appendSlice(alloc, txt);
                    } else if (model_picker.active) {
                        try model_picker.query.appendSlice(alloc, txt);
                        try model_picker.refresh(alloc);
                    } else if (txt.len > 0) {
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
                        try command_picker.updateFromInput(alloc, input.items);
                    }
                } else if (key.matches('\r', .{}) or key.matches('\n', .{})) {
                    if (app.tool_confirmation.pending) {
                        if (app.tool_confirmation.cursor == 0) {
                            app.mutex.lock();
                            app.tool_confirmation.approved = true;
                            app.tool_confirmation.pending = false;
                            app.mutex.unlock();
                            app.tool_confirmation.cond.signal();
                        } else {
                            app.mutex.lock();
                            var deny_buf: [256]u8 = undefined;
                            const action = if (std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file")) "write" else if (std.mem.eql(u8, app.tool_confirmation.tool_name, "bash")) "run" else "edit";
                            const deny_text = std.fmt.bufPrint(&deny_buf, "Permission denied: agent cannot {s} '{s}'", .{ action, app.tool_confirmation.file_path }) catch "Permission denied";
                            try app.messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, deny_text) });
                            app.tool_confirmation.approved = false;
                            app.tool_confirmation.pending = false;
                            app.mutex.unlock();
                            app.tool_confirmation.cond.signal();
                        }
                    } else if (command_picker.active) {
                        if (command_picker.selectedCommand()) |command| {
                            try runSlashCommand(alloc, command.action, &input, &cursor_pos, &model_picker, &provider_picker);
                        }
                        command_picker.reset(alloc);
                    } else if (at_picker.active and at_picker.results.items.len > 0) {
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
                    } else if (model_picker.active and model_picker.results.items.len > 0) {
                        const selected = model_picker.results.items[model_picker.selected];
                        app.llm_client.config.model = selected.id;
                        agent.config.save(alloc, .{
                            .apiKey = config.apiKey,
                            .baseUrl = config.baseUrl,
                            .model = selected.id,
                        }) catch {};
                        model_picker.reset(alloc);
                    } else if (provider_picker.active and provider_picker.phase == .list) {
                        provider_picker.phase = .key_input;
                    } else if (provider_picker.active and provider_picker.phase == .key_input) {
                        if (provider_picker.key_input.items.len > 0) {
                            const new_key = provider_picker.key_input.items;
                            app.llm_client.config.api_key = new_key;
                            agent.config.save(alloc, .{
                                .apiKey = new_key,
                                .baseUrl = config.baseUrl,
                                .model = config.model,
                            }) catch {};
                        }
                        provider_picker.reset(alloc);
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
                } else if (mouse.button == .left) {
                    var mouse_arena = std.heap.ArenaAllocator.init(alloc);
                    defer mouse_arena.deinit();

                    app.mutex.lock();
                    const layout = layout_mod.compute(vx.screen.height, &app);
                    const rendered_lines = chat_selection.buildRenderedLines(&app, mouse_arena.allocator(), if (vx.screen.width > 0) vx.screen.width else 1, vx.screen.width_method) catch &.{};
                    app.mutex.unlock();

                    const chat_win = vx.window().child(.{
                        .x_off = 0,
                        .y_off = layout.chat_y,
                        .width = vx.screen.width,
                        .height = layout.chat_h_total,
                        .border = .{ .where = .all, .glyphs = .single_rounded },
                    });

                    switch (mouse.type) {
                        .press => {
                            clipboard_status = null;
                            if (chat_selection.pointFromMouse(mouse, chat_win, scroll_offset, rendered_lines)) |point| {
                                selection.anchor = point;
                                selection.focus = point;
                                selection.dragging = true;
                                app.needs_redraw = true;
                            } else {
                                const had_selection = selection.anchor != null or selection.focus != null;
                                selection.clear();
                                if (had_selection) app.needs_redraw = true;
                            }
                        },
                        .drag => {
                            if (selection.dragging) {
                                if (chat_selection.pointFromMouse(mouse, chat_win, scroll_offset, rendered_lines)) |point| {
                                    selection.focus = point;
                                    app.needs_redraw = true;
                                }
                            }
                        },
                        .release => {
                            if (selection.dragging) {
                                selection.dragging = false;
                                if (chat_selection.pointFromMouse(mouse, chat_win, scroll_offset, rendered_lines)) |point| {
                                    selection.focus = point;
                                }

                                if (selection.bounds(rendered_lines)) |bounds| {
                                    const copied = chat_selection.selectedText(alloc, rendered_lines, bounds, vx.screen.width_method) catch blk: {
                                        clipboard_status = " copy failed ";
                                        break :blk null;
                                    };
                                    if (copied) |text| {
                                        defer alloc.free(text);
                                        if (text.len == 0) {
                                            clipboard_status = " nothing selected ";
                                        } else {
                                            vx.copyToSystemClipboard(tty.writer(), text, alloc) catch {
                                                clipboard_status = " copy failed ";
                                                app.needs_redraw = true;
                                                break;
                                            };
                                            clipboard_status = " copied selection ";
                                        }
                                    }
                                } else {
                                    clipboard_status = " drag to copy ";
                                }
                                app.needs_redraw = true;
                            }
                        },
                        else => {},
                    }
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

        var frame_arena = std.heap.ArenaAllocator.init(alloc);
        defer frame_arena.deinit();

        // Header
        _ = win.printSegment(.{
            .text = " Zigent - AI Coding Agent ",
            .style = .{ .bg = .{ .rgb = .{ 0x30, 0x80, 0xD0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 0 });

        const layout = layout_mod.compute(vx.screen.height, &app);

        // Chat area
        const chat_win = win.child(.{
            .x_off = 0,
            .y_off = layout.chat_y,
            .width = vx.screen.width,
            .height = layout.chat_h_total,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const chat_h = chat_win.height;
        const rendered_lines = chat_selection.buildRenderedLines(&app, frame_arena.allocator(), chat_win.width, vx.screen.width_method) catch &.{};
        const total_lines = rendered_lines.len;

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

        if (selection.bounds(rendered_lines)) |bounds| {
            var visible_row: usize = 0;
            var line_idx = start;
            while (visible_row < chat_h and line_idx < rendered_lines.len) : ({
                visible_row += 1;
                line_idx += 1;
            }) {
                const line = rendered_lines[line_idx];
                const range = chat_selection.selectionRangeForLine(bounds, line_idx, line.display_cols) orelse continue;
                chat_selection.applySelectionHighlight(chat_win, @intCast(visible_row), line, range);
            }
        }

        // Input box with border
        // Preview panel
        if (app.tool_confirmation.pending) {
            const is_write = std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file");
            const is_bash = std.mem.eql(u8, app.tool_confirmation.tool_name, "bash");
            const preview_win = win.child(.{
                .x_off = 0,
                .y_off = layout.preview_y,
                .width = vx.screen.width,
                .height = layout.preview_h,
                .border = .{ .where = .all, .glyphs = .single_rounded },
            });
            var title_buf: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, " {s} {s} ", .{
                if (is_bash) "Run:" else if (is_write) "New file:" else "Editing:",
                app.tool_confirmation.file_path,
            }) catch " Preview ";
            _ = preview_win.printSegment(.{
                .text = title,
                .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true, .bg = .{ .rgb = .{ 0x30, 0x60, 0xA0 } } },
            }, .{ .row_offset = 0, .col_offset = 1 });

            const sel_row = preview_win.height -| 3;
            const preview_content_end = sel_row;

            if (is_bash) {
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
            } else {
                var prow: u16 = 1;
                var line_idx: usize = 0;
                var old_iter = std.mem.splitScalar(u8, app.tool_confirmation.old_string, '\n');
                while (old_iter.next()) |line| {
                    if (prow >= preview_content_end) break;
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
                    if (prow >= preview_content_end) break;
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

            // Shared Yes/No selector at the bottom of the preview panel
            const yes_selected = app.tool_confirmation.cursor == 0;
            _ = preview_win.printSegment(.{
                .text = if (yes_selected) " ❯ 1. Yes" else "   1. Yes",
                .style = .{ .fg = if (yes_selected) vaxis.Color{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else vaxis.Color{ .rgb = .{ 0x88, 0x88, 0x88 } }, .bold = yes_selected },
            }, .{ .row_offset = sel_row, .col_offset = 1 });

            const no_selected = app.tool_confirmation.cursor == 1;
            _ = preview_win.printSegment(.{
                .text = if (no_selected) " ❯ 2. No" else "   2. No",
                .style = .{ .fg = if (no_selected) vaxis.Color{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else vaxis.Color{ .rgb = .{ 0x88, 0x88, 0x88 } }, .bold = no_selected },
            }, .{ .row_offset = sel_row + 1, .col_offset = 1 });
        }

        // @picker overlay — rendered above the input box
        if (at_picker.active and at_picker.results.items.len > 0) {
            const n: u16 = @intCast(@min(at_picker.results.items.len, at_picker_mod.MAX_RESULTS));
            const picker_h: u16 = n + 2; // +2 for border
            const picker_y: u16 = if (layout.input_y >= picker_h) layout.input_y - picker_h else 0;
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

        if (command_picker.active and command_picker.results.items.len > 0) {
            command_picker.render(win, vx.screen.width, layout.input_y);
        }

        // /model picker overlay
        if (model_picker.active) {
            model_picker.render(win, vx.screen.width, vx.screen.height);
        }

        // /provider picker overlay
        if (provider_picker.active) {
            provider_picker.render(win, vx.screen.width, vx.screen.height);
        }

        const input_win = win.child(.{
            .x_off = 0,
            .y_off = layout.input_y,
            .width = vx.screen.width,
            .height = 3,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        if (app.tool_confirmation.pending) {
            var confirm_buf: [256]u8 = undefined;
            const action = if (std.mem.eql(u8, app.tool_confirmation.tool_name, "write_file")) "write" else if (std.mem.eql(u8, app.tool_confirmation.tool_name, "bash")) "run" else "edit";
            const confirm_text = std.fmt.bufPrint(&confirm_buf, " Allow agent to {s} '{s}'?  ↑↓ select   Enter confirm", .{
                action,
                app.tool_confirmation.file_path,
            }) catch " ↑↓ select  Enter confirm";
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
        const status_row: u16 = if (vx.screen.height == 0) 0 else vx.screen.height - 1;
        const status_bg: vaxis.Color = .{ .rgb = .{ 0x40, 0x40, 0x40 } };
        var status_buf: [128]u8 = undefined;

        // Model name — highlighted
        var res = win.printSegment(.{
            .text = std.fmt.bufPrint(&status_buf, " {s} ", .{llm_client.config.model}) catch " ? ",
            .style = .{ .bg = .{ .rgb = .{ 0x20, 0x60, 0xA0 } }, .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = status_row, .col_offset = 0 });

        // State / tool info
        var info_buf: [128]u8 = undefined;
        const info_text = if (app.tool_status) |tool|
            std.fmt.bufPrint(&info_buf, " TOOL: {s} ", .{tool}) catch " TOOL "
        else if (app.is_loading)
            " THINKING "
        else
            " READY ";
        res = win.printSegment(.{
            .text = info_text,
            .style = .{ .bg = status_bg, .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });

        var footer_buf: [128]u8 = undefined;
        const footer_text = if (clipboard_status) |status|
            std.fmt.bufPrint(&footer_buf, "{s}  ctrl+q: quit", .{status}) catch " ctrl+q: quit"
        else
            " ctrl+q: quit";
        _ = win.printSegment(.{
            .text = footer_text,
            .style = .{ .bg = status_bg, .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = status_row, .col_offset = res.col });

        try vx.render(tty.writer());
        app.needs_redraw = false;
        app.mutex.unlock();
    }
}

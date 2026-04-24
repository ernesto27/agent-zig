const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const app_mod = @import("App.zig");
const App = app_mod.App;
const chat_selection = @import("chat_selection.zig");
const layout_mod = @import("layout.zig");
const ui = @import("ui.zig");
const at_picker_mod = @import("at_picker.zig");
const command_picker_mod = @import("commands/command_picker.zig");
const model_picker_mod = @import("model_picker.zig");
const provider_picker_mod = @import("provider_picker.zig");

const log_mod = @import("log.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);
const app_version = agent.build.version;

pub const std_options: std.Options = .{
    .logFn = log_mod.Logger.logToFile,
};

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    log_mod.Logger.writeCrashReport(msg, trace, ret_addr);
    std.process.exit(1);
}

fn spawnLlmRequest(
    alloc: std.mem.Allocator,
    app: *App,
    loop: *EventLoop,
    spinner_state: *ui.SpinnerState,
    auto_scroll: *bool,
) !void {
    app.mutex.lock();
    try app.messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "") });
    app.setLoading(true);
    app.mutex.unlock();
    auto_scroll.* = true;
    const generation = spinner_state.generation.fetchAdd(1, .acq_rel) + 1;
    const spinner = try std.Thread.spawn(.{}, ui.spinnerThread, .{ app, loop, spinner_state, generation });
    spinner.detach();
    const thread = try std.Thread.spawn(.{}, App.fetchAiResponse, .{ app, loop });
    thread.detach();
}

fn runSlashCommand(
    alloc: std.mem.Allocator,
    action: command_picker_mod.CommandAction,
    input: *std.ArrayList(u8),
    cursor_pos: *usize,
    model_picker: *model_picker_mod.ModelPicker,
    provider_picker: *provider_picker_mod.ProviderPicker,
    app: *App,
) !bool {
    input.clearRetainingCapacity();
    cursor_pos.* = 0;

    switch (action) {
        .provider => provider_picker.open(),
        .model => try model_picker.open(alloc),
        .clear => app.clearHistory(),
        .resume_session => app.sessions.open(),
        .init => {
            if (app.is_loading) return false;
            try app.initCMD();
            return true;
        },
    }
    return false;
}

fn handleEscape(
    alloc: std.mem.Allocator,
    app: *App,
    loop: *EventLoop,
    at_picker: *at_picker_mod.AtPicker,
    command_picker: *command_picker_mod.CommandPicker,
    model_picker: *model_picker_mod.ModelPicker,
    provider_picker: *provider_picker_mod.ProviderPicker,
) !void {
    if (app.tool_confirmation.pending) {
        try app.resolveToolConfirmation(alloc, .deny);
    } else if (app.cancelActiveRequest(loop)) {
        return;
    } else if (at_picker.active) {
        at_picker.reset(alloc);
    } else if (command_picker.active) {
        command_picker.reset(alloc);
    } else if (model_picker.active) {
        model_picker.reset(alloc);
    } else if (provider_picker.active) {
        provider_picker.reset(alloc);
    } else if (app.sessions.active) {
        app.sessions.reset();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try log_mod.Logger.init(alloc);
    defer log_mod.Logger.deinit();

    const parsed_config = agent.config.load(alloc) catch {
        std.debug.print("Failed to load config. Create ~/.config/agent-zig/config.jhison\n", .{});
        return;
    };
    defer parsed_config.deinit();
    var config = parsed_config.value;

    var model_picker = model_picker_mod.ModelPicker.init();
    defer model_picker.deinit(alloc);

    var provider_picker = provider_picker_mod.ProviderPicker.init();
    defer provider_picker.deinit(alloc);

    var command_picker = command_picker_mod.CommandPicker.init();
    defer command_picker.deinit(alloc);

    var at_picker = at_picker_mod.AtPicker.init();
    defer at_picker.deinit(alloc);

    var llm_client_cfg = agent.llm.Config{
        .base_url = "",
        .api_key = "",
        .model = config.selected,
        .provider_name = "",
    };
    if (agent.llm.providers.findModel(config.selected)) |found| {
        llm_client_cfg.provider_name = found.provider.name;
        if (config.forProvider(found.provider.name)) |pc| {
            llm_client_cfg.base_url = pc.baseUrl;
            llm_client_cfg.api_key = pc.apiKey;
        }
    }
    var llm_client = agent.llm.Client.init(alloc, llm_client_cfg);
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
    try vx.setBracketedPaste(tty.writer(), true);

    if (!vx.state.in_band_resize) try loop.init();

    var running = true;
    var scroll_offset: usize = 0;
    var auto_scroll = true;
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
    var spinner_state = ui.SpinnerState{};
    var bracketed_paste = false;
    var paste_buf = std.ArrayList(u8){};
    defer paste_buf.deinit(alloc);

    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (bracketed_paste) {
                    if (key.text) |txt| {
                        try paste_buf.appendSlice(alloc, txt);
                    }
                    // Skip redraw during paste — one redraw at paste_end is enough
                    continue;
                }
                if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
                    running = false;
                } else if (key.matches('t', .{ .ctrl = true })) {
                    const model = model_picker_mod.findModel(llm_client.config.model);
                    if (model != null and model.?.model.supports_thinking) {
                        llm_client.config.effort = llm_client.config.effort.next();
                    }
                } else if (key.matches('a', .{ .ctrl = true })) {
                    app.tool_confirmation.cursor = .approve;
                } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    const modal_open =
                        app.tool_confirmation.pending or
                        at_picker.active or
                        command_picker.active or
                        model_picker.active or
                        provider_picker.active or
                        app.sessions.active;

                    if (!modal_open) {
                        app.toggleMode();
                    }
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    try handleEscape(alloc, &app, &loop, &at_picker, &command_picker, &model_picker, &provider_picker);
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (at_picker.active) {
                        if (at_picker.selected > 0) at_picker.selected -= 1;
                    } else if (command_picker.active) {
                        if (command_picker.selected > 0) command_picker.selected -= 1;
                    } else if (model_picker.active) {
                        if (model_picker.selected > 0) model_picker.selected -= 1;
                    } else if (provider_picker.active and provider_picker.phase == .list) {
                        if (provider_picker.selected > 0) provider_picker.selected -= 1;
                    } else if (app.sessions.active) {
                        if (app.sessions.selected > 0) {
                            app.sessions.selected -= 1;
                            if (app.sessions.selected < app.sessions.scroll)
                                app.sessions.scroll -= 1;
                        }
                    } else if (app.tool_confirmation.pending) {
                        app.tool_confirmation.cursor = switch (app.tool_confirmation.cursor) {
                            .approve => .accept_all,
                            .deny => .approve,
                            .accept_all => .deny,
                        };
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
                    } else if (app.sessions.active) {
                        if (app.sessions.selected + 1 < app.sessions.entries.items.len) {
                            app.sessions.selected += 1;
                            if (app.sessions.selected >= app.sessions.scroll + @TypeOf(app.sessions).max_visible)
                                app.sessions.scroll += 1;
                        }
                    } else if (app.tool_confirmation.pending) {
                        app.tool_confirmation.cursor = switch (app.tool_confirmation.cursor) {
                            .approve => .deny,
                            .deny => .accept_all,
                            .accept_all => .approve,
                        };
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
                            // Only refresh @ picker for single-char input during paste
                            if (txt.len == 1) {
                                at_picker.query.clearRetainingCapacity();
                                const after_at = input.items[at_picker.at_start + 1 .. cursor_pos];
                                try at_picker.query.appendSlice(alloc, after_at);
                                try at_picker.refresh(alloc);
                            }
                        }
                        if (txt.len == 1) {
                            try command_picker.updateFromInput(alloc, input.items);
                        }
                    }
                } else if (key.matches('\r', .{}) or key.matches('\n', .{})) {
                    if (app.tool_confirmation.pending) {
                        try app.resolveToolConfirmation(alloc, app.tool_confirmation.cursor);
                    } else if (command_picker.active) {
                        var should_send = false;
                        if (command_picker.selectedCommand()) |command| {
                            should_send = try runSlashCommand(alloc, command.action, &input, &cursor_pos, &model_picker, &provider_picker, &app);
                        }
                        command_picker.reset(alloc);
                        if (should_send and !app.is_loading) {
                            try spawnLlmRequest(alloc, &app, &loop, &spinner_state, &auto_scroll);
                        }
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
                        config.selected = selected.id;
                        if (agent.llm.providers.findModel(selected.id)) |found| {
                            app.llm_client.config.provider_name = found.provider.name;
                            if (config.forProvider(found.provider.name)) |pc| {
                                app.llm_client.config.base_url = pc.baseUrl;
                                app.llm_client.config.api_key = pc.apiKey;
                                pc.model = selected.id;
                            }
                        }
                        agent.config.save(alloc, config) catch {};
                        model_picker.reset(alloc);
                    } else if (provider_picker.active and provider_picker.phase == .list) {
                        provider_picker.phase = .key_input;
                    } else if (provider_picker.active and provider_picker.phase == .key_input) {
                        if (provider_picker.key_input.items.len > 0) {
                            const new_key = provider_picker.key_input.items;
                            const provider_name = provider_picker.selectedProvider().name;
                            app.llm_client.config.api_key = new_key;
                            app.llm_client.config.provider_name = provider_name;
                            if (config.forProvider(provider_name)) |pc| {
                                pc.apiKey = new_key;
                            }
                            agent.config.save(alloc, config) catch {};
                        }
                        provider_picker.reset(alloc);
                    } else if (app.sessions.active and app.sessions.entries.items.len > 0) {
                        const selected = app.sessions.entries.items[app.sessions.selected];
                        app.mutex.lock();
                        if (app.sessions.readFileContent(alloc, selected.filename)) |ctx| {
                            app.clearHistory();
                            app.messages.append(alloc, .{ .role = .user, .content = ctx }) catch {};
                            app.appendToHistory(alloc, ctx) catch {};
                            app.mutex.unlock();
                            std.log.info("session content:\n{s}", .{ctx});
                        } else |err| {
                            app.mutex.unlock();
                            std.log.err("failed to read session: {}", .{err});
                        }
                        app.sessions.reset();
                    } else if (input.items.len > 0 and !app.is_loading) {
                        app.mutex.lock();

                        const picked = at_picker.takePicked(alloc, input.items);
                        defer alloc.free(picked);
                        for (picked) |p| app.pending_attachments.append(alloc, p) catch alloc.free(p);

                        const user_text = try alloc.dupe(u8, input.items);
                        try app.messages.append(alloc, .{ .role = .user, .content = user_text });
                        app.mutex.unlock();

                        try history.append(alloc, try alloc.dupe(u8, input.items));
                        history_idx = null;
                        draft.clearRetainingCapacity();
                        input.clearRetainingCapacity();
                        cursor_pos = 0;

                        try spawnLlmRequest(alloc, &app, &loop, &spinner_state, &auto_scroll);
                    }
                }
                app.needs_redraw = true;
            },
            .paste_start => {
                bracketed_paste = true;
                paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                bracketed_paste = false;
                if (paste_buf.items.len > 0) {
                    try input.insertSlice(alloc, cursor_pos, paste_buf.items);
                    cursor_pos += paste_buf.items.len;
                }
                app.needs_redraw = true;
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    if (app.tool_confirmation.pending) {
                        if (app.preview_scroll > 0) app.preview_scroll -|= 3;
                    } else {
                        if (scroll_offset > 0) scroll_offset -|= 3;
                        auto_scroll = false;
                    }
                    app.needs_redraw = true;
                } else if (mouse.button == .wheel_down) {
                    if (app.tool_confirmation.pending) {
                        app.preview_scroll += 3;
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
                .thinking => |th| {
                    if (th.is_header) {
                        _ = chat_win.printSegment(.{
                            .text = "Thinking:",
                            .style = .{ .fg = .{ .rgb = .{ 0xCC, 0x80, 0x30 } }, .italic = true, .bold = true },
                        }, .{ .row_offset = row, .col_offset = 2 });
                    } else if (th.text.len > 0) {
                        _ = chat_win.printSegment(.{
                            .text = th.text,
                            .style = .{ .fg = .{ .rgb = .{ 0x77, 0x77, 0x77 } } },
                        }, .{ .row_offset = row, .col_offset = 2 });
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
        ui.renderTools(frame_arena.allocator(), win, vx.screen.width, layout.preview_y, layout.preview_h, &app, app.preview_scroll);

        // @picker overlay — rendered above the input box
        if (at_picker.active and at_picker.results.items.len > 0) {
            at_picker.render(win, vx.screen.width, layout.input_y);
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

        // /resume session picker overlay
        if (app.sessions.active) {
            app.sessions.render(win, vx.screen.width, vx.screen.height);
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
            const confirm_text = std.fmt.bufPrint(&confirm_buf, " Allow agent to {s} '{s}'?  ↑↓ select   Enter confirm   Esc cancel", .{
                action,
                app.tool_confirmation.file_path,
            }) catch " ↑↓ select  Enter confirm  Esc cancel";
            _ = input_win.printSegment(.{
                .text = confirm_text,
                .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
            }, .{ .row_offset = 0, .col_offset = 1 });
        } else {
            const prompt = if (app.is_loading) ui.loading(app.getElapsedSeconds() orelse 0) else "> ";
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
        ui.renderStatus(
            win,
            vx.screen.width,
            status_row,
            &app,
            llm_client.config.model,
            llm_client.config.effort,
            app_version,
            clipboard_status,
        );

        try vx.render(tty.writer());
        app.needs_redraw = false;
        app.mutex.unlock();
    }
}

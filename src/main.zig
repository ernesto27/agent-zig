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
const input_handler = @import("input_handler.zig");

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

    var show_exit: bool = false;

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
    var spinner_state = ui.SpinnerState{};
    var ctx = input_handler.InputContext{
        .alloc = alloc,
        .app = &app,
        .loop = &loop,
        .at_picker = &at_picker,
        .command_picker = &command_picker,
        .model_picker = &model_picker,
        .provider_picker = &provider_picker,
        .spinner_state = &spinner_state,
        .auto_scroll = &auto_scroll,
        .config = &config,
        .show_exit = &show_exit,
        .input = .{},
        .cursor_pos = 0,
        .history = .{},
        .history_idx = null,
        .draft = .{},
    };
    defer {
        ctx.input.deinit(alloc);
        ctx.draft.deinit(alloc);
        for (ctx.history.items) |s| alloc.free(s);
        ctx.history.deinit(alloc);
    }
    var selection: chat_selection.SelectionState = .{};
    var clipboard_status: ?[]const u8 = null;
    var bracketed_paste = false;
    var paste_buf = std.ArrayList(u8){};
    defer paste_buf.deinit(alloc);

    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (bracketed_paste) {
                    if (key.text) |txt| try paste_buf.appendSlice(alloc, txt);
                    // Skip redraw during paste — one redraw at paste_end is enough
                    continue;
                }
                if (try input_handler.handleKey(&ctx, key)) running = false;
                app.needs_redraw = true;
            },
            .paste_start => {
                bracketed_paste = true;
                paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                bracketed_paste = false;
                try input_handler.handlePasteEnd(&ctx, paste_buf.items);
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
                    const input_layout = ui.buildInputLayout(mouse_arena.allocator(), &app, ctx.input.items, vx.screen.width, ctx.cursor_pos);
                    const layout = layout_mod.compute(vx.screen.height, &app, input_layout.view.box_h);
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

        const input_layout = ui.buildInputLayout(frame_arena.allocator(), &app, ctx.input.items, vx.screen.width, ctx.cursor_pos);
        const layout = layout_mod.compute(vx.screen.height, &app, input_layout.view.box_h);

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
            .height = input_layout.view.box_h,
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
            ui.renderInput(input_win, input_layout.prompt, ctx.input.items, ctx.cursor_pos, input_layout.view);
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
            show_exit,
        );

        try vx.render(tty.writer());
        app.needs_redraw = false;
        app.mutex.unlock();
    }
}

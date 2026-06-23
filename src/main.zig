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
const mcp_picker_mod = @import("mcp_picker.zig");
const trust_dialog_mod = @import("trust_dialog.zig");

const log_mod = @import("log.zig");
const input_handler = @import("input_handler.zig");
const attach_preview = @import("attach_preview.zig");
const cli = @import("cli/common.zig");
const update = @import("cli/update.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);
const app_version = agent.build.version;

fn versionCheckThread(app: *App, loop: *EventLoop) void {
    const v = update.checkNewVersion(app.alloc) catch null;
    if (v) |ver| {
        app.mutex.lock();
        app.latest_version = ver;
        app.needs_redraw = true;
        app.mutex.unlock();
        ui.wakeLoop(loop);
    }
}

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

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len > 1) {
        const cmd = args[1];
        if (cli.dispatch(alloc, cmd)) return;

        std.debug.print("unknown command: {s}\n", .{cmd});
        std.process.exit(1);
    }

    try log_mod.Logger.init(alloc);
    defer log_mod.Logger.deinit();

    var config_store = agent.config.ConfigStore.init(alloc) catch {
        std.debug.print("Failed to load config. Create ~/.config/agent-zig/config.json\n", .{});
        return;
    };
    defer config_store.deinit();

    var model_picker = model_picker_mod.ModelPicker.init();
    defer model_picker.deinit(alloc);

    var provider_picker = provider_picker_mod.ProviderPicker.init();
    defer provider_picker.deinit(alloc);

    var mcp_picker = mcp_picker_mod.McpPicker.init();
    defer mcp_picker.deinit(alloc);

    var trust_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trust_cwd: ?[]const u8 = std.fs.realpath(".", &trust_cwd_buf) catch std.posix.getcwd(&trust_cwd_buf) catch null;
    var trust_dialog = trust_dialog_mod.TrustDialog.init();
    if (trust_cwd) |cwd| {
        if (!agent.config.isTrusted(config_store.cfg.trustedFolders, cwd)) trust_dialog.open(cwd);
    }

    var show_exit: bool = false;

    var at_picker = at_picker_mod.AtPicker.init();
    defer at_picker.deinit(alloc);

    var llm_client_cfg = agent.llm.Config{
        .base_url = "",
        .api_key = "",
        .model = config_store.cfg.providers.selected,
        .provider_name = "",
    };
    if (agent.llm.providers.findModel(config_store.cfg.providers.selected)) |found| {
        llm_client_cfg.provider_name = found.provider.name;
        if (config_store.cfg.providers.forProvider(found.provider.name)) |pc| {
            llm_client_cfg.base_url = pc.baseUrl;
            llm_client_cfg.api_key = pc.apiKey;
            llm_client_cfg.effort = config_store.thinkEffort(found.provider.name);
        }
    }
    var llm_client = agent.llm.Client.init(alloc, llm_client_cfg);
    defer llm_client.deinit();

    var app = App.init(alloc, &llm_client, &config_store);
    defer app.deinit();
    app.loadMcpServers(config_store.cfg.mcpServers);

    var command_picker = command_picker_mod.CommandPicker.init(&app.skill_registry);
    defer command_picker.deinit(alloc);

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
        .mcp_picker = &mcp_picker,
        .trust_dialog = &trust_dialog,
        .spinner_state = &spinner_state,
        .auto_scroll = &auto_scroll,
        .config = &config_store,
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
    var input_selection: chat_selection.InputSelectionState = .{};
    var clipboard_status: ?[]const u8 = null;
    var pending_images = std.ArrayList(attach_preview.PendingImage){};
    defer attach_preview.deinitPendingImages(alloc, &vx, &tty, &pending_images);
    var bracketed_paste = false;
    var paste_buf = std.ArrayList(u8){};
    defer paste_buf.deinit(alloc);

    const version_thread = try std.Thread.spawn(.{}, versionCheckThread, .{ &app, &loop });
    version_thread.detach();

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
                input_selection.clear();
                app.needs_redraw = true;
            },
            .paste_start => {
                bracketed_paste = true;
                paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                bracketed_paste = false;
                try input_handler.handlePasteEnd(&ctx, paste_buf.items);
                input_selection.clear();
                app.needs_redraw = true;
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    if (app.tool_confirmation.pending or app.pending_attachments.items.len > 0) {
                        if (app.preview_scroll > 0) app.preview_scroll -|= 3;
                    } else {
                        if (scroll_offset > 0) scroll_offset -|= 3;
                        auto_scroll = false;
                    }
                    app.needs_redraw = true;
                } else if (mouse.button == .wheel_down) {
                    if (app.tool_confirmation.pending or app.pending_attachments.items.len > 0) {
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
                    const layout = layout_mod.compute(vx.screen.height, &app, input_layout.view.box_h, vx.caps.kitty_graphics);
                    const rendered_lines = chat_selection.buildRenderedLines(&app, mouse_arena.allocator(), if (vx.screen.width > 0) vx.screen.width else 1, vx.screen.width_method) catch &.{};
                    app.mutex.unlock();

                    const chat_win = vx.window().child(.{
                        .x_off = 0,
                        .y_off = layout.chat_y,
                        .width = vx.screen.width,
                        .height = layout.chat_h_total,
                        .border = .{ .where = .all, .glyphs = .single_rounded },
                    });

                    const input_win = vx.window().child(.{
                        .x_off = 0,
                        .y_off = layout.input_y,
                        .width = vx.screen.width,
                        .height = input_layout.view.box_h,
                        .border = .{ .where = .all, .glyphs = .single_rounded },
                    });

                    const handle_input_selection =
                        !app.tool_confirmation.pending and
                        (input_selection.dragging or
                            (mouse.type == .press and ui.inputPointFromMouse(mouse, input_win, input_layout.prompt, input_layout.view, &app) != null));

                    if (handle_input_selection) {
                        selection.clear();
                        const mouse_result = ui.handleInputMouseSelection(
                            alloc,
                            mouse,
                            &input_selection,
                            input_win,
                            input_layout.prompt,
                            ctx.input.items,
                            input_layout.view,
                            &app,
                        ) catch blk: {
                            clipboard_status = " copy failed ";
                            app.needs_redraw = true;
                            break :blk null;
                        };
                        if (mouse_result) |result| {
                            if (result.clear_status) clipboard_status = null;
                            if (result.status) |status| clipboard_status = status;
                            if (result.needs_redraw) app.needs_redraw = true;
                            if (result.copied_text) |text| {
                                defer alloc.free(text);
                                vx.copyToSystemClipboard(tty.writer(), text, alloc) catch {
                                    clipboard_status = " copy failed ";
                                    app.needs_redraw = true;
                                    break;
                                };
                                clipboard_status = " copied input ";
                            }
                        }
                    } else {
                        if (mouse.type == .press) input_selection.clear();
                        const mouse_result = chat_selection.handleMouseSelection(
                            alloc,
                            mouse,
                            &selection,
                            chat_win,
                            scroll_offset,
                            rendered_lines,
                            vx.screen.width_method,
                        ) catch blk: {
                            clipboard_status = " copy failed ";
                            app.needs_redraw = true;
                            break :blk null;
                        };
                        if (mouse_result) |result| {
                            if (result.clear_status) clipboard_status = null;
                            if (result.status) |status| clipboard_status = status;
                            if (result.needs_redraw) app.needs_redraw = true;
                            if (result.copied_text) |text| {
                                defer alloc.free(text);
                                vx.copyToSystemClipboard(tty.writer(), text, alloc) catch {
                                    clipboard_status = " copy failed ";
                                    app.needs_redraw = true;
                                    break;
                                };
                                clipboard_status = " copied selection ";
                            }
                        }
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

        try attach_preview.syncPendingImages(alloc, &vx, &tty, &app, &pending_images);

        var frame_arena = std.heap.ArenaAllocator.init(alloc);
        defer frame_arena.deinit();

        // Header
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = agent.utils.getCwdPretty(&cwd_buf) catch "";
        var branch_buf: [std.fs.max_path_bytes]u8 = undefined;
        const currentBranch = agent.utils.getCurrentGitBranch(&branch_buf) catch "";
        var header_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const base_header = if (currentBranch.len > 0)
            std.fmt.bufPrint(&header_buf, "{s}:{s}", .{ cwd, currentBranch }) catch cwd
        else
            cwd;
        var sandbox_header_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const header = if (app.sandbox.active)
            std.fmt.bufPrint(&sandbox_header_buf, "{s}  🐳 sandbox", .{base_header}) catch base_header
        else
            base_header;
        ui.renderHeader(win, header);

        const input_layout = ui.buildInputLayout(frame_arena.allocator(), &app, ctx.input.items, vx.screen.width, ctx.cursor_pos);
        const layout = layout_mod.compute(vx.screen.height, &app, input_layout.view.box_h, vx.caps.kitty_graphics);

        if (!app.tool_confirmation.pending and app.pending_attachments.items.len > 0 and layout.preview_h > 0) {
            const inner_preview_h: usize = if (layout.preview_h > 2) layout.preview_h - 2 else 0;
            const preview_rows = attach_preview.totalContentRows(app.pending_attachments.items, vx.caps.kitty_graphics);
            const max_preview_scroll = if (preview_rows > inner_preview_h) preview_rows - inner_preview_h else 0;
            if (app.preview_scroll > max_preview_scroll) app.preview_scroll = max_preview_scroll;
        } else if (!app.tool_confirmation.pending) {
            app.preview_scroll = 0;
        }

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

        const start = if (app.messages.isEmpty()) blk: {
            const banner_rows: u16 = if (app.latest_version) |v| blk2: {
                ui.renderUpdateBanner(chat_win, v);
                break :blk2 1;
            } else 0;
            ui.renderWelcome(chat_win, app.skill_registry, config_store.cfg.mcpServers, app.system_prompt.agents_md_exists, banner_rows);
            break :blk 0;
        } else ui.renderChatLines(chat_win, rendered_lines, scroll_offset);

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
        ui.renderAttachPreview(frame_arena.allocator(), win, vx.screen.width, layout.preview_y, layout.preview_h, &app, pending_images.items, vx.caps.kitty_graphics, app.preview_scroll);

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

        if (mcp_picker.active) {
            mcp_picker.render(win, vx.screen.width, vx.screen.height);
        }

        if (trust_dialog.active) {
            trust_dialog.render(win, vx.screen.width, vx.screen.height);
        }

        // /resume session picker overlay
        if (app.sessions.active) {
            app.sessions.render(win, vx.screen.width, vx.screen.height);
        }

        if (app.sessions.rename_active) {
            app.sessions.renderRename(win, vx.screen.width, vx.screen.height);
        }

        if (app.loading.active) ui.renderShowLoading(win, &app, layout.loading_y);
        if (!app.tool_confirmation.pending) app.message_queue.render(win, layout.queue_y, layout.queue_h);

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
            ui.renderInput(input_win, input_layout.prompt, ctx.input.items, ctx.cursor_pos, input_layout.view, &app, ui.inputSelectionBounds(input_selection, input_layout.view));
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

const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig");
const ui = @import("ui.zig");

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
    var buf: [2048]u8 = undefined;
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
        std.debug.print("Failed to load config. Create ~/.config/agent-zig/config.json\n", .{});
        return;
    };
    defer parsed_config.deinit();
    const config = parsed_config.value;

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

    if (!vx.state.in_band_resize) try loop.init();

    var running = true;
    var scroll_offset: usize = 0;
    var auto_scroll = true;
    var input = std.ArrayList(u8){};
    defer input.deinit(alloc);

    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
                    running = false;
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (scroll_offset > 0) scroll_offset -= 1;
                    auto_scroll = false;
                } else if (key.matches(vaxis.Key.down, .{})) {
                    scroll_offset += 1;
                    // Will re-enable auto_scroll in render if at bottom
                } else if (key.codepoint == 127 or key.codepoint == 8) {
                    if (input.items.len > 0) input.items.len -= 1;
                } else if (key.text) |txt| {
                    if (txt.len > 0) try input.appendSlice(alloc, txt);
                } else if (key.matches('\r', .{}) or key.matches('\n', .{})) {
                    if (input.items.len > 0 and !app.is_loading) {
                        app.mutex.lock();
                        const user_text = try alloc.dupe(u8, input.items);
                        try app.messages.append(alloc, .{ .role = .user, .content = user_text });
                        try app.messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "") });
                        app.is_loading = true;
                        app.mutex.unlock();

                        input.clearRetainingCapacity();
                        auto_scroll = true;

                        // Spawn background thread
                        const thread = try std.Thread.spawn(.{}, App.fetchAiResponse, .{ &app, &loop });
                        thread.detach();
                    }
                }
                app.needs_redraw = true;
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
        const chat_h_total: u16 = if (vx.screen.height > 1 + input_box_h + 1) vx.screen.height - 1 - input_box_h - 1 else 1;
        const input_y: u16 = chat_y + chat_h_total;

        // Chat area
        const chat_win = win.child(.{
            .x_off = 0,
            .y_off = chat_y,
            .width = vx.screen.width,
            .height = chat_h_total,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const chat_h = chat_win.height;

        // Pre-compute all wrapped lines to enable proper scrolling
        const max_total_lines = 2048;
        var all_lines: [max_total_lines]struct { text: []const u8, prefix: []const u8, role: App.Role, is_first: bool } = undefined;
        var total_lines: usize = 0;

        for (app.messages.items) |msg| {
            const prefix = if (msg.role == .user) "You: " else "AI: ";
            const prefix_len = @as(u16, @intCast(prefix.len));
            const wrap_w = if (chat_win.width > prefix_len + 3) chat_win.width - prefix_len - 3 else 10;
            const wrapped = ui.wrapText(msg.content, wrap_w, 512);

            for (wrapped, 0..) |maybe_line, li| {
                const line = maybe_line orelse break;
                if (total_lines >= max_total_lines) break;
                all_lines[total_lines] = .{
                    .text = line,
                    .prefix = prefix,
                    .role = msg.role,
                    .is_first = li == 0,
                };
                total_lines += 1;
            }
        }

        // Clamp scroll_offset and handle auto-scroll
        const max_scroll = if (total_lines > chat_h) total_lines - chat_h else 0;
        if (auto_scroll) {
            scroll_offset = max_scroll;
        } else if (scroll_offset >= max_scroll) {
            scroll_offset = max_scroll;
            auto_scroll = true; // Re-enable when user scrolls to bottom
        }

        var row: u16 = 0;
        const start = if (scroll_offset < total_lines) scroll_offset else 0;
        for (all_lines[start..total_lines]) |entry| {
            if (row >= chat_h) break;
            if (entry.is_first) {
                _ = chat_win.printSegment(.{
                    .text = entry.prefix,
                    .style = .{ .fg = .{ .rgb = if (entry.role == .user) .{ 0x60, 0xD0, 0x60 } else .{ 0x60, 0xA0, 0xF0 } }, .bold = true },
                }, .{ .row_offset = row, .col_offset = 1 });
            }
            const prefix_len = @as(u16, @intCast(entry.prefix.len));
            _ = chat_win.printSegment(.{ .text = entry.text }, .{ .row_offset = row, .col_offset = 1 + prefix_len });
            row += 1;
        }

        // Input box with border
        const input_win = win.child(.{
            .x_off = 0,
            .y_off = input_y,
            .width = vx.screen.width,
            .height = input_box_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });
        const prompt = if (app.is_loading) "... " else "> ";
        _ = input_win.printSegment(.{
            .text = prompt,
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });
        _ = input_win.printSegment(.{
            .text = input.items,
            .style = .{ .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 + @as(u16, @intCast(prompt.len)) });

        // Status
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, " messages: {d} | {s} | ctrl+q: quit ", .{ app.messages.items.len, if (app.is_loading) "THINKING" else "READY" }) catch "status";
        _ = win.printSegment(.{ .text = status, .style = .{ .bg = .{ .rgb = .{ 0x40, 0x40, 0x40 } }, .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } } } }, .{ .row_offset = if (vx.screen.height == 0) 0 else vx.screen.height - 1, .col_offset = 0 });

        try vx.render(tty.writer());
        app.needs_redraw = false;
        app.mutex.unlock();
    }
}

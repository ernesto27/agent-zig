const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const Role = enum { user, assistant };

pub const Message = struct {
    role: Role,
    content: []const u8,
    styled_lines: ?[]const agent.markdown.StyledLine = null,
    styled_content_len: usize = 0,
};

pub const ToolConfirmation = struct {
    pending: bool = false,
    tool_name: []const u8 = "",
    file_path: []const u8 = "",
    approved: bool = false,
    cond: std.Thread.Condition = .{},
    content: []const u8 = "",
    old_string: []const u8 = "",
    new_string: []const u8 = "",
};

tool_confirmation: ToolConfirmation = .{},
preview_scroll: usize = 0,
alloc: std.mem.Allocator,
messages: std.ArrayList(Message),
llm_history: std.ArrayList(agent.llm.Message),
llm_client: *agent.llm.Client,
pending_attachments: std.ArrayList([]u8),
mutex: std.Thread.Mutex = .{},
is_loading: bool = false,
needs_redraw: bool = true,
tool_status: ?[]const u8 = null,

const App = @This();
const log = std.log.scoped(.app);

pub fn init(alloc: std.mem.Allocator, client: *agent.llm.Client) App {
    return .{
        .alloc = alloc,
        .messages = .{},
        .llm_history = .{},
        .llm_client = client,
        .pending_attachments = .{},
    };
}

pub fn deinit(self: *App) void {
    for (self.messages.items) |*msg| {
        self.alloc.free(msg.content);
        if (msg.styled_lines) |lines| agent.markdown.freeLines(self.alloc, lines);
    }
    self.messages.deinit(self.alloc);
    self.llm_history.deinit(self.alloc);
    self.clearPendingAttachments();
    self.pending_attachments.deinit(self.alloc);
}

fn clearPendingAttachments(self: *App) void {
    for (self.pending_attachments.items) |p| self.alloc.free(p);
    self.pending_attachments.clearRetainingCapacity();
}

pub fn getStyledLines(self: *App, msg: *Message) ![]const agent.markdown.StyledLine {
    if (msg.styled_lines != null and msg.styled_content_len == msg.content.len) {
        return msg.styled_lines.?;
    }
    if (msg.styled_lines) |old| agent.markdown.freeLines(self.alloc, old);
    msg.styled_lines = try agent.markdown.parse(self.alloc, msg.content);
    msg.styled_content_len = msg.content.len;
    return msg.styled_lines.?;
}

const StreamCtx = struct {
    app: *App,
    loop: *EventLoop,
};

fn onChunk(ctx_ptr: *anyopaque, chunk: []const u8) void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
    const app = ctx.app;

    app.mutex.lock();
    defer app.mutex.unlock();

    if (app.messages.items.len == 0) return;
    const last = &app.messages.items[app.messages.items.len - 1];

    // Grow the last message's content by appending the new chunk
    const new_content = std.mem.concat(app.alloc, u8, &.{ last.content, chunk }) catch return;
    app.alloc.free(last.content);
    last.content = new_content;

    app.needs_redraw = true;
    wakeLoop(ctx.loop);
}

fn wakeLoop(loop: *EventLoop) void {
    loop.postEvent(.{ .winsize = .{
        .rows = loop.vaxis.screen.height,
        .cols = loop.vaxis.screen.width,
        .x_pixel = 0,
        .y_pixel = 0,
    } });
}

/// Background thread: sends messages to LLM, executes tools, loops until done
pub fn fetchAiResponse(self: *App, loop: *EventLoop) void {
    const alloc = self.alloc;

    // 1. Snapshot the user's message into llm_history
    self.mutex.lock();
    const last_user_msg = if (self.messages.items.len >= 2)
        self.messages.items[self.messages.items.len - 2].content
    else
        "";

    const user_text = blk: {
        var out = std.ArrayList(u8){};
        out.appendSlice(alloc, last_user_msg) catch {
            out.deinit(alloc);
            self.is_loading = false;
            self.mutex.unlock();
            return;
        };

        const max_size = 512 * 1024;
        for (self.pending_attachments.items) |path| {
            const file = (if (std.fs.path.isAbsolute(path))
                std.fs.openFileAbsolute(path, .{})
            else
                std.fs.cwd().openFile(path, .{})) catch continue;
            defer file.close();
            const contents = file.readToEndAlloc(alloc, max_size) catch continue;
            defer alloc.free(contents);
            out.appendSlice(alloc, "\n\n<file path=\"") catch {};
            out.appendSlice(alloc, path) catch {};
            out.appendSlice(alloc, "\">\n") catch {};
            out.appendSlice(alloc, contents) catch {};
            out.appendSlice(alloc, "\n</file>") catch {};
        }

        self.clearPendingAttachments();
        break :blk out.toOwnedSlice(alloc) catch {
            out.deinit(alloc);
            self.is_loading = false;
            self.mutex.unlock();
            return;
        };
    };

    self.llm_history.append(alloc, .{
        .role = .user,
        .content = .{ .text = user_text },
    }) catch {};
    self.mutex.unlock();

    // 2. Get tool definitions (arena keeps parsed JSON alive)
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const tool_defs = agent.tools.getDefinitions(arena_alloc) catch &.{};

    // 3. Agentic loop — keep all parsed responses alive until loop ends so that
    //    content_blocks stored in llm_history can safely reference their JSON arenas.
    var responses = std.ArrayList(std.json.Parsed(agent.llm.message.MessagesResponse)){};
    defer {
        for (responses.items) |*r| r.deinit();
        responses.deinit(alloc);
    }

    const max_iterations = 10;
    var iteration: usize = 0;

    while (iteration < max_iterations) : (iteration += 1) {
        log.info("agentic loop iteration {d}, history size {d}", .{ iteration, self.llm_history.items.len });

        // Log outgoing messages
        log.info("--- REQUEST ({d} messages) ---", .{self.llm_history.items.len});
        for (self.llm_history.items) |msg| {
            const role_str = @tagName(msg.role);
            switch (msg.content) {
                .text => |t| log.info("[{s}] {s}", .{ role_str, t }),
                .tool_result_blocks => |blocks| for (blocks) |b| {
                    log.info("[{s}] tool_result id={s} content={s}", .{ role_str, b.tool_use_id, b.content });
                },
                .content_blocks => |blocks| for (blocks) |b| {
                    if (b.text) |t| log.info("[{s}] text: {s}", .{ role_str, t });
                    if (b.name) |n| log.info("[{s}] tool_use: {s}", .{ role_str, n });
                },
            }
        }

        // Call LLM (non-streaming)
        const resp = self.llm_client.sendMessage(alloc, self.llm_history.items, tool_defs) catch |err| {
            log.err("sendMessage failed: {}", .{err});
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.messages.items.len > 0) {
                const last = &self.messages.items[self.messages.items.len - 1];
                alloc.free(last.content);
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "(error: {})", .{err}) catch "(error)";
                last.content = alloc.dupe(u8, msg) catch "";
            }
            break;
        };
        responses.append(alloc, resp) catch {
            resp.deinit();
            break;
        };
        const resp_ref = &responses.items[responses.items.len - 1];

        const response = resp_ref.value;
        log.info("--- RESPONSE stop_reason={s} tokens={d}in/{d}out ---", .{
            response.stop_reason orelse "null",
            response.usage.input_tokens,
            response.usage.output_tokens,
        });
        for (response.content) |block| {
            if (std.mem.eql(u8, block.type, "text")) {
                log.info("[assistant] text: {s}", .{block.text orelse ""});
            } else if (std.mem.eql(u8, block.type, "tool_use")) {
                log.info("[assistant] tool_use: {s} id={s}", .{ block.name orelse "", block.id orelse "" });
            }
        }

        // Collect text and tool_use blocks
        var text_buf = std.ArrayList(u8){};
        defer text_buf.deinit(alloc);

        const ToolUse = struct { id: []const u8, name: []const u8, input: std.json.Value };
        var tool_uses = std.ArrayList(ToolUse){};
        defer tool_uses.deinit(alloc);

        for (response.content) |block| {
            if (std.mem.eql(u8, block.type, "text")) {
                if (block.text) |t| text_buf.appendSlice(alloc, t) catch {};
            } else if (std.mem.eql(u8, block.type, "tool_use")) {
                tool_uses.append(alloc, .{
                    .id = alloc.dupe(u8, block.id orelse "") catch "",
                    .name = alloc.dupe(u8, block.name orelse "") catch "",
                    .input = block.input,
                }) catch {};
            }
        }

        // Update display with any text
        if (text_buf.items.len > 0) {
            self.mutex.lock();
            if (self.messages.items.len > 0) {
                const last = &self.messages.items[self.messages.items.len - 1];
                const sep: []const u8 = if (last.content.len > 0 and last.content[last.content.len - 1] != '\n') "\n" else "";
                const new_content = std.mem.concat(alloc, u8, &.{ last.content, sep, text_buf.items }) catch last.content;
                if (new_content.ptr != last.content.ptr) alloc.free(last.content);
                last.content = new_content;
            }
            self.needs_redraw = true;
            self.mutex.unlock();
            wakeLoop(loop);
        }

        // Check stop reason
        const is_tool_use = if (response.stop_reason) |sr| std.mem.eql(u8, sr, "tool_use") else false;
        if (!is_tool_use or tool_uses.items.len == 0) {
            // No tools — append assistant text to history and done
            if (text_buf.items.len > 0) {
                const duped = alloc.dupe(u8, text_buf.items) catch break;
                self.llm_history.append(alloc, .{
                    .role = .assistant,
                    .content = .{ .text = duped },
                }) catch {};
            }
            break;
        }

        // Append assistant's tool_use blocks to history.
        // Deep-copy block.input: the source lives in resp's arena which is freed after
        // this fetchAiResponse call ends, but llm_history must survive across calls.
        const content_blocks = alloc.alloc(agent.llm.message.ContentBlock, response.content.len) catch break;
        for (response.content, 0..) |block, i| {
            const input_copy: std.json.Value = if (block.input != .null) blk: {
                const json_str = std.json.Stringify.valueAlloc(alloc, block.input, .{}) catch break :blk .null;
                defer alloc.free(json_str);
                break :blk std.json.parseFromSliceLeaky(std.json.Value, alloc, json_str, .{}) catch .null;
            } else .null;
            content_blocks[i] = .{
                .type = alloc.dupe(u8, block.type) catch "",
                .text = if (block.text) |t| alloc.dupe(u8, t) catch null else null,
                .id = if (block.id) |id| alloc.dupe(u8, id) catch null else null,
                .name = if (block.name) |n| alloc.dupe(u8, n) catch null else null,
                .input = input_copy,
            };
        }
        self.llm_history.append(alloc, .{
            .role = .assistant,
            .content = .{ .content_blocks = content_blocks },
        }) catch {};

        // Execute each tool
        const tool_results = alloc.alloc(agent.llm.message.ToolResultBlock, tool_uses.items.len) catch break;
        for (tool_uses.items, 0..) |tool_use, i| {
            log.info("executing tool: {s}", .{tool_use.name});
            const needs_confirmation =
                std.mem.eql(u8, tool_use.name, "write_file") or
                std.mem.eql(u8, tool_use.name, "edit_file");

            if (needs_confirmation) {
                const fp = agent.tools.getStringField(tool_use.input, "file_path") orelse "";
                const cnt = agent.tools.getStringField(tool_use.input, "content") orelse "";
                const old_s = agent.tools.getStringField(tool_use.input, "old_string") orelse "";
                const new_s = agent.tools.getStringField(tool_use.input, "new_string") orelse "";

                self.mutex.lock();
                self.tool_confirmation.pending = true;
                self.tool_confirmation.tool_name = tool_use.name;
                self.tool_confirmation.file_path = fp;
                self.tool_confirmation.content = cnt;
                self.tool_confirmation.old_string = old_s;
                self.tool_confirmation.new_string = new_s;
                self.tool_confirmation.approved = false;
                self.tool_status = tool_use.name;
                self.needs_redraw = true;
                self.mutex.unlock();
                wakeLoop(loop);

                self.mutex.lock();
                while (self.tool_confirmation.pending) {
                    self.tool_confirmation.cond.wait(&self.mutex);
                }
                const approved = self.tool_confirmation.approved;
                self.mutex.unlock();

                if (!approved) {
                    tool_results[i] = .{
                        .tool_use_id = tool_use.id,
                        .content = "User denied permission",
                        .is_error = true,
                    };
                    continue;
                }
            }

            const result = agent.tools.execute(alloc, tool_use.name, tool_use.input);
            log.info("tool result: is_error={}, content_len={d}", .{ result.is_error, result.content.len });
            tool_results[i] = .{
                .tool_use_id = tool_use.id,
                .content = result.content,
                .is_error = result.is_error,
            };
        }

        // Append tool results as user message, loop back
        self.llm_history.append(alloc, .{
            .role = .user,
            .content = .{ .tool_result_blocks = tool_results },
        }) catch {};

        log.info("tool results appended, looping back", .{});
        self.mutex.lock();
        self.tool_status = null;
        self.mutex.unlock();
    }

    // Done
    self.mutex.lock();
    self.is_loading = false;
    self.tool_status = null;
    self.needs_redraw = true;
    self.mutex.unlock();
    wakeLoop(loop);
}

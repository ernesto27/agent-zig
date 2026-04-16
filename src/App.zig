const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const context_usage_mod = @import("context_usage.zig");
const sessions = @import("sessions.zig");
const init_mod = @import("commands/init.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const Role = enum { user, assistant };

pub const Message = struct {
    role: Role,
    content: []const u8,
    thinking: ?[]const u8 = null,
    styled_lines: ?[]const agent.markdown.StyledLine = null,
    styled_content_len: usize = 0,
};

pub const ToolConfirmation = struct {
    pending: bool = false,
    tool_name: []const u8 = "",
    file_path: []const u8 = "",
    cond: std.Thread.Condition = .{},
    content: []const u8 = "",
    old_string: []const u8 = "",
    new_string: []const u8 = "",
    cursor: ConfirmationAction = .approve,
};

pub const GrepStatus = struct {
    pattern: []const u8 = "",
    path: []const u8 = ".",
    include: []const u8 = "",

    pub fn deinit(self: *GrepStatus, alloc: std.mem.Allocator) void {
        if (self.pattern.len > 0) alloc.free(self.pattern);
        if (self.path.len > 0 and !std.mem.eql(u8, self.path, ".")) alloc.free(self.path);
        if (self.include.len > 0) alloc.free(self.include);
        self.* = .{};
    }
};

pub const GlobStatus = struct {
    pattern: []const u8 = "",
    path: []const u8 = ".",

    pub fn deinit(self: *GlobStatus, alloc: std.mem.Allocator) void {
        if (self.pattern.len > 0) alloc.free(self.pattern);
        if (self.path.len > 0 and !std.mem.eql(u8, self.path, ".")) alloc.free(self.path);
        self.* = .{};
    }
};

pub const ConfirmationAction = enum { approve, deny, accept_all };
pub const App = struct {
    tool_confirmation: ToolConfirmation = .{},
    preview_scroll: usize = 0,
    alloc: std.mem.Allocator,
    messages: std.ArrayList(Message),
    llm_history: std.ArrayList(agent.llm.Message),
    llm_client: *agent.llm.Client,
    pending_attachments: std.ArrayList([]u8),
    system_prompt: agent.system_prompt.SystemPrompt = .{},
    sessions: sessions.Sessions = .{},
    init_cmd: init_mod.Init = .{},
    mutex: std.Thread.Mutex = .{},
    is_loading: bool = false,
    start_time: ?i64 = null,
    needs_redraw: bool = true,
    tool_status: ?[]const u8 = null,
    grep_status: GrepStatus = .{},
    glob_status: GlobStatus = .{},
    cancel_requested: bool = false,
    context_usage: context_usage_mod.contextUsage = .{},

    const Self = @This();
    const log = std.log.scoped(.app);

    pub fn init(alloc: std.mem.Allocator, client: *agent.llm.Client) Self {
        var sp = agent.system_prompt.SystemPrompt{};
        sp.readContent(alloc) catch |err| {
            log.err("failed to load system prompt: {}", .{err});
        };
        var sess = sessions.Sessions{};
        sess.init(alloc) catch |err| {
            log.err("failed to init sessions: {}", .{err});
        };
        return .{
            .alloc = alloc,
            .messages = .{},
            .llm_history = .{},
            .llm_client = client,
            .pending_attachments = .{},
            .system_prompt = sp,
            .sessions = sess,
        };
    }

    pub fn getElapsedSeconds(self: *Self) ?usize {
        const start = self.start_time orelse return null;
        const now = std.time.timestamp();
        return @intCast(@max(0, now - start));
    }

    pub fn setLoading(self: *Self, loading: bool) void {
        self.is_loading = loading;
        self.start_time = if (loading) std.time.timestamp() else null;
    }

    fn freeMessages(self: *Self) void {
        for (self.messages.items) |*msg| {
            self.alloc.free(msg.content);
            if (msg.thinking) |t| self.alloc.free(t);
            if (msg.styled_lines) |lines| agent.markdown.freeLines(self.alloc, lines);
        }
        for (self.llm_history.items) |msg| {
            switch (msg.content) {
                .text => |t| self.alloc.free(t),
                else => {},
            }
        }
    }

    pub fn appendToHistory(self: *Self, alloc: std.mem.Allocator, text: []const u8) !void {
        const content = try alloc.dupe(u8, text);
        try self.llm_history.append(alloc, .{ .role = .user, .content = .{ .text = content } });
    }

    pub fn clearHistory(self: *Self) void {
        self.freeMessages();
        self.messages.clearRetainingCapacity();
        self.llm_history.clearRetainingCapacity();
    }

    pub fn initCMD(self: *Self) !void {
        const prompt = init_mod.Init.getInitPrompt();
        const content = try self.alloc.dupe(u8, prompt);
        try self.messages.append(self.alloc, .{ .role = .user, .content = content });
    }

    pub fn deinit(self: *Self) void {
        self.freeMessages();
        self.messages.deinit(self.alloc);
        self.llm_history.deinit(self.alloc);
        self.clearPendingAttachments();
        self.grep_status.deinit(self.alloc);
        self.glob_status.deinit(self.alloc);
        self.pending_attachments.deinit(self.alloc);
        self.system_prompt.deinit(self.alloc);
        self.sessions.deinit();
    }

    fn setGrepStatus(self: *Self, pattern: []const u8, path: []const u8, include: []const u8) void {
        self.grep_status.deinit(self.alloc);
        self.grep_status = .{
            .pattern = if (pattern.len == 0) "" else (self.alloc.dupe(u8, pattern) catch ""),
            .path = if (std.mem.eql(u8, path, ".")) "." else (self.alloc.dupe(u8, path) catch "."),
            .include = if (include.len == 0) "" else (self.alloc.dupe(u8, include) catch ""),
        };
    }

    fn clearGrepStatus(self: *Self) void {
        self.grep_status.deinit(self.alloc);
    }

    fn setGlobStatus(self: *Self, pattern: []const u8, path: []const u8) void {
        self.glob_status.deinit(self.alloc);
        self.glob_status = .{
            .pattern = if (pattern.len == 0) "" else (self.alloc.dupe(u8, pattern) catch ""),
            .path = if (std.mem.eql(u8, path, ".")) "." else (self.alloc.dupe(u8, path) catch "."),
        };
    }

    fn clearGlobStatus(self: *Self) void {
        self.glob_status.deinit(self.alloc);
    }

    fn clearPendingAttachments(self: *Self) void {
        for (self.pending_attachments.items) |p| self.alloc.free(p);
        self.pending_attachments.clearRetainingCapacity();
    }

    pub fn getStyledLines(self: *Self, msg: *Message) ![]const agent.markdown.StyledLine {
        if (msg.styled_lines != null and msg.styled_content_len == msg.content.len) {
            return msg.styled_lines.?;
        }
        if (msg.styled_lines) |old| agent.markdown.freeLines(self.alloc, old);
        msg.styled_lines = try agent.markdown.parse(self.alloc, msg.content);
        msg.styled_content_len = msg.content.len;
        return msg.styled_lines.?;
    }

    const StreamCtx = struct {
        app: *Self,
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

    fn onThinkingChunk(ctx_ptr: *anyopaque, chunk: []const u8) void {
        const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
        const app = ctx.app;

        app.mutex.lock();
        defer app.mutex.unlock();

        if (app.messages.items.len == 0) return;
        const last = &app.messages.items[app.messages.items.len - 1];

        if (last.thinking) |existing| {
            const new_thinking = std.mem.concat(app.alloc, u8, &.{ existing, chunk }) catch return;
            app.alloc.free(existing);
            last.thinking = new_thinking;
        } else {
            last.thinking = app.alloc.dupe(u8, chunk) catch return;
        }

        app.needs_redraw = true;
        wakeLoop(ctx.loop);
    }

    pub fn shouldCancel(ctx_ptr: *anyopaque) bool {
        const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
        const app = ctx.app;

        app.mutex.lock();
        defer app.mutex.unlock();
        return app.cancel_requested;
    }

    pub fn cancelActiveRequest(self: *Self, loop: *EventLoop) bool {
        self.mutex.lock();

        if (!self.is_loading) {
            self.mutex.unlock();
            return false;
        }

        self.cancel_requested = true;
        self.needs_redraw = true;
        self.mutex.unlock();
        wakeLoop(loop);
        return true;
    }

    pub fn resolveToolConfirmation(self: *Self, alloc: std.mem.Allocator, action: ConfirmationAction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.tool_confirmation.pending) return;

        self.tool_confirmation.cursor = action;

        if (action == .deny) {
            var deny_buf: [256]u8 = undefined;
            const deny_target = self.tool_confirmation.file_path;
            const action_text = if (std.mem.eql(u8, self.tool_confirmation.tool_name, "write_file"))
                "write"
            else if (std.mem.eql(u8, self.tool_confirmation.tool_name, "bash"))
                "run"
            else
                "edit";
            const deny_text = std.fmt.bufPrint(&deny_buf, "Permission denied: agent cannot {s} '{s}'", .{ action_text, deny_target }) catch "Permission denied";
            try self.messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, deny_text) });
            self.needs_redraw = true;
        }

        self.tool_confirmation.pending = false;
        self.tool_confirmation.cond.signal();
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
    pub fn fetchAiResponse(self: *Self, loop: *EventLoop) void {
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
                self.setLoading(false);
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
                self.setLoading(false);
                self.mutex.unlock();
                return;
            };
        };

        self.llm_history.append(alloc, .{
            .role = .user,
            .content = .{ .text = user_text },
        }) catch {};
        self.sessions.appendFmt(alloc, "You: {s}", .{user_text});
        self.mutex.unlock();

        // 2. Get tool definitions (arena keeps parsed JSON alive)
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const tool_defs = agent.tools.getDefinitions(arena_alloc) catch &.{};

        const max_iterations = 10;
        var iteration: usize = 0;
        var stream_ctx = StreamCtx{ .app = self, .loop = loop };

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

            const system = if (self.system_prompt.content.len > 0) self.system_prompt.content else null;
            const resp = self.llm_client.sendMessageStreaming(alloc, self.llm_history.items, tool_defs, system, &stream_ctx, onChunk, onThinkingChunk, shouldCancel) catch |err| {
                log.err("sendMessageStreaming failed: {}", .{err});
                self.mutex.lock();
                if (err == error.RequestCancelled) {
                    self.setLoading(false);
                    self.tool_status = null;
                    self.clearGrepStatus();
                    self.clearGlobStatus();
                    self.cancel_requested = false;
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    wakeLoop(loop);
                    return;
                }
                if (self.messages.items.len > 0) {
                    const last = &self.messages.items[self.messages.items.len - 1];
                    alloc.free(last.content);
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "(error: {})", .{err}) catch "(error)";
                    last.content = alloc.dupe(u8, msg) catch "";
                }
                self.mutex.unlock();
                break;
            };
            defer resp.deinit();

            const response = resp.value;
            log.info("--- RESPONSE stop_reason={s} tokens={d}in/{d}out ---", .{
                response.stop_reason orelse "null",
                response.usage.input_tokens,
                response.usage.output_tokens,
            });
            self.context_usage.tokensCount = @intCast(response.usage.input_tokens + response.usage.output_tokens);
            if (agent.llm.providers.findModel(self.llm_client.config.model)) |found| {
                self.context_usage.tokensPercentage = self.context_usage.tokensCount * 100 / found.model.max_context;
            }
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

            // Check stop reason
            const is_tool_use = if (response.stop_reason) |sr| std.mem.eql(u8, sr, "tool_use") else false;
            if (!is_tool_use or tool_uses.items.len == 0) {
                // No tools — append assistant text to history and done
                if (text_buf.items.len > 0) {
                    const duped = alloc.dupe(u8, text_buf.items) catch break;
                    self.mutex.lock();
                    self.llm_history.append(alloc, .{
                        .role = .assistant,
                        .content = .{ .text = duped },
                    }) catch {};
                    self.sessions.appendFmt(alloc, "AI: \n{s}", .{duped});
                    self.mutex.unlock();
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
                    .thinking = if (block.thinking) |t| alloc.dupe(u8, t) catch null else null,
                    .signature = if (block.signature) |s| alloc.dupe(u8, s) catch null else null,
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
            var any_denied = false;
            for (tool_uses.items, 0..) |tool_use, i| {
                log.info("executing tool: {s}", .{tool_use.name});

                if (self.tool_confirmation.cursor != .accept_all) {
                    const needs_confirmation =
                        std.mem.eql(u8, tool_use.name, "write_file") or
                        std.mem.eql(u8, tool_use.name, "edit_file") or
                        std.mem.eql(u8, tool_use.name, "bash");

                    if (needs_confirmation) {
                        const is_bash = std.mem.eql(u8, tool_use.name, "bash");
                        const fp = if (is_bash)
                            agent.tools.getStringField(tool_use.input, "command") orelse ""
                        else
                            agent.tools.getStringField(tool_use.input, "file_path") orelse "";
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
                        self.tool_confirmation.cursor = .approve;
                        self.tool_status = tool_use.name;
                        self.needs_redraw = true;
                        self.mutex.unlock();
                        wakeLoop(loop);

                        self.mutex.lock();
                        while (self.tool_confirmation.pending) {
                            self.tool_confirmation.cond.wait(&self.mutex);
                        }
                        const approved = self.tool_confirmation.cursor != .deny;
                        self.mutex.unlock();

                        if (!approved) {
                            tool_results[i] = .{
                                .tool_use_id = tool_use.id,
                                .content = "User denied permission",
                                .is_error = true,
                            };
                            any_denied = true;
                            continue;
                        }
                    }
                }

                if (std.mem.eql(u8, tool_use.name, "grep")) {
                    self.mutex.lock();
                    self.tool_status = tool_use.name;
                    self.setGrepStatus(
                        agent.tools.getStringField(tool_use.input, "pattern") orelse "",
                        agent.tools.getStringField(tool_use.input, "path") orelse ".",
                        agent.tools.getStringField(tool_use.input, "include") orelse "",
                    );
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    wakeLoop(loop);
                }

                if (std.mem.eql(u8, tool_use.name, "glob")) {
                    self.mutex.lock();
                    self.tool_status = tool_use.name;
                    self.setGlobStatus(
                        agent.tools.getStringField(tool_use.input, "pattern") orelse "",
                        agent.tools.getStringField(tool_use.input, "path") orelse ".",
                    );
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    wakeLoop(loop);
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

            if (any_denied) break;

            log.info("tool results appended, looping back", .{});
            self.mutex.lock();
            self.tool_status = null;
            self.mutex.unlock();
        }

        // Done
        self.mutex.lock();
        self.setLoading(false);
        self.tool_status = null;
        self.clearGrepStatus();
        self.clearGlobStatus();
        self.cancel_requested = false;
        self.needs_redraw = true;
        self.mutex.unlock();
        wakeLoop(loop);
    }
};

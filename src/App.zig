const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const context_usage_mod = @import("context_usage.zig");
const sessions = @import("sessions.zig");
const compact_mod = @import("commands/compact.zig");
const init_mod = @import("commands/init.zig");
const mode_mod = @import("mode.zig");
const image_attach = @import("image_attach.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const Role = enum { user, assistant, notice };
pub const Mode = mode_mod.Mode;

pub const Message = struct {
    role: Role,
    content: []const u8,
    thinking: ?[]const u8 = null,
    styled_lines: ?[]const agent.markdown.StyledLine = null,
    styled_content_len: usize = 0,
    is_error: bool = false,
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

pub const WebStatus = struct {
    label: []const u8 = "",

    pub fn deinit(self: *WebStatus, alloc: std.mem.Allocator) void {
        if (self.label.len > 0) alloc.free(self.label);
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
    skill_registry: agent.skills.Registry = .{},
    mcp_registry: agent.mcp.registry.McpRegistry,
    // Borrowed view of config.mcpServers — its arena outlives App (owned by
    // main.zig's parsed_config). Used by /mcp to show "configured" vs "live".
    mcp_config: std.json.Value = .null,
    // Thread running the (slow) MCP server spawn + initialize. Joined on
    // App.deinit so we don't leak the thread or race with shutdownAll.
    mcp_load_thread: ?std.Thread = null,
    system_prompt: agent.system_prompt.SystemPrompt = .{},
    sessions: sessions.Sessions = .{},
    init_cmd: init_mod.Init = .{},
    compact_mod: compact_mod.Compact = .{},
    mutex: std.Thread.Mutex = .{},
    is_loading: bool = false,
    start_time: ?i64 = null,
    needs_redraw: bool = true,
    tool_status: ?[]const u8 = null,
    grep_status: GrepStatus = .{},
    glob_status: GlobStatus = .{},
    web_status: WebStatus = .{},
    cancel_requested: bool = false,
    context_usage: context_usage_mod.contextUsage = .{},
    mode: Mode = .{ .build = .{} },

    const Self = @This();
    const log = std.log.scoped(.app);

    pub fn init(alloc: std.mem.Allocator, client: *agent.llm.Client, config: *agent.config.Config) Self {
        var sp = agent.system_prompt.SystemPrompt{};
        sp.readContent(alloc) catch |err| {
            log.err("failed to load system prompt: {}", .{err});
        };
        var sess = sessions.Sessions{};
        sess.init(alloc, config) catch |err| {
            log.err("failed to init sessions: {}", .{err});
        };
        var skill_registry = agent.skills.Registry.init();
        skill_registry.load(alloc) catch |err| {
            log.err("failed to load skills: {}", .{err});
        };
        if (skill_registry.skills.items.len == 0) {
            log.info("no skills loaded", .{});
        } else {
            log.info("loaded {d} skills", .{skill_registry.skills.items.len});
            for (skill_registry.skills.items) |skill| {
                log.info("skill: {s}", .{skill.name});
            }
        }
        return .{
            .alloc = alloc,
            .messages = .{},
            .llm_history = .{},
            .llm_client = client,
            .pending_attachments = .{},
            .skill_registry = skill_registry,
            .mcp_registry = agent.mcp.registry.McpRegistry.init(alloc),
            .system_prompt = sp,
            .sessions = sess,
        };
    }

    /// Spawn and initialize every configured MCP server. Called from main
    /// after `App.init` because the config isn't available to `init`.
    /// Failures are logged per-server and don't block startup.
    pub fn loadMcpServers(self: *Self, mcp_servers: std.json.Value) void {
        // Store the config view immediately so /mcp can show "configured"
        // entries (with status=loading) before the loader thread finishes.
        self.mcp_config = mcp_servers;
        self.mcp_load_thread = std.Thread.spawn(.{}, mcpLoadEntry, .{self}) catch |err| blk: {
            log.err("loadMcpServers: spawn thread failed: {}", .{err});
            // Fallback: run inline so behavior degrades to "blocks startup"
            // instead of "no MCP at all".
            self.mcp_registry.loadFromConfig(mcp_servers) catch {};
            break :blk null;
        };
    }

    fn mcpLoadEntry(self: *Self) void {
        self.mcp_registry.loadFromConfig(self.mcp_config) catch |err| {
            log.err("mcpLoadEntry: {}", .{err});
        };
        // Nudge the UI so the next render reflects "loading → ready".
        self.mutex.lock();
        self.needs_redraw = true;
        self.mutex.unlock();
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
        self.freeLlmHistory();
    }

    fn freeLlmHistory(self: *Self) void {
        for (self.llm_history.items) |msg| {
            switch (msg.content) {
                .text => |t| self.alloc.free(t),
                .content_blocks => |blocks| {
                    for (blocks) |b| {
                        if (b.text) |t| self.alloc.free(t);
                        if (b.source) |src| self.alloc.free(src.data);
                    }
                    self.alloc.free(blocks);
                },
                else => {},
            }
        }
    }

    pub fn appendToHistory(self: *Self, alloc: std.mem.Allocator, text: []const u8) !void {
        const content = try alloc.dupe(u8, text);
        try self.llm_history.append(alloc, .{ .role = .user, .content = .{ .text = content } });
    }

    fn messagesToString(self: *Self) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.alloc);

        for (self.messages.items) |msg| {
            const role = switch (msg.role) {
                .user => "User",
                .assistant => "Assistant",
                .notice => "Notice",
            };

            try buf.writer(self.alloc).print("{s}: {s}\n", .{ role, msg.content });
            if (msg.thinking) |thinking| {
                try buf.writer(self.alloc).print("Thinking: {s}\n", .{thinking});
            }
        }

        return buf.toOwnedSlice(self.alloc);
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

    fn buildCompactPrompt(self: *Self) ![]const u8 {
        const transcript = try self.messagesToString();
        defer self.alloc.free(transcript);

        return compact_mod.Compact.getPrompt(self.alloc, transcript);
    }

    pub fn compactCMD(self: *Self) !void {
        const prompt = try self.buildCompactPrompt();
        self.freeLlmHistory();
        self.llm_history.clearRetainingCapacity();
        self.clearPendingAttachments();
        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }

    pub fn forkCMD(self: *Self) !void {
        const prompt = try self.buildCompactPrompt();
        errdefer self.alloc.free(prompt);

        try self.sessions.fork(prompt);

        self.clearHistory();
        try self.appendToHistory(self.alloc, prompt);
        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }

    pub fn skillCMD(self: *Self, skill_name: []const u8) !void {
        const prompt = try std.fmt.allocPrint(
            self.alloc,
            "Use the `skill` tool to load and apply the `{s}` skill for this conversation.",
            .{skill_name},
        );
        errdefer self.alloc.free(prompt);

        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }

    fn appendSkillNotice(self: *Self, skill_name: []const u8) void {
        const content = std.fmt.allocPrint(self.alloc, "→ Skill \"{s}\"", .{skill_name}) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.messages.append(self.alloc, .{ .role = .notice, .content = content }) catch {
            self.alloc.free(content);
            return;
        };
        const assistant_placeholder = self.alloc.dupe(u8, "") catch return;
        self.messages.append(self.alloc, .{ .role = .assistant, .content = assistant_placeholder }) catch {
            self.alloc.free(assistant_placeholder);
            return;
        };
        self.needs_redraw = true;
    }

    fn appendSkillScriptNotice(self: *Self, skill_name: []const u8, script_path: []const u8) void {
        const content = std.fmt.allocPrint(self.alloc, "→ Skill script \"{s}/{s}\"", .{ skill_name, script_path }) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.messages.append(self.alloc, .{ .role = .notice, .content = content }) catch {
            self.alloc.free(content);
            return;
        };
        self.needs_redraw = true;
    }

    pub fn deinit(self: *Self) void {
        self.freeMessages();
        self.messages.deinit(self.alloc);
        self.llm_history.deinit(self.alloc);
        self.clearPendingAttachments();
        self.grep_status.deinit(self.alloc);
        self.glob_status.deinit(self.alloc);
        self.web_status.deinit(self.alloc);
        self.pending_attachments.deinit(self.alloc);
        self.skill_registry.deinit(self.alloc);
        // Wait for the MCP loader thread before shutting down the registry,
        // otherwise shutdownAll() would race with in-flight spawn/initialize.
        if (self.mcp_load_thread) |t| t.join();
        self.mcp_registry.shutdownAll();
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

    fn setWebStatus(self: *Self, label: []const u8) void {
        self.web_status.deinit(self.alloc);
        self.web_status = .{
            .label = if (label.len == 0) "" else (self.alloc.dupe(u8, label) catch ""),
        };
    }

    fn clearWebStatus(self: *Self) void {
        self.web_status.deinit(self.alloc);
    }

    fn summarizeUrls(self: *Self, value: std.json.Value) []const u8 {
        return switch (value) {
            .string => self.alloc.dupe(u8, value.string) catch "",
            .array => |arr| blk: {
                if (arr.items.len == 0) break :blk self.alloc.dupe(u8, "") catch "";
                if (arr.items[0] != .string) break :blk self.alloc.dupe(u8, "<invalid urls>") catch "";
                if (arr.items.len == 1) break :blk self.alloc.dupe(u8, arr.items[0].string) catch "";
                break :blk std.fmt.allocPrint(self.alloc, "{s} (+{d} more)", .{ arr.items[0].string, arr.items.len - 1 }) catch "";
            },
            else => self.alloc.dupe(u8, "<invalid urls>") catch "",
        };
    }

    pub fn clearPendingAttachments(self: *Self) void {
        for (self.pending_attachments.items) |p| self.alloc.free(p);
        self.pending_attachments.clearRetainingCapacity();
        self.preview_scroll = 0;
    }

    fn stripProposedPlanTags(self: *Self, input: []const u8) ![]u8 {
        const without_open = try std.mem.replaceOwned(u8, self.alloc, input, "<proposed_plan>", "");
        defer self.alloc.free(without_open);
        return std.mem.replaceOwned(u8, self.alloc, without_open, "</proposed_plan>", "");
    }

    pub fn getStyledLines(self: *Self, msg: *Message) ![]const agent.markdown.StyledLine {
        if (msg.styled_lines != null and msg.styled_content_len == msg.content.len) {
            return msg.styled_lines.?;
        }
        if (msg.styled_lines) |old| agent.markdown.freeLines(self.alloc, old);
        const content = try self.stripProposedPlanTags(msg.content);
        defer self.alloc.free(content);
        const lines = try agent.markdown.parse(self.alloc, content);
        if (msg.is_error) {
            for (lines) |line| {
                for (line.spans) |*span| {
                    span.style.fg = .{ .rgb = .{ 0xFF, 0x60, 0x60 } };
                }
            }
        }
        msg.styled_lines = lines;
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

        const last = app.lastAssistantMessage() orelse return;

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

        const last = app.lastAssistantMessage() orelse return;

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

    fn lastAssistantMessage(self: *Self) ?*Message {
        var idx = self.messages.items.len;
        while (idx > 0) {
            idx -= 1;
            if (self.messages.items[idx].role == .assistant) return &self.messages.items[idx];
        }
        return null;
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

    pub fn toggleMode(self: *Self) void {
        self.mode = self.mode.toggle();
        self.needs_redraw = true;
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

        const UserText = union(enum) {
            text_only: []u8,
            with_images: []agent.llm.message.ContentBlock,
        };

        const user_text: UserText = blk: {
            var text_buf = std.ArrayList(u8){};

            text_buf.appendSlice(alloc, last_user_msg) catch {
                text_buf.deinit(alloc);
                self.setLoading(false);
                self.mutex.unlock();
                return;
            };

            var image_blocks = std.ArrayList(agent.llm.message.ContentBlock){};

            const max_size = 512 * 1024;
            for (self.pending_attachments.items) |path| {
                if (image_attach.mimeFromPath(path)) |mime| {
                    const b64 = image_attach.encodeFileBase64(alloc, path) catch continue;
                    image_blocks.append(alloc, .{
                        .type = "image",
                        .source = .{ .media_type = mime, .data = b64 },
                    }) catch {
                        alloc.free(b64);
                        continue;
                    };
                } else {
                    const file = (if (std.fs.path.isAbsolute(path))
                        std.fs.openFileAbsolute(path, .{})
                    else
                        std.fs.cwd().openFile(path, .{})) catch continue;
                    defer file.close();
                    const contents = file.readToEndAlloc(alloc, max_size) catch continue;
                    defer alloc.free(contents);
                    text_buf.appendSlice(alloc, "\n\n<file path=\"") catch {};
                    text_buf.appendSlice(alloc, path) catch {};
                    text_buf.appendSlice(alloc, "\">\n") catch {};
                    text_buf.appendSlice(alloc, contents) catch {};
                    text_buf.appendSlice(alloc, "\n</file>") catch {};
                }
            }

            self.clearPendingAttachments();
            const text = text_buf.toOwnedSlice(alloc) catch {
                text_buf.deinit(alloc);
                image_blocks.deinit(alloc);
                self.setLoading(false);
                self.mutex.unlock();
                return;
            };

            if (image_blocks.items.len == 0) {
                image_blocks.deinit(alloc);
                break :blk .{ .text_only = text };
            }

            const blocks = alloc.alloc(agent.llm.message.ContentBlock, 1 + image_blocks.items.len) catch {
                alloc.free(text);
                image_blocks.deinit(alloc);
                self.setLoading(false);
                self.mutex.unlock();
                return;
            };
            blocks[0] = .{ .type = "text", .text = text };
            @memcpy(blocks[1..], image_blocks.items);
            image_blocks.deinit(alloc);
            break :blk .{ .with_images = blocks };
        };

        switch (user_text) {
            .text_only => |t| {
                self.llm_history.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = t },
                }) catch {};
                self.sessions.appendFmt("You: {s}", .{t});
            },
            .with_images => |blocks| {
                self.llm_history.append(alloc, .{
                    .role = .user,
                    .content = .{ .content_blocks = blocks },
                }) catch {};
                const txt = if (blocks[0].text) |t| t else "(image)";
                self.sessions.appendFmt("You: {s} [+image]", .{txt});
            },
        }
        self.mutex.unlock();

        // 2. Get tool definitions (arena keeps parsed JSON alive)
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const tool_ctx = agent.tools.Context{
            .skill_registry = &self.skill_registry,
            .mcp_registry = &self.mcp_registry,
        };
        const tool_defs = agent.tools.getDefinitions(arena_alloc, tool_ctx) catch &.{};

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

            const system = self.mode.buildSystemPrompt(alloc, self.system_prompt.content);
            defer if (system) |prompt| alloc.free(prompt);
            const resp = self.llm_client.sendMessageStreaming(alloc, self.llm_history.items, tool_defs, system, &stream_ctx, onChunk, onThinkingChunk, shouldCancel) catch |err| {
                log.err("sendMessageStreaming failed: {}", .{err});
                self.mutex.lock();
                if (err == error.RequestCancelled) {
                    self.setLoading(false);
                    self.tool_status = null;
                    self.clearGrepStatus();
                    self.clearGlobStatus();
                    self.clearWebStatus();
                    self.cancel_requested = false;
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    wakeLoop(loop);
                    return;
                }
                if (self.messages.items.len > 0) {
                    const last = &self.messages.items[self.messages.items.len - 1];
                    alloc.free(last.content);
                    const msg = "Service is not working, try later";
                    last.content = alloc.dupe(u8, msg) catch "";
                    last.is_error = true;
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
                    self.sessions.appendFmt("AI: \n{s}", .{duped});
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

                const policy = self.mode.isToolAllowed(tool_use.name, tool_use.input);
                if (!policy.ok) {
                    tool_results[i] = .{
                        .tool_use_id = tool_use.id,
                        .content = policy.reason,
                        .is_error = true,
                    };
                    any_denied = true;
                    continue;
                }

                if (self.tool_confirmation.cursor != .accept_all) {
                    const needs_confirmation =
                        std.mem.eql(u8, tool_use.name, "write_file") or
                        std.mem.eql(u8, tool_use.name, "edit_file") or
                        std.mem.eql(u8, tool_use.name, "bash") or
                        std.mem.startsWith(u8, tool_use.name, "mcp__");

                    if (needs_confirmation) {
                        const is_bash = std.mem.eql(u8, tool_use.name, "bash");
                        const is_mcp = std.mem.startsWith(u8, tool_use.name, "mcp__");

                        // For MCP tools we don't have a single "file_path"
                        // or "content" — synthesize a header (server.tool)
                        // and a pretty-printed JSON of the input so the user
                        // can actually see what's about to run.
                        var mcp_fp: []const u8 = "";
                        var mcp_body: []const u8 = "";
                        if (is_mcp) {
                            const rest = tool_use.name["mcp__".len..];
                            if (std.mem.indexOf(u8, rest, "__")) |sep| {
                                mcp_fp = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ rest[0..sep], rest[sep + 2 ..] }) catch tool_use.name;
                            } else {
                                mcp_fp = tool_use.name;
                            }
                            const json_pretty = std.json.Stringify.valueAlloc(arena_alloc, tool_use.input, .{ .whitespace = .indent_2 }) catch "";
                            // Prepend the tool's MCP-advertised description
                            // so the user knows what the call will actually
                            // do before approving.
                            if (self.mcp_registry.findDescriptionForPrefixed(tool_use.name)) |desc| {
                                mcp_body = std.fmt.allocPrint(arena_alloc, "{s}\n\n{s}", .{ desc, json_pretty }) catch json_pretty;
                            } else {
                                mcp_body = json_pretty;
                            }
                        }

                        const fp = if (is_mcp) mcp_fp else if (is_bash)
                            agent.tools.getStringField(tool_use.input, "command") orelse ""
                        else
                            agent.tools.getStringField(tool_use.input, "file_path") orelse "";
                        const cnt = if (is_mcp) mcp_body else (agent.tools.getStringField(tool_use.input, "content") orelse "");
                        const old_s = if (is_mcp) "" else (agent.tools.getStringField(tool_use.input, "old_string") orelse "");
                        const new_s = if (is_mcp) "" else (agent.tools.getStringField(tool_use.input, "new_string") orelse "");

                        self.mutex.lock();
                        self.tool_confirmation.pending = true;
                        self.tool_confirmation.tool_name = tool_use.name;
                        self.tool_confirmation.file_path = fp;
                        self.tool_confirmation.content = cnt;
                        self.tool_confirmation.old_string = old_s;
                        self.tool_confirmation.new_string = new_s;
                        self.tool_confirmation.cursor = .approve;
                        self.preview_scroll = 0;
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

                if (std.mem.eql(u8, tool_use.name, "web_search")) {
                    const query = agent.tools.getStringField(tool_use.input, "query") orelse "";
                    const label = std.fmt.allocPrint(self.alloc, "Web Search(\"{s}\")", .{query}) catch "Web Search()";
                    self.mutex.lock();
                    self.tool_status = tool_use.name;
                    self.setWebStatus(label);
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    self.alloc.free(label);
                    wakeLoop(loop);
                }

                if (std.mem.eql(u8, tool_use.name, "web_extract")) {
                    const target = self.summarizeUrls(agent.tools.getField(tool_use.input, "urls") orelse .null);
                    const label = std.fmt.allocPrint(self.alloc, "Web Extract(\"{s}\")", .{target}) catch "Web Extract()";
                    self.mutex.lock();
                    self.tool_status = tool_use.name;
                    self.setWebStatus(label);
                    self.needs_redraw = true;
                    self.mutex.unlock();
                    self.alloc.free(target);
                    self.alloc.free(label);
                    wakeLoop(loop);
                }

                const result = agent.tools.execute(alloc, tool_ctx, tool_use.name, tool_use.input);
                log.info("tool result: is_error={}, content_len={d}", .{ result.is_error, result.content.len });
                if (!result.is_error and std.mem.eql(u8, tool_use.name, "skill")) {
                    if (agent.tools.getStringField(tool_use.input, "name")) |skill_name| {
                        self.appendSkillNotice(skill_name);
                        wakeLoop(loop);
                    }
                }
                if (!result.is_error and std.mem.eql(u8, tool_use.name, "skill_script")) {
                    if (agent.tools.getStringField(tool_use.input, "skill")) |skill_name| {
                        if (agent.tools.getStringField(tool_use.input, "path")) |script_path| {
                            self.appendSkillScriptNotice(skill_name, script_path);
                            wakeLoop(loop);
                        }
                    }
                }
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
        self.clearWebStatus();
        self.cancel_requested = false;
        self.needs_redraw = true;
        self.mutex.unlock();
        wakeLoop(loop);
    }
};

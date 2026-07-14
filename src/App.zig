const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const context_usage_mod = @import("context_usage.zig");
const sessions = @import("sessions.zig");
const messages_mod = @import("messages.zig");
const compact_mod = @import("commands/compact.zig");
const init_mod = @import("commands/init.zig");
const export_mod = @import("commands/export.zig");
const settings_mod = agent.settings;
const mode_mod = @import("mode.zig");
const agent_loop = @import("agent_loop.zig");
const image_attach = @import("image_attach.zig");
const LoadingState = @import("loading_state.zig").LoadingState;
const chat_selection = @import("chat_selection.zig");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const Role = messages_mod.Role;
pub const Mode = mode_mod.Mode;

pub const Message = messages_mod.Message;

pub const ToolConfirmation = struct {
    pending: bool = false,
    tool_name: []const u8 = "",
    tool: ?agent.tools.ToolName = null,
    file_path: []const u8 = "",
    cond: std.Thread.Condition = .{},
    content: []const u8 = "",
    old_string: []const u8 = "",
    new_string: []const u8 = "",
    start_line: usize = 1,
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
    messages: messages_mod.Messages,
    chat_render_cache: chat_selection.ChatRenderCache,
    message_queue: agent.message_queue.MessageQueue = .{},
    llm_client: *agent.llm.Client,
    // Borrowed; owned by main(). Live handle to persisted config + settings,
    // so reads (e.g. dockerImage, settings) reflect runtime mutations.
    config_store: *agent.config.ConfigStore,
    pending_attachments: std.ArrayList([]u8),
    skill_registry: agent.skills.Registry,
    mcp_registry: agent.mcp.registry.McpRegistry,
    // Borrowed view of config.mcpServers — its arena outlives App (owned by
    // main.zig's parsed_config). Used by /mcp to show "configured" vs "live".
    mcp_config: agent.config.McpServers = .{},
    // Thread running the (slow) MCP server spawn + initialize. Joined on
    // App.deinit so we don't leak the thread or race with shutdownAll.
    mcp_load_thread: ?std.Thread = null,
    system_prompt: agent.system_prompt.SystemPrompt = .{},
    sessions: sessions.Sessions = .{},
    init_cmd: init_mod.Init = .{},
    compact_mod: compact_mod.Compact = .{},
    settings: settings_mod.Settings = .{},
    mutex: std.Thread.Mutex = .{},
    loading: LoadingState = .{},
    needs_redraw: bool = true,
    latest_version: ?[]const u8 = null,
    tool_status: ?[]const u8 = null,
    grep_status: GrepStatus = .{},
    glob_status: GlobStatus = .{},
    web_status: WebStatus = .{},
    cancel_requested: bool = false,
    context_usage: context_usage_mod.contextUsage = .{},
    mode: Mode = .{ .build = .{} },
    tasks: agent.tasks.TaskStore,
    sandbox: agent.sandbox.Sandbox = .{},
    // Written by the start/stop worker, read by the event loop and input handler
    // → atomic (no mutex; the worker also does blocking docker calls we must not
    // hold a lock across).
    sandbox_busy: std.atomic.Value(bool) = .init(false),
    // Handle for the background start/stop worker. Kept (not detached) so deinit
    // can join it — a slow image pull/worktree create must not outlive the app
    // and touch freed state. Mirrors `mcp_load_thread`.
    sandbox_thread: ?std.Thread = null,
    // Set by fetchAiResponse so the Host hook methods can wakeLoop without the
    // engine having to thread the event loop through.
    active_loop: ?*EventLoop = null,

    const Self = @This();
    const log = std.log.scoped(.app);

    pub fn init(alloc: std.mem.Allocator, client: *agent.llm.Client, config: *agent.config.ConfigStore) !Self {
        var sp = agent.system_prompt.SystemPrompt{};
        sp.readContent(alloc) catch |err| {
            log.err("failed to load system prompt: {}", .{err});
        };
        var sess = sessions.Sessions{};
        sess.init(alloc, config) catch |err| {
            log.err("failed to init sessions: {}", .{err});
        };
        var skill_registry = try agent.skills.Registry.init(alloc);
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
            .chat_render_cache = .{ .arena = std.heap.ArenaAllocator.init(alloc) },
            .llm_client = client,
            .pending_attachments = .{},
            .skill_registry = skill_registry,
            .mcp_registry = agent.mcp.registry.McpRegistry.init(alloc),
            .system_prompt = sp,
            .sessions = sess,
            .config_store = config,
            .settings = settings_mod.Settings.init(config.cfg.settings),
            .tasks = agent.tasks.TaskStore.init(alloc),
        };
    }

    /// Spawn and initialize every configured MCP server. Called from main
    /// after `App.init` because the config isn't available to `init`.
    /// Failures are logged per-server and don't block startup.
    pub fn loadMcpServers(self: *Self, mcp_servers: agent.config.McpServers) void {
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

    pub fn resumeSession(self: *Self, alloc: std.mem.Allocator, filename: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.messages.resumeSession(alloc, &self.sessions, filename);
        self.tasks.clear();
        self.needs_redraw = true;
    }

    pub fn clearHistory(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.messages.clear(self.alloc);
        self.tasks.clear();
    }

    pub fn initCMD(self: *Self) !void {
        const prompt = init_mod.Init.getInitPrompt();
        const content = try self.alloc.dupe(u8, prompt);
        try self.messages.append(self.alloc, .{ .role = .user, .content = content });
    }

    pub fn exportCMD(self: *Self) !void {
        const notice = try export_mod.Export.exportSession(self.alloc, self.messages.view());
        defer self.alloc.free(notice);
        self.appendNotice(notice);
    }

    fn buildCompactPrompt(self: *Self) ![]const u8 {
        const transcript = try self.messages.toString(self.alloc);
        defer self.alloc.free(transcript);

        return compact_mod.Compact.getPrompt(self.alloc, transcript);
    }

    pub fn compactCMD(self: *Self) !void {
        const prompt = try self.buildCompactPrompt();
        self.messages.clearLlmHistory(self.alloc);
        self.clearPendingAttachments();
        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }

    pub fn forkCMD(self: *Self) !void {
        const prompt = try self.buildCompactPrompt();
        errdefer self.alloc.free(prompt);

        try self.sessions.fork(prompt);

        self.clearHistory();
        try self.messages.appendToHistory(self.alloc, prompt);
        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }

    pub fn skillCMD(self: *Self, skill_name: []const u8) !void {
        const prompt = try agent.skills.buildSkillPrompt(self.alloc, skill_name);
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

    pub fn appendNotice(self: *Self, content: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.messages.appendNotice(self.alloc, content);
        self.needs_redraw = true;
    }

    /// Toggle the Docker sandbox. When on, the filesystem tools run inside a
    /// container bound to a fresh git worktree on a new branch (under
    /// ~/.config/agent-zig/worktrees) — the main repo checkout is never touched.
    /// Starting creates the worktree, then launches the container with it
    /// bind-mounted (the image pull on first run can be slow), so the work runs on
    /// a background thread to keep the TUI responsive.
    pub fn toggleSandbox(self: *Self, loop: *EventLoop, is_off: bool) void {
        if (self.sandbox_busy.load(.acquire)) return;

        // Reap the previous (now-finished) worker so its handle can be reused.
        // Safe: sandbox_busy is false here, so it isn't running.
        if (self.sandbox_thread) |t| {
            t.join();
            self.sandbox_thread = null;
        }

        if (is_off) {
            if (!self.sandbox.active.load(.acquire)) {
                self.appendNotice("🐳 sandbox is not running");
                return;
            }
            self.sandbox_busy.store(true, .release);
            self.appendNotice("🐳 stopping sandbox…");
            // Stop on a worker thread: docker stop/chown block, and doing them on
            // the event-loop thread freezes the TUI until the container dies.
            self.sandbox_thread = std.Thread.spawn(.{}, stopSandboxWork, .{ self, loop }) catch |err| {
                log.warn("sandbox stop thread spawn failed, running inline: {}", .{err});
                self.sandbox_thread = null;
                self.stopSandboxWork(loop); // spawn failed — run inline as a fallback
                return;
            };
            return;
        }

        // Already running → just say so; the sandbox stays up for the rest of the
        // session (it's torn down on exit in deinit).
        if (self.sandbox.active.load(.acquire)) {
            const msg = std.fmt.allocPrint(self.alloc, "🐳 sandbox already running on branch {s} at {s}", .{ self.sandbox.branch, self.sandbox.worktree_path }) catch null;
            if (msg) |m| {
                defer self.alloc.free(m);
                self.appendNotice(m);
            } else self.appendNotice("🐳 sandbox already running");
            return;
        }

        self.sandbox_busy.store(true, .release);
        self.appendNotice("🐳 starting sandbox (first run may pull the image)…");

        // Keep the handle (don't detach) so deinit can join it.
        self.sandbox_thread = std.Thread.spawn(.{}, sandboxWork, .{ self, loop }) catch |err| {
            log.warn("sandbox start thread spawn failed, running inline: {}", .{err});
            // Spawn failed — fall back to running inline (blocks, but works).
            self.sandbox_thread = null;
            self.sandboxWork(loop);
            return;
        };
    }

    /// Background worker: stop the sandbox, post the result, redraw.
    fn stopSandboxWork(self: *Self, loop: *EventLoop) void {
        defer {
            self.sandbox_busy.store(false, .release);
            wakeLoop(loop);
        }
        self.sandbox.stop(self.alloc);
        self.appendNotice("🐳 sandbox OFF (worktree kept for review)");
    }

    /// Background worker: start the sandbox, post the result, redraw.
    fn sandboxWork(self: *Self, loop: *EventLoop) void {
        defer {
            self.sandbox_busy.store(false, .release);
            wakeLoop(loop);
        }

        const cwd = std.fs.cwd().realpathAlloc(self.alloc, ".") catch {
            self.appendNotice("🐳 sandbox: could not resolve current directory");
            return;
        };
        defer self.alloc.free(cwd);

        self.sandbox.start(self.alloc, self.config_store.cfg.dockerImage, cwd) catch |err| {
            const msg = std.fmt.allocPrint(self.alloc, "🐳 sandbox failed to start: {s} (is Docker installed and running?)", .{@errorName(err)}) catch {
                self.appendNotice("🐳 sandbox failed to start");
                return;
            };
            defer self.alloc.free(msg);
            self.appendNotice(msg);
            return;
        };
        const on_msg = std.fmt.allocPrint(self.alloc, "🐳 sandbox ON — branch {s} at {s} (main repo untouched)", .{ self.sandbox.branch, self.sandbox.worktree_path }) catch null;
        if (on_msg) |m| {
            defer self.alloc.free(m);
            self.appendNotice(m);
        } else self.appendNotice("🐳 sandbox ON");
    }

    pub fn deinit(self: *Self) void {
        // Wait for any in-flight sandbox start/stop before tearing down the state
        // it touches (self.sandbox, self.messages, self.alloc).
        if (self.sandbox_thread) |t| t.join();
        self.sandbox.stop(self.alloc);
        self.chat_render_cache.arena.deinit();
        self.tasks.deinit();
        self.messages.deinit(self.alloc);
        self.message_queue.deinit(self.alloc);
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
        if (self.latest_version) |v| self.alloc.free(v);
        agent.llm.providers.openrouter_store.deinit();
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

    pub fn getStyledLines(self: *Self, msg: *Message) ![]const agent.markdown.StyledLine {
        return msg.styledLines(self.alloc);
    }

    // === agent_loop.Host implementation ===
    // The engine in agent_loop.zig drives the think→tool→loop and calls back
    // into these methods for every side-effect. Locking lives here (not in the
    // engine), preserving the TUI's mutex discipline.

    pub fn historyItems(self: *Self) []const agent.llm.message.Message {
        return self.messages.historyItems();
    }

    pub fn pushHistory(self: *Self, msg: agent.llm.message.Message) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.messages.pushHistory(self.alloc, &self.sessions, msg);
    }

    pub fn onChunk(self: *Self, chunk: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const last = self.messages.lastAssistant() orelse return;
        const new_content = std.mem.concat(self.alloc, u8, &.{ last.content, chunk }) catch return;
        self.alloc.free(last.content);
        last.content = new_content;

        self.needs_redraw = true;
        if (self.active_loop) |l| wakeLoop(l);
    }

    pub fn onThinkingChunk(self: *Self, chunk: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const last = self.messages.lastAssistant() orelse return;

        if (!self.settings.showThinking.status) return;

        if (last.thinking) |existing| {
            const new_thinking = std.mem.concat(self.alloc, u8, &.{ existing, chunk }) catch return;
            self.alloc.free(existing);
            last.thinking = new_thinking;
        } else {
            last.thinking = self.alloc.dupe(u8, chunk) catch return;
        }

        self.needs_redraw = true;
        if (self.active_loop) |l| wakeLoop(l);
    }

    pub fn shouldCancel(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    pub fn isToolAllowed(self: *Self, name: []const u8, input: std.json.Value) mode_mod.ToolPolicy {
        return self.mode.isToolAllowed(name, input);
    }

    pub fn onUsage(self: *Self, usage: agent.llm.message.Usage) void {
        self.context_usage.tokensCount = @intCast(usage.input_tokens + usage.output_tokens);
        if (agent.llm.providers.findModel(self.llm_client.config.model)) |found| {
            self.context_usage.tokensPercentage = self.context_usage.tokensCount * 100 / found.model.max_context;
        }
    }

    pub fn onRequestError(self: *Self, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.last()) |last| {
            const msg = agent.llm.client.requestErrorMessage(self.alloc, err, self.llm_client.config.provider_name) catch return;
            self.alloc.free(last.content);
            last.content = msg;
            last.is_error = true;
        }
    }

    pub fn onFinished(self: *Self, _: agent_loop.Outcome) void {
        self.mutex.lock();
        self.loading.stop();
        self.tool_status = null;
        self.clearGrepStatus();
        self.clearGlobStatus();
        self.clearWebStatus();
        self.cancel_requested = false;
        self.needs_redraw = true;
        self.mutex.unlock();
        if (self.active_loop) |l| wakeLoop(l);
    }

    pub fn onToolsComplete(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tool_status = null;
    }

    pub fn confirmTool(self: *Self, name: []const u8, input: std.json.Value) agent_loop.Decision {
        if (self.tool_confirmation.cursor == .accept_all) return .approve;

        const tool = std.meta.stringToEnum(agent.tools.ToolName, name);
        const needs_confirmation =
            tool == .write_file or
            tool == .edit_file or
            tool == .bash or
            std.mem.startsWith(u8, name, "mcp__");
        if (!needs_confirmation) return .approve;

        // Strings stored in tool_confirmation below must live until the user
        // resolves the dialog; this arena outlives the cond.wait and is freed on
        // return (after pending=false, so the UI no longer reads them).
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const is_bash = tool == .bash;
        const is_mcp = std.mem.startsWith(u8, name, "mcp__");

        var mcp_fp: []const u8 = "";
        var mcp_body: []const u8 = "";
        if (is_mcp) {
            const rest = name["mcp__".len..];
            if (std.mem.indexOf(u8, rest, "__")) |sep| {
                mcp_fp = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ rest[0..sep], rest[sep + 2 ..] }) catch name;
            } else {
                mcp_fp = name;
            }
            const json_pretty = std.json.Stringify.valueAlloc(arena_alloc, input, .{ .whitespace = .indent_2 }) catch "";
            if (self.mcp_registry.findDescriptionForPrefixed(name)) |desc| {
                mcp_body = std.fmt.allocPrint(arena_alloc, "{s}\n\n{s}", .{ desc, json_pretty }) catch json_pretty;
            } else {
                mcp_body = json_pretty;
            }
        }

        const fp = if (is_mcp) mcp_fp else if (is_bash)
            agent.tools.getStringField(input, "command") orelse ""
        else
            agent.tools.getStringField(input, "file_path") orelse "";
        const cnt = if (is_mcp) mcp_body else (agent.tools.getStringField(input, "content") orelse "");
        const old_s = if (is_mcp) "" else (agent.tools.getStringField(input, "old_string") orelse "");
        const new_s = if (is_mcp) "" else (agent.tools.getStringField(input, "new_string") orelse "");

        var start_line: usize = 1;
        if (tool == .edit_file) {
            const line_ctx = agent.tools.Context{ .sandbox = &self.sandbox };
            if (agent.tools.matchStartLine(arena_alloc, line_ctx, fp, old_s)) |ln| start_line = ln;
        }

        self.mutex.lock();
        self.loading.pause();
        self.tool_confirmation.pending = true;
        self.tool_confirmation.tool_name = name;
        self.tool_confirmation.tool = tool;
        self.tool_confirmation.file_path = fp;
        self.tool_confirmation.content = cnt;
        self.tool_confirmation.old_string = old_s;
        self.tool_confirmation.new_string = new_s;
        self.tool_confirmation.start_line = start_line;
        self.tool_confirmation.cursor = .approve;
        self.preview_scroll = 0;
        self.tool_status = name;
        self.needs_redraw = true;
        self.mutex.unlock();
        if (self.active_loop) |l| wakeLoop(l);

        self.mutex.lock();
        while (self.tool_confirmation.pending) {
            self.tool_confirmation.cond.wait(&self.mutex);
        }
        const approved = self.tool_confirmation.cursor != .deny;
        self.mutex.unlock();

        return if (approved) .approve else .deny;
    }

    pub fn onToolActivity(self: *Self, name: []const u8, input: std.json.Value) void {
        const tool = std.meta.stringToEnum(agent.tools.ToolName, name);
        if (tool == .grep) {
            self.mutex.lock();
            self.tool_status = name;
            self.setGrepStatus(
                agent.tools.getStringField(input, "pattern") orelse "",
                agent.tools.getStringField(input, "path") orelse ".",
                agent.tools.getStringField(input, "include") orelse "",
            );
            self.needs_redraw = true;
            self.mutex.unlock();
            if (self.active_loop) |l| wakeLoop(l);
        }

        if (tool == .glob) {
            self.mutex.lock();
            self.tool_status = name;
            self.setGlobStatus(
                agent.tools.getStringField(input, "pattern") orelse "",
                agent.tools.getStringField(input, "path") orelse ".",
            );
            self.needs_redraw = true;
            self.mutex.unlock();
            if (self.active_loop) |l| wakeLoop(l);
        }

        if (tool == .web_search) {
            const query = agent.tools.getStringField(input, "query") orelse "";
            const label = std.fmt.allocPrint(self.alloc, "Web Search(\"{s}\")", .{query}) catch "Web Search()";
            self.mutex.lock();
            self.tool_status = name;
            self.setWebStatus(label);
            self.needs_redraw = true;
            self.mutex.unlock();
            self.alloc.free(label);
            if (self.active_loop) |l| wakeLoop(l);
        }

        if (tool == .web_extract) {
            const target = self.summarizeUrls(agent.tools.getField(input, "urls") orelse .null);
            const label = std.fmt.allocPrint(self.alloc, "Web Extract(\"{s}\")", .{target}) catch "Web Extract()";
            self.mutex.lock();
            self.tool_status = name;
            self.setWebStatus(label);
            self.needs_redraw = true;
            self.mutex.unlock();
            self.alloc.free(target);
            self.alloc.free(label);
            if (self.active_loop) |l| wakeLoop(l);
        }
    }

    pub fn onToolResult(self: *Self, name: []const u8, input: std.json.Value, result: agent.tools.ToolResult) void {
        const tool = std.meta.stringToEnum(agent.tools.ToolName, name);
        if (!result.is_error and tool == .skill) {
            if (agent.tools.getStringField(input, "name")) |skill_name| {
                self.appendSkillNotice(skill_name);
                if (self.active_loop) |l| wakeLoop(l);
            }
        }
        if (!result.is_error and tool == .skill_script) {
            if (agent.tools.getStringField(input, "skill")) |skill_name| {
                if (agent.tools.getStringField(input, "path")) |script_path| {
                    self.appendSkillScriptNotice(skill_name, script_path);
                    if (self.active_loop) |l| wakeLoop(l);
                }
            }
        }
    }

    pub fn dequeueFollowUp(self: *Self) ?[]const u8 {
        const queued = self.message_queue.dequeue() orelse return null;
        self.mutex.lock();
        const ui_user = self.alloc.dupe(u8, queued) catch {
            self.alloc.free(queued);
            self.mutex.unlock();
            return null;
        };
        // 0-byte dupe can't fail; needs to be heap so freeMessages frees it.
        const placeholder = self.alloc.dupe(u8, "") catch unreachable;
        self.messages.append(self.alloc, .{ .role = .user, .content = ui_user }) catch |err|
            log.err("queue: append user message failed: {}", .{err});
        self.messages.append(self.alloc, .{ .role = .assistant, .content = placeholder }) catch |err|
            log.err("queue: append assistant placeholder failed: {}", .{err});
        self.mutex.unlock();
        log.info("[assistant] sending queued follow-up: {s}", .{queued});
        return queued;
    }

    pub fn cancelActiveRequest(self: *Self, loop: *EventLoop) bool {
        self.mutex.lock();

        if (!self.loading.active) {
            self.mutex.unlock();
            return false;
        }

        self.cancel_requested = true;
        // Drop any queued follow-up messages — cancelling abandons the turn.
        self.message_queue.clear(self.alloc);
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

        if (action != .deny) {
            self.loading.unpause();
        }

        if (action == .deny) {
            var deny_buf: [256]u8 = undefined;
            const deny_target = self.tool_confirmation.file_path;
            const action_text = if (self.tool_confirmation.tool == .write_file)
                "write"
            else if (self.tool_confirmation.tool == .bash)
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
        self.active_loop = loop;

        // 1. Snapshot the user's message into llm_history
        self.mutex.lock();
        const msg_view = self.messages.view();
        const last_user_msg = if (msg_view.len >= 2)
            msg_view[msg_view.len - 2].content
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
                self.loading.stop();
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
                        .source = .{ .media_type = mime, .data = b64, .path = alloc.dupe(u8, path) catch null },
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
                self.loading.stop();
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
                self.loading.stop();
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
                self.messages.pushHistory(alloc, &self.sessions, .{
                    .role = .user,
                    .content = .{ .text = t },
                });
            },
            .with_images => |blocks| {
                self.messages.pushHistory(alloc, &self.sessions, .{
                    .role = .user,
                    .content = .{ .content_blocks = blocks },
                });
            },
        }
        self.mutex.unlock();

        // 2. Build tool defs (arena keeps parsed JSON alive) and run the shared
        //    agentic loop. Every side-effect is delegated back to App through the
        //    Host hook methods above (locking, streaming, confirmation, status,
        //    queued follow-ups, sessions, error bubbles, final cleanup).
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const tool_ctx = agent.tools.Context{
            .skill_registry = &self.skill_registry,
            .mcp_registry = &self.mcp_registry,
            .sandbox = &self.sandbox,
            .task_store = &self.tasks,
            .task_mutex = &self.mutex,
        };
        const tool_defs = agent.tools.getDefinitions(arena.allocator(), tool_ctx) catch &.{};

        const system = self.mode.buildSystemPrompt(alloc, self.system_prompt.content);
        defer if (system) |prompt| alloc.free(prompt);

        _ = agent_loop.run(Self, self, alloc, self.llm_client, tool_ctx, tool_defs, system, .{});
    }
};

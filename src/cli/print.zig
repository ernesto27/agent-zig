const std = @import("std");
const agent = @import("agent");
const log_mod = @import("../log.zig");
const mode = @import("../mode.zig");
const messages = @import("../messages.zig");
const sessions = @import("../sessions.zig");
const agent_loop = @import("../agent_loop.zig");

const log = std.log.scoped(.print);

const Host = struct {
    alloc: std.mem.Allocator,
    convo: messages.Messages = .{},
    sink: sessions.Sessions = .{},
    final_text: ?[]const u8 = null,

    fn deinit(self: *Host) void {
        self.convo.deinit(self.alloc);
    }

    pub fn historyItems(self: *Host) []const agent.llm.message.Message {
        return self.convo.historyItems();
    }

    pub fn pushHistory(self: *Host, msg: agent.llm.message.Message) void {
        self.convo.pushHistory(self.alloc, &self.sink, msg);
        if (msg.role == .assistant and msg.content == .text) {
            self.final_text = msg.content.text;
        }
    }

    pub fn onChunk(_: *Host, _: []const u8) void {}
    pub fn onThinkingChunk(_: *Host, _: []const u8) void {}

    pub fn shouldCancel(_: *Host) bool {
        return false;
    }

    pub fn isToolAllowed(_: *Host, _: []const u8, _: std.json.Value) mode.ToolPolicy {
        return .{ .ok = true, .reason = "" };
    }

    pub fn confirmTool(_: *Host, _: []const u8, _: std.json.Value) agent_loop.Decision {
        return .approve;
    }

    pub fn onRequestError(_: *Host, err: anyerror) void {
        std.debug.print("error: LLM request failed: {s}\n", .{@errorName(err)});
    }
};

pub fn run(allocator: std.mem.Allocator, prompt: []const u8) !void {
    if (prompt.len == 0) {
        std.debug.print("error: -p/--print requires a non-empty prompt\n", .{});
        return error.EmptyPrompt;
    }

    try log_mod.Logger.init(allocator);
    defer log_mod.Logger.deinit();

    var config_store = agent.config.ConfigStore.init(allocator) catch {
        std.debug.print("error: failed to load config (~/.config/agent-zig/config.json)\n", .{});
        return error.ConfigLoadFailed;
    };
    defer config_store.deinit();

    var client_cfg = agent.llm.Config{
        .base_url = "",
        .api_key = "",
        .model = config_store.cfg.providers.selected,
        .provider_name = "",
    };
    const found = agent.llm.providers.findModel(config_store.cfg.providers.selected) orelse {
        std.debug.print("error: no model selected — run the TUI once to pick a provider/model\n", .{});
        return error.NoModelSelected;
    };
    client_cfg.provider_name = found.provider.name;
    if (config_store.cfg.providers.forProvider(found.provider.name)) |pc| {
        client_cfg.base_url = pc.baseUrl;
        client_cfg.api_key = pc.apiKey;
        client_cfg.effort = config_store.thinkEffort(found.provider.name);
    }
    if (client_cfg.api_key.len == 0) {
        std.debug.print("error: no API key configured for {s}\n", .{found.provider.name});
        return error.MissingApiKey;
    }

    var client = agent.llm.Client.init(allocator, client_cfg);
    defer client.deinit();

    var sp = agent.system_prompt.SystemPrompt{};
    sp.readContent(allocator) catch |err| log.err("failed to load system prompt: {}", .{err});
    defer sp.deinit(allocator);

    var skill_registry = agent.skills.Registry.init();
    skill_registry.load(allocator) catch |err| log.err("failed to load skills: {}", .{err});
    defer skill_registry.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tool_ctx = agent.tools.Context{ .skill_registry = &skill_registry };
    const tool_defs = agent.tools.getDefinitions(arena.allocator(), tool_ctx) catch &.{};

    const build_mode: mode.Mode = .{ .build = .{} };
    const system = build_mode.buildSystemPrompt(allocator, sp.content);
    defer if (system) |s| allocator.free(s);

    var host = Host{ .alloc = allocator };
    defer host.deinit();
    host.pushHistory(.{ .role = .user, .content = .{ .text = try allocator.dupe(u8, prompt) } });

    const outcome = agent_loop.run(Host, &host, allocator, &client, tool_ctx, tool_defs, system, .{});
    if (outcome == .request_failed) return error.LlmRequestFailed;

    const answer = host.final_text orelse {
        std.debug.print("error: model returned no text answer\n", .{});
        return error.NoAnswer;
    };
    if (outcome == .max_iterations) log.warn("iteration cap reached before a final answer", .{});

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{answer});
    try stdout.flush();
}

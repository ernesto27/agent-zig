const std = @import("std");
const agent = @import("agent");

const log = std.log.scoped(.agent_loop);

pub const Decision = enum { approve, deny };

pub const Outcome = enum {
    completed,
    cancelled,
    denied,
    max_iterations,
    request_failed,
};

pub const Options = struct {
    max_iterations: usize = 50,
};

const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

const Turn = struct {
    text: []u8,
    tool_uses: []ToolUse,

    fn deinit(self: *Turn, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        for (self.tool_uses) |tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
        }
        alloc.free(self.tool_uses);
    }
};

pub fn run(
    comptime Host: type,
    host: *Host,
    alloc: std.mem.Allocator,
    client: *agent.llm.Client,
    tool_ctx: agent.tools.Context,
    tool_defs: []const agent.llm.message.ToolDefinition,
    system: ?[]const u8,
    opts: Options,
) Outcome {
    const outcome = drive(Host, host, alloc, client, tool_ctx, tool_defs, system, opts);
    if (comptime @hasDecl(Host, "onFinished")) host.onFinished(outcome);
    return outcome;
}

fn drive(
    comptime Host: type,
    host: *Host,
    alloc: std.mem.Allocator,
    client: *agent.llm.Client,
    tool_ctx: agent.tools.Context,
    tool_defs: []const agent.llm.message.ToolDefinition,
    system: ?[]const u8,
    opts: Options,
) Outcome {
    const Tramp = Trampolines(Host);

    var iteration: usize = 0;
    while (iteration < opts.max_iterations) : (iteration += 1) {
        const history = host.historyItems();
        log.info("loop iteration {d}, history size {d}", .{ iteration, history.len });

        const resp = client.sendMessageStreaming(
            alloc,
            history,
            tool_defs,
            system,
            host,
            Tramp.onChunk,
            Tramp.onThinkingChunk,
            Tramp.shouldCancel,
        ) catch |err| {
            if (err == error.RequestCancelled) return .cancelled;
            log.err("sendMessageStreaming failed: {}", .{err});
            if (comptime @hasDecl(Host, "onRequestError")) host.onRequestError(err);
            return .request_failed;
        };
        defer resp.deinit();
        const response = resp.value;

        log.info("--- RESPONSE stop_reason={s} tokens={d}in/{d}out ---", .{
            response.stop_reason orelse "null",
            response.usage.input_tokens,
            response.usage.output_tokens,
        });
        if (comptime @hasDecl(Host, "onUsage")) host.onUsage(response.usage);

        var turn = splitResponse(alloc, response) catch |err| {
            fireRequestError(Host, host, err);
            return .request_failed;
        };
        defer turn.deinit(alloc);

        const is_tool_use = if (response.stop_reason) |sr|
            std.mem.eql(u8, sr, "tool_use")
        else
            false;

        if (!is_tool_use or turn.tool_uses.len == 0) {
            if (turn.text.len > 0) {
                const owned = alloc.dupe(u8, turn.text) catch return .completed;
                host.pushHistory(.{ .role = .assistant, .content = .{ .text = owned } });
            }
            if (comptime @hasDecl(Host, "dequeueFollowUp")) {
                if (host.dequeueFollowUp()) |queued| {
                    host.pushHistory(.{ .role = .user, .content = .{ .text = queued } });
                    continue;
                }
            }
            return .completed;
        }

        const blocks = dupeAssistantBlocks(alloc, response.content) catch |err| {
            fireRequestError(Host, host, err);
            return .request_failed;
        };
        host.pushHistory(.{ .role = .assistant, .content = .{ .content_blocks = blocks } });

        const results = alloc.alloc(agent.llm.message.ToolResultBlock, turn.tool_uses.len) catch |err| {
            fireRequestError(Host, host, err);
            return .request_failed;
        };
        var any_denied = false;
        for (turn.tool_uses, 0..) |tu, i| {
            log.info("executing tool: {s}", .{tu.name});

            // tool_use_id is duped into `alloc`: `results` is handed to
            // host.pushHistory and lives in history across requests, whereas
            // `tu.id` is owned by `turn` and freed at iteration end. Never store
            // the borrowed `tu.id` — on alloc failure, abort the request.
            const policy = host.isToolAllowed(tu.name, tu.input);
            if (!policy.ok) {
                results[i] = .{
                    .tool_use_id = alloc.dupe(u8, tu.id) catch return .request_failed,
                    .content = policy.reason,
                    .is_error = true,
                };
                any_denied = true;
                continue;
            }
            if (host.confirmTool(tu.name, tu.input) == .deny) {
                results[i] = .{
                    .tool_use_id = alloc.dupe(u8, tu.id) catch return .request_failed,
                    .content = "User denied permission",
                    .is_error = true,
                };
                any_denied = true;
                continue;
            }
            if (comptime @hasDecl(Host, "onToolActivity")) host.onToolActivity(tu.name, tu.input);
            const r = agent.tools.execute(alloc, tool_ctx, tu.name, tu.input);
            log.info("tool result: is_error={}, content_len={d}", .{ r.is_error, r.content.len });
            if (comptime @hasDecl(Host, "onToolResult")) host.onToolResult(tu.name, tu.input, r);
            results[i] = .{
                .tool_use_id = alloc.dupe(u8, tu.id) catch return .request_failed,
                .content = r.content,
                .is_error = r.is_error,
            };
        }
        host.pushHistory(.{ .role = .user, .content = .{ .tool_result_blocks = results } });

        if (any_denied) return .denied;
        if (comptime @hasDecl(Host, "onToolsComplete")) host.onToolsComplete();
    }
    return .max_iterations;
}

fn fireRequestError(comptime Host: type, host: *Host, err: anyerror) void {
    if (comptime @hasDecl(Host, "onRequestError")) host.onRequestError(err);
}

fn Trampolines(comptime Host: type) type {
    return struct {
        fn onChunk(ctx: *anyopaque, chunk: []const u8) void {
            self(ctx).onChunk(chunk);
        }
        fn onThinkingChunk(ctx: *anyopaque, chunk: []const u8) void {
            self(ctx).onThinkingChunk(chunk);
        }
        fn shouldCancel(ctx: *anyopaque) bool {
            return self(ctx).shouldCancel();
        }
        inline fn self(ctx: *anyopaque) *Host {
            return @ptrCast(@alignCast(ctx));
        }
    };
}

fn splitResponse(alloc: std.mem.Allocator, response: agent.llm.message.MessagesResponse) !Turn {
    var text_buf: std.ArrayList(u8) = .{};
    errdefer text_buf.deinit(alloc);
    var tool_uses: std.ArrayList(ToolUse) = .{};
    errdefer {
        for (tool_uses.items) |tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
        }
        tool_uses.deinit(alloc);
    }

    for (response.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |t| try text_buf.appendSlice(alloc, t);
        } else if (std.mem.eql(u8, block.type, "tool_use")) {
            try tool_uses.append(alloc, .{
                .id = try alloc.dupe(u8, block.id orelse ""),
                .name = try alloc.dupe(u8, block.name orelse ""),
                .input = block.input,
            });
        }
    }
    return .{
        .text = try text_buf.toOwnedSlice(alloc),
        .tool_uses = try tool_uses.toOwnedSlice(alloc),
    };
}

fn dupeAssistantBlocks(
    alloc: std.mem.Allocator,
    blocks: []const agent.llm.message.ContentBlock,
) ![]agent.llm.message.ContentBlock {
    const out = try alloc.alloc(agent.llm.message.ContentBlock, blocks.len);
    for (blocks, 0..) |block, i| {
        const input_copy: std.json.Value = if (block.input != .null) blk: {
            const json_str = std.json.Stringify.valueAlloc(alloc, block.input, .{}) catch break :blk .null;
            defer alloc.free(json_str);
            break :blk std.json.parseFromSliceLeaky(std.json.Value, alloc, json_str, .{}) catch .null;
        } else .null;
        out[i] = .{
            .type = try alloc.dupe(u8, block.type),
            .text = if (block.text) |t| try alloc.dupe(u8, t) else null,
            .thinking = if (block.thinking) |t| try alloc.dupe(u8, t) else null,
            .signature = if (block.signature) |s| try alloc.dupe(u8, s) else null,
            .id = if (block.id) |id| try alloc.dupe(u8, id) else null,
            .name = if (block.name) |n| try alloc.dupe(u8, n) else null,
            .input = input_copy,
        };
    }
    return out;
}

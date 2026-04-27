const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const App = @import("App.zig").App;
const at_picker_mod = @import("at_picker.zig");
const command_picker_mod = @import("commands/command_picker.zig");
const model_picker_mod = @import("model_picker.zig");
const provider_picker_mod = @import("provider_picker.zig");
const ui = @import("ui.zig");

const EventLoop = vaxis.Loop(vaxis.Event);

pub const InputContext = struct {
    // borrowed — owned by main()
    alloc: std.mem.Allocator,
    app: *App,
    loop: *EventLoop,
    at_picker: *at_picker_mod.AtPicker,
    command_picker: *command_picker_mod.CommandPicker,
    model_picker: *model_picker_mod.ModelPicker,
    provider_picker: *provider_picker_mod.ProviderPicker,
    spinner_state: *ui.SpinnerState,
    auto_scroll: *bool,
    config: *agent.config.Config,

    // owned
    input: std.ArrayList(u8),
    cursor_pos: usize,
    history: std.ArrayList([]const u8),
    history_idx: ?usize,
    draft: std.ArrayList(u8),
};

/// Returns true if the app should quit.
pub fn handleKey(ctx: *InputContext, key: vaxis.Key) !bool {
    if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
        return true;
    } else if (key.matches('t', .{ .ctrl = true })) {
        const model = model_picker_mod.findModel(ctx.app.llm_client.config.model);
        if (model != null and model.?.model.supports_thinking)
            ctx.app.llm_client.config.effort = ctx.app.llm_client.config.effort.next();
    } else if (key.matches('a', .{ .ctrl = true })) {
        ctx.app.tool_confirmation.cursor = .approve;
    }  else if (key.matches('c', .{ .ctrl = true })) {

    } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
        const modal_open =
            ctx.app.tool_confirmation.pending or
            ctx.at_picker.active or
            ctx.command_picker.active or
            ctx.model_picker.active or
            ctx.provider_picker.active or
            ctx.app.sessions.active;
        if (!modal_open) ctx.app.toggleMode();
    } else if (key.matches(vaxis.Key.escape, .{})) {
        try handleEscape(ctx);
    } else if (key.matches(vaxis.Key.up, .{})) {
        try handleArrow(ctx, .up);
    } else if (key.matches(vaxis.Key.down, .{})) {
        try handleArrow(ctx, .down);
    } else if (key.matches(vaxis.Key.left, .{})) {
        if (ctx.cursor_pos > 0) ctx.cursor_pos -= 1;
    } else if (key.matches(vaxis.Key.right, .{})) {
        if (ctx.cursor_pos < ctx.input.items.len) ctx.cursor_pos += 1;
    } else if (key.codepoint == 127 or key.codepoint == 8) {
        try handleBackspace(ctx);
    } else if (key.text) |txt| {
        try handleTextInput(ctx, txt);
    } else if (((key.codepoint == '\r' or key.codepoint == '\n') and key.mods.shift) or
        key.matches('j', .{ .ctrl = true }))
    {
        try ctx.input.insert(ctx.alloc, ctx.cursor_pos, '\n');
        ctx.cursor_pos += 1;
    } else if (key.matches('\r', .{}) or key.matches('\n', .{})) {
        try handleEnter(ctx);
    }
    return false;
}

pub fn handlePasteEnd(ctx: *InputContext, text: []const u8) !void {
    if (text.len > 0) {
        try ctx.input.insertSlice(ctx.alloc, ctx.cursor_pos, text);
        ctx.cursor_pos += text.len;
    }
}

// ── private helpers ───────────────────────────────────────────────────────────

fn spawnLlmRequest(ctx: *InputContext) !void {
    ctx.app.mutex.lock();
    try ctx.app.messages.append(ctx.alloc, .{ .role = .assistant, .content = try ctx.alloc.dupe(u8, "") });
    ctx.app.setLoading(true);
    ctx.app.mutex.unlock();
    ctx.auto_scroll.* = true;
    const generation = ctx.spinner_state.generation.fetchAdd(1, .acq_rel) + 1;
    const spinner = try std.Thread.spawn(.{}, ui.spinnerThread, .{ ctx.app, ctx.loop, ctx.spinner_state, generation });
    spinner.detach();
    const thread = try std.Thread.spawn(.{}, App.fetchAiResponse, .{ ctx.app, ctx.loop });
    thread.detach();
}

fn runSlashCommand(ctx: *InputContext, action: command_picker_mod.CommandAction) !bool {
    ctx.input.clearRetainingCapacity();
    ctx.cursor_pos = 0;
    switch (action) {
        .provider => ctx.provider_picker.open(),
        .model => try ctx.model_picker.open(ctx.alloc),
        .clear => ctx.app.clearHistory(),
        .resume_session => ctx.app.sessions.open(),
        .init => {
            if (ctx.app.is_loading) return false;
            try ctx.app.initCMD();
            return true;
        },
    }
    return false;
}

fn handleEscape(ctx: *InputContext) !void {
    if (ctx.app.tool_confirmation.pending) {
        try ctx.app.resolveToolConfirmation(ctx.alloc, .deny);
    } else if (ctx.app.cancelActiveRequest(ctx.loop)) {
        return;
    } else if (ctx.at_picker.active) {
        ctx.at_picker.reset(ctx.alloc);
    } else if (ctx.command_picker.active) {
        ctx.command_picker.reset(ctx.alloc);
    } else if (ctx.model_picker.active) {
        ctx.model_picker.reset(ctx.alloc);
    } else if (ctx.provider_picker.active) {
        ctx.provider_picker.reset(ctx.alloc);
    } else if (ctx.app.sessions.active) {
        ctx.app.sessions.reset();
    }
}

const ArrowDir = enum { up, down };

fn handleArrow(ctx: *InputContext, dir: ArrowDir) !void {
    const alloc = ctx.alloc;
    switch (dir) {
        .up => {
            if (ctx.at_picker.active) {
                if (ctx.at_picker.selected > 0) ctx.at_picker.selected -= 1;
            } else if (ctx.command_picker.active) {
                if (ctx.command_picker.selected > 0) ctx.command_picker.selected -= 1;
            } else if (ctx.model_picker.active) {
                if (ctx.model_picker.selected > 0) ctx.model_picker.selected -= 1;
            } else if (ctx.provider_picker.active and ctx.provider_picker.phase == .list) {
                if (ctx.provider_picker.selected > 0) ctx.provider_picker.selected -= 1;
            } else if (ctx.app.sessions.active) {
                if (ctx.app.sessions.selected > 0) {
                    ctx.app.sessions.selected -= 1;
                    if (ctx.app.sessions.selected < ctx.app.sessions.scroll)
                        ctx.app.sessions.scroll -= 1;
                }
            } else if (ctx.app.tool_confirmation.pending) {
                ctx.app.tool_confirmation.cursor = switch (ctx.app.tool_confirmation.cursor) {
                    .approve => .accept_all,
                    .deny => .approve,
                    .accept_all => .deny,
                };
            } else if (!ctx.app.tool_confirmation.pending and ctx.history.items.len > 0) {
                if (ctx.history_idx == null) {
                    ctx.draft.clearRetainingCapacity();
                    try ctx.draft.appendSlice(alloc, ctx.input.items);
                    ctx.history_idx = ctx.history.items.len - 1;
                } else if (ctx.history_idx.? > 0) {
                    ctx.history_idx = ctx.history_idx.? - 1;
                }
                ctx.input.clearRetainingCapacity();
                try ctx.input.appendSlice(alloc, ctx.history.items[ctx.history_idx.?]);
                ctx.cursor_pos = ctx.input.items.len;
                try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
            }
        },
        .down => {
            if (ctx.at_picker.active) {
                if (ctx.at_picker.selected + 1 < ctx.at_picker.results.items.len)
                    ctx.at_picker.selected += 1;
            } else if (ctx.command_picker.active) {
                if (ctx.command_picker.selected + 1 < ctx.command_picker.results.items.len)
                    ctx.command_picker.selected += 1;
            } else if (ctx.model_picker.active) {
                if (ctx.model_picker.selected + 1 < ctx.model_picker.results.items.len)
                    ctx.model_picker.selected += 1;
            } else if (ctx.provider_picker.active and ctx.provider_picker.phase == .list) {
                if (ctx.provider_picker.selected + 1 < model_picker_mod.providers.len)
                    ctx.provider_picker.selected += 1;
            } else if (ctx.app.sessions.active) {
                if (ctx.app.sessions.selected + 1 < ctx.app.sessions.entries.items.len) {
                    ctx.app.sessions.selected += 1;
                    if (ctx.app.sessions.selected >= ctx.app.sessions.scroll + @TypeOf(ctx.app.sessions).max_visible)
                        ctx.app.sessions.scroll += 1;
                }
            } else if (ctx.app.tool_confirmation.pending) {
                ctx.app.tool_confirmation.cursor = switch (ctx.app.tool_confirmation.cursor) {
                    .approve => .deny,
                    .deny => .accept_all,
                    .accept_all => .approve,
                };
            } else if (!ctx.app.tool_confirmation.pending and ctx.history_idx != null) {
                if (ctx.history_idx.? + 1 < ctx.history.items.len) {
                    ctx.history_idx = ctx.history_idx.? + 1;
                    ctx.input.clearRetainingCapacity();
                    try ctx.input.appendSlice(alloc, ctx.history.items[ctx.history_idx.?]);
                } else {
                    ctx.history_idx = null;
                    ctx.input.clearRetainingCapacity();
                    try ctx.input.appendSlice(alloc, ctx.draft.items);
                }
                ctx.cursor_pos = ctx.input.items.len;
                try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
            }
        },
    }
}

fn handleBackspace(ctx: *InputContext) !void {
    const alloc = ctx.alloc;
    if (ctx.provider_picker.active and ctx.provider_picker.phase == .key_input) {
        if (ctx.provider_picker.key_input.items.len > 0)
            _ = ctx.provider_picker.key_input.orderedRemove(ctx.provider_picker.key_input.items.len - 1);
    } else if (ctx.model_picker.active) {
        if (ctx.model_picker.query.items.len > 0) {
            _ = ctx.model_picker.query.orderedRemove(ctx.model_picker.query.items.len - 1);
            try ctx.model_picker.refresh(alloc);
        }
    } else if (ctx.cursor_pos > 0) {
        _ = ctx.input.orderedRemove(ctx.cursor_pos - 1);
        ctx.cursor_pos -= 1;
        if (ctx.at_picker.active) {
            if (ctx.cursor_pos <= ctx.at_picker.at_start) {
                ctx.at_picker.reset(alloc);
            } else {
                ctx.at_picker.query.clearRetainingCapacity();
                const after_at = ctx.input.items[ctx.at_picker.at_start + 1 .. ctx.cursor_pos];
                try ctx.at_picker.query.appendSlice(alloc, after_at);
                try ctx.at_picker.refresh(alloc);
            }
        }
        try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
    }
}

fn handleTextInput(ctx: *InputContext, txt: []const u8) !void {
    const alloc = ctx.alloc;
    if (ctx.provider_picker.active and ctx.provider_picker.phase == .key_input) {
        try ctx.provider_picker.key_input.appendSlice(alloc, txt);
    } else if (ctx.model_picker.active) {
        try ctx.model_picker.query.appendSlice(alloc, txt);
        try ctx.model_picker.refresh(alloc);
    } else if (txt.len > 0) {
        try ctx.input.insertSlice(alloc, ctx.cursor_pos, txt);
        ctx.cursor_pos += txt.len;
        if (std.mem.eql(u8, txt, "@") and !ctx.at_picker.active) {
            ctx.at_picker.active = true;
            ctx.at_picker.at_start = ctx.cursor_pos - 1;
            try ctx.at_picker.refresh(alloc);
        } else if (ctx.at_picker.active and txt.len == 1) {
            ctx.at_picker.query.clearRetainingCapacity();
            const after_at = ctx.input.items[ctx.at_picker.at_start + 1 .. ctx.cursor_pos];
            try ctx.at_picker.query.appendSlice(alloc, after_at);
            try ctx.at_picker.refresh(alloc);
        }
        if (txt.len == 1) try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
    }
}

fn handleEnter(ctx: *InputContext) !void {
    const alloc = ctx.alloc;
    if (ctx.app.tool_confirmation.pending) {
        try ctx.app.resolveToolConfirmation(alloc, ctx.app.tool_confirmation.cursor);
    } else if (ctx.command_picker.active) {
        var should_send = false;
        if (ctx.command_picker.selectedCommand()) |cmd| {
            should_send = try runSlashCommand(ctx, cmd.action);
        }
        ctx.command_picker.reset(alloc);
        if (should_send and !ctx.app.is_loading) try spawnLlmRequest(ctx);
    } else if (ctx.at_picker.active and ctx.at_picker.results.items.len > 0) {
        const picked_path = ctx.at_picker.results.items[ctx.at_picker.selected];
        try ctx.at_picker.addPicked(alloc, picked_path);

        var replacement = std.ArrayList(u8){};
        defer replacement.deinit(alloc);
        try replacement.append(alloc, '@');
        try replacement.appendSlice(alloc, picked_path);

        const span_len = ctx.cursor_pos - ctx.at_picker.at_start;
        var i: usize = 0;
        while (i < span_len) : (i += 1) _ = ctx.input.orderedRemove(ctx.at_picker.at_start);
        try ctx.input.insertSlice(alloc, ctx.at_picker.at_start, replacement.items);
        ctx.cursor_pos = ctx.at_picker.at_start + replacement.items.len;
        ctx.at_picker.reset(alloc);
    } else if (ctx.model_picker.active and ctx.model_picker.results.items.len > 0) {
        const selected = ctx.model_picker.results.items[ctx.model_picker.selected];
        ctx.app.llm_client.config.model = selected.id;
        ctx.config.selected = selected.id;
        if (agent.llm.providers.findModel(selected.id)) |found| {
            ctx.app.llm_client.config.provider_name = found.provider.name;
            if (ctx.config.forProvider(found.provider.name)) |pc| {
                ctx.app.llm_client.config.base_url = pc.baseUrl;
                ctx.app.llm_client.config.api_key = pc.apiKey;
                pc.model = selected.id;
            }
        }
        agent.config.save(alloc, ctx.config.*) catch {};
        ctx.model_picker.reset(alloc);
    } else if (ctx.provider_picker.active and ctx.provider_picker.phase == .list) {
        ctx.provider_picker.phase = .key_input;
    } else if (ctx.provider_picker.active and ctx.provider_picker.phase == .key_input) {
        if (ctx.provider_picker.key_input.items.len > 0) {
            const new_key = ctx.provider_picker.key_input.items;
            const provider_name = ctx.provider_picker.selectedProvider().name;
            ctx.app.llm_client.config.api_key = new_key;
            ctx.app.llm_client.config.provider_name = provider_name;
            if (ctx.config.forProvider(provider_name)) |pc| pc.apiKey = new_key;
            agent.config.save(alloc, ctx.config.*) catch {};
        }
        ctx.provider_picker.reset(alloc);
    } else if (ctx.app.sessions.active and ctx.app.sessions.entries.items.len > 0) {
        const selected = ctx.app.sessions.entries.items[ctx.app.sessions.selected];
        ctx.app.mutex.lock();
        if (ctx.app.sessions.readFileContent(alloc, selected.filename)) |sess_ctx| {
            ctx.app.clearHistory();
            ctx.app.messages.append(alloc, .{ .role = .user, .content = sess_ctx }) catch {};
            ctx.app.appendToHistory(alloc, sess_ctx) catch {};
            ctx.app.mutex.unlock();
            std.log.info("session content:\n{s}", .{sess_ctx});
        } else |err| {
            ctx.app.mutex.unlock();
            std.log.err("failed to read session: {}", .{err});
        }
        ctx.app.sessions.reset();
    } else if (ctx.input.items.len > 0 and !ctx.app.is_loading) {
        ctx.app.mutex.lock();

        const picked = ctx.at_picker.takePicked(alloc, ctx.input.items);
        defer alloc.free(picked);
        for (picked) |p| ctx.app.pending_attachments.append(alloc, p) catch alloc.free(p);

        const user_text = try alloc.dupe(u8, ctx.input.items);
        try ctx.app.messages.append(alloc, .{ .role = .user, .content = user_text });
        ctx.app.mutex.unlock();

        try ctx.history.append(alloc, try alloc.dupe(u8, ctx.input.items));
        ctx.history_idx = null;
        ctx.draft.clearRetainingCapacity();
        ctx.input.clearRetainingCapacity();
        ctx.cursor_pos = 0;

        try spawnLlmRequest(ctx);
    }
}

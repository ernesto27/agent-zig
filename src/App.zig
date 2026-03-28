const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");

const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

pub const Role = enum { user, assistant };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

alloc: std.mem.Allocator,
messages: std.ArrayList(Message),
llm_client: *agent.llm.Client,
mutex: std.Thread.Mutex = .{},
is_loading: bool = false,
needs_redraw: bool = true,

const App = @This();

pub fn init(alloc: std.mem.Allocator, client: *agent.llm.Client) App {
    return .{
        .alloc = alloc,
        .messages = .{},
        .llm_client = client,
    };
}

pub fn deinit(self: *App) void {
    for (self.messages.items) |msg| {
        self.alloc.free(msg.content);
    }
    self.messages.deinit(self.alloc);
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

/// Function executed in a background thread to stream AI response
pub fn fetchAiResponse(self: *App, loop: *EventLoop) void {
    const alloc = self.alloc;

    // 1. Snapshot conversation history (skip empty streaming placeholder)
    self.mutex.lock();
    var llm_msgs = std.ArrayListUnmanaged(agent.llm.Message){};
    defer llm_msgs.deinit(alloc);

    for (self.messages.items) |msg| {
        if (msg.content.len == 0) continue;
        llm_msgs.append(alloc, .{
            .role = if (msg.role == .user) .user else .assistant,
            .content = msg.content,
        }) catch {};
    }
    self.mutex.unlock();

    // 2. Stream — onChunk fires per token and updates the last message in place
    std.log.info("starting stream with {d} messages", .{llm_msgs.items.len});
    var ctx = StreamCtx{ .app = self, .loop = loop };
    const result = self.llm_client.sendMessageStreaming(alloc, llm_msgs.items, &ctx, onChunk);

    // 3. On error log it and show in TUI
    if (result) |_| {} else |err| {
        std.log.err("streaming failed: {}", .{err});
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.items.len > 0) {
            const last = &self.messages.items[self.messages.items.len - 1];
            alloc.free(last.content);
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "(error: {})", .{err}) catch "(error)";
            last.content = alloc.dupe(u8, msg) catch "";
        }
    }

    self.is_loading = false;
    self.needs_redraw = true;
    wakeLoop(loop);
}

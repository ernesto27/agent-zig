const std = @import("std");
const agent = @import("agent");
const sessions = @import("sessions.zig");
const palette = @import("theme");

pub const Role = enum { user, assistant, notice };

pub const Message = struct {
    role: Role,
    content: []const u8,
    thinking: ?[]const u8 = null,
    styled_lines: ?[]const agent.markdown.StyledLine = null,
    styled_content_len: usize = 0,
    is_error: bool = false,

    pub fn styledLines(msg: *Message, alloc: std.mem.Allocator) ![]const agent.markdown.StyledLine {
        if (msg.styled_lines != null and msg.styled_content_len == msg.content.len) {
            return msg.styled_lines.?;
        }
        if (msg.styled_lines) |old| agent.markdown.freeLines(alloc, old);
        const content = try stripProposedPlanTags(alloc, msg.content);
        defer alloc.free(content);
        const lines = try agent.markdown.parse(alloc, content);
        if (msg.is_error) {
            for (lines) |line| {
                for (line.spans) |*span| {
                    span.style.fg = palette.red;
                }
            }
        }
        msg.styled_lines = lines;
        msg.styled_content_len = msg.content.len;
        return msg.styled_lines.?;
    }

    fn stripProposedPlanTags(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
        const without_open = try std.mem.replaceOwned(u8, alloc, input, "<proposed_plan>", "");
        defer alloc.free(without_open);
        return std.mem.replaceOwned(u8, alloc, without_open, "</proposed_plan>", "");
    }
};

pub const Messages = struct {
    items: std.ArrayList(Message) = .{},
    llm_history: std.ArrayList(agent.llm.Message) = .{},

    const Self = @This();
    const log = std.log.scoped(.messages);

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.freeMessages(alloc);
        self.items.deinit(alloc);
        self.llm_history.deinit(alloc);
    }

    pub fn append(self: *Self, alloc: std.mem.Allocator, msg: Message) !void {
        try self.items.append(alloc, msg);
    }

    pub fn view(self: *Self) []Message {
        return self.items.items;
    }

    pub fn count(self: *const Self) usize {
        return self.items.items.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.items.items.len == 0;
    }

    pub fn last(self: *Self) ?*Message {
        if (self.items.items.len == 0) return null;
        return &self.items.items[self.items.items.len - 1];
    }

    pub fn lastAssistant(self: *Self) ?*Message {
        var idx = self.items.items.len;
        while (idx > 0) {
            idx -= 1;
            if (self.items.items[idx].role == .assistant) return &self.items.items[idx];
        }
        return null;
    }

    pub fn appendNotice(self: *Self, alloc: std.mem.Allocator, content: []const u8) void {
        const owned = alloc.dupe(u8, content) catch return;
        self.items.append(alloc, .{ .role = .notice, .content = owned }) catch {
            alloc.free(owned);
        };
    }

    pub fn historyItems(self: *Self) []const agent.llm.Message {
        return self.llm_history.items;
    }

    pub fn historyLen(self: *const Self) usize {
        return self.llm_history.items.len;
    }

    pub fn appendToHistory(self: *Self, alloc: std.mem.Allocator, text: []const u8) !void {
        const content = try alloc.dupe(u8, text);
        try self.llm_history.append(alloc, .{ .role = .user, .content = .{ .text = content } });
    }

    pub fn pushHistory(self: *Self, alloc: std.mem.Allocator, sess: *sessions.Sessions, msg: agent.llm.Message) void {
        self.llm_history.append(alloc, msg) catch |err| {
            log.err("failed to append to llm_history: {}", .{err});
        };
        sess.appendMessage(msg);
    }

    pub fn clearLlmHistory(self: *Self, alloc: std.mem.Allocator) void {
        self.freeLlmHistory(alloc);
        self.llm_history.clearRetainingCapacity();
    }

    pub fn clear(self: *Self, alloc: std.mem.Allocator) void {
        self.freeMessages(alloc);
        self.items.clearRetainingCapacity();
        self.llm_history.clearRetainingCapacity();
    }

    pub fn resumeSession(self: *Self, alloc: std.mem.Allocator, sess: *sessions.Sessions, filename: []const u8) void {
        const records = sess.parseSessionFile(alloc, filename) catch |err| {
            log.err("failed to parse session {s}: {}", .{ filename, err });
            return;
        };
        defer alloc.free(records);

        self.clear(alloc);
        for (records) |rec| {
            const ui_role: Role = if (rec.role == .assistant) .assistant else .user;
            self.items.append(alloc, .{ .role = ui_role, .content = rec.text }) catch {
                alloc.free(rec.text);
                continue;
            };
            const dup = alloc.dupe(u8, rec.text) catch continue;
            self.llm_history.append(alloc, .{ .role = rec.role, .content = .{ .text = dup } }) catch alloc.free(dup);
        }
    }

    pub fn toString(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(alloc);

        for (self.items.items) |msg| {
            const role = switch (msg.role) {
                .user => "User",
                .assistant => "Assistant",
                .notice => "Notice",
            };

            try buf.writer(alloc).print("{s}: {s}\n", .{ role, msg.content });
            if (msg.thinking) |thinking| {
                try buf.writer(alloc).print("Thinking: {s}\n", .{thinking});
            }
        }

        return buf.toOwnedSlice(alloc);
    }

    fn freeMessages(self: *Self, alloc: std.mem.Allocator) void {
        for (self.items.items) |*msg| {
            alloc.free(msg.content);
            if (msg.thinking) |t| alloc.free(t);
            if (msg.styled_lines) |lines| agent.markdown.freeLines(alloc, lines);
        }
        self.freeLlmHistory(alloc);
    }

    fn freeLlmHistory(self: *Self, alloc: std.mem.Allocator) void {
        for (self.llm_history.items) |msg| {
            switch (msg.content) {
                .text => |t| alloc.free(t),
                .content_blocks => |blocks| {
                    for (blocks) |b| {
                        if (b.text) |t| alloc.free(t);
                        if (b.source) |src| {
                            alloc.free(src.data);
                            if (src.path) |p| alloc.free(p);
                        }
                    }
                    alloc.free(blocks);
                },
                else => {},
            }
        }
    }
};

const std = @import("std");
const messages_mod = @import("../messages.zig");
const Message = messages_mod.Message;

const log = std.log.scoped(.export_cmd);

pub const Export = struct {
    const template = @embedFile("export_template.html");
    const placeholder = "<!--MESSAGES-->";

    /// Export the conversation to a self-contained HTML file in the current
    /// directory. Returns an owned notice string describing the outcome (saved
    /// path, empty session, or failure); the caller owns and frees it.
    pub fn exportSession(allocator: std.mem.Allocator, msgs: []const Message) ![]u8 {
        var has_content = false;
        for (msgs) |m| {
            if (m.role == .user or m.role == .assistant) {
                has_content = true;
                break;
            }
        }
        if (!has_content) return allocator.dupe(u8, "Nothing to export: session is empty.");

        const html = try buildHtml(allocator, msgs);
        defer allocator.free(html);

        const filename = try std.fmt.allocPrint(allocator, "session-export-{d}.html", .{std.time.timestamp()});
        defer allocator.free(filename);

        writeFile(filename, html) catch |err| {
            log.err("export write failed: {}", .{err});
            return allocator.dupe(u8, "Export failed: could not write file.");
        };

        const abs = std.fs.cwd().realpathAlloc(allocator, filename) catch
            return allocator.dupe(u8, "Exported conversation.");
        defer allocator.free(abs);

        return std.fmt.allocPrint(allocator, "Exported conversation to {s}", .{abs});
    }

    fn buildHtml(allocator: std.mem.Allocator, msgs: []const Message) ![]u8 {
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(allocator);

        for (msgs) |msg| {
            const class: []const u8, const label: []const u8 = switch (msg.role) {
                .user => .{ "user", "User" },
                .assistant => .{ "assistant", "Assistant" },
                .notice => continue,
            };
            try body.appendSlice(allocator, "<div class=\"msg ");
            try body.appendSlice(allocator, class);
            try body.appendSlice(allocator, "\"><span class=\"role\">");
            try body.appendSlice(allocator, label);
            try body.appendSlice(allocator, "</span>");
            try appendEscaped(&body, allocator, msg.content);
            try body.appendSlice(allocator, "</div>\n");
        }

        const idx = std.mem.indexOf(u8, template, placeholder) orelse template.len;
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, template[0..idx]);
        try out.appendSlice(allocator, body.items);
        try out.appendSlice(allocator, template[idx + placeholder.len ..]);
        return out.toOwnedSlice(allocator);
    }

    fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '&' => try buf.appendSlice(allocator, "&amp;"),
                '<' => try buf.appendSlice(allocator, "&lt;"),
                '>' => try buf.appendSlice(allocator, "&gt;"),
                '"' => try buf.appendSlice(allocator, "&quot;"),
                else => try buf.append(allocator, c),
            }
        }
    }

    fn writeFile(filename: []const u8, html: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(html);
    }
};

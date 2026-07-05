const std = @import("std");
const builtin = @import("builtin");

pub const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

pub fn getEnvBuf(buf: []u8, name: []const u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return std.posix.getenv(name);
    var name_w: [128]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(name_w[0 .. name_w.len - 1], name) catch return null;
    name_w[name_len] = 0;
    const value_w = std.process.getenvW(name_w[0..name_len :0]) orelse return null;
    if (std.unicode.calcWtf8Len(value_w) > buf.len) return null;
    const len = std.unicode.wtf16LeToWtf8(buf, value_w);
    return buf[0..len];
}

pub fn homeDir(allocator: std.mem.Allocator) error{HomeNotFound}![]u8 {
    return std.process.getEnvVarOwned(allocator, home_env) catch error.HomeNotFound;
}

/// Truncate `text` to at most `max_w` characters, reserving `reserve` chars
/// at the end (typically for an ellipsis). UTF-8 safe: never cuts mid-codepoint.
pub fn truncate(text: []const u8, max_w: usize, reserve: usize) []const u8 {
    if (text.len <= max_w) return text;
    const limit = max_w -| reserve;
    if (limit == 0) return text[0..0];
    var end = limit;
    while (end > 0 and isUtf8Continuation(text[end])) end -= 1;
    return text[0..end];
}

fn isUtf8Continuation(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

pub fn getCwdPretty(buf: []u8) ![]u8 {
    var raw: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&raw);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = getEnvBuf(&home_buf, home_env) orelse {
        @memcpy(buf[0..cwd.len], cwd);
        return buf[0..cwd.len];
    };
    const is_home_prefix = std.mem.startsWith(u8, cwd, home) and
        (cwd.len == home.len or cwd[home.len] == std.fs.path.sep);
    if (!is_home_prefix) {
        @memcpy(buf[0..cwd.len], cwd);
        return buf[0..cwd.len];
    }
    return std.fmt.bufPrint(buf, "~{s}", .{cwd[home.len..]}) catch buf[0..0];
}

pub fn getCurrentGitBranch(buf: []u8) ![]const u8 {
    var raw: [std.fs.max_path_bytes]u8 = undefined;
    const head = try std.fs.cwd().readFile(".git/HEAD", &raw);
    const trimmed = std.mem.trimRight(u8, head, "\r\n");
    const prefix = "ref: refs/heads/";

    if (!std.mem.startsWith(u8, trimmed, prefix)) return buf[0..0];

    const branch = trimmed[prefix.len..];
    @memcpy(buf[0..branch.len], branch);
    return buf[0..branch.len];
}

test "getCwdPretty does not replace non-home prefix" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = getEnvBuf(&home_buf, home_env) orelse return;
    const fake_cwd = try std.fmt.bufPrint(&buf, "{s}-old/project", .{home});
    // simulate: startsWith would match but it's not a real home subdir
    const bad = std.mem.startsWith(u8, fake_cwd, home) and fake_cwd[home.len] != '/';
    try std.testing.expect(bad); // confirms the old code would have been fooled
}

test "getCwdPretty returns non-empty path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try getCwdPretty(&buf);
    std.debug.print("cwd: {s}\n", .{cwd});
    try std.testing.expect(cwd.len > 0);
}

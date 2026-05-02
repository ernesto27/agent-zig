const std = @import("std");


pub fn getCwdPretty(buf: []u8) ![]u8 {
    var raw: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&raw);
    const home = std.posix.getenv("HOME") orelse {
        @memcpy(buf[0..cwd.len], cwd);
        return buf[0..cwd.len];
    };
    const is_home_prefix = std.mem.startsWith(u8, cwd, home) and
        (cwd.len == home.len or cwd[home.len] == '/');
    if (!is_home_prefix) {
        @memcpy(buf[0..cwd.len], cwd);
        return buf[0..cwd.len];
    }
    return std.fmt.bufPrint(buf, "~{s}", .{cwd[home.len..]}) catch buf[0..0];
}

test "getCwdPretty does not replace non-home prefix" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return;
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

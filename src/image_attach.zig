const std = @import("std");

pub fn mimeFromPath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    return null;
}

/// Reads file at `path`, returns owned base64 bytes. Caller frees with `alloc`.
pub fn encodeFileBase64(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const max = 5 * 1024 * 1024;

    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(alloc, max);
    defer alloc.free(raw);

    const Enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, Enc.calcSize(raw.len));
    _ = Enc.encode(out, raw);
    return out;
}

test "mimeFromPath" {
    try std.testing.expectEqualStrings("image/png", mimeFromPath("a.png").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeFromPath("X.JPG").?);
    try std.testing.expect(mimeFromPath("foo.zig") == null);
}

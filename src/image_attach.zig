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

pub const ImageInfo = struct {
    width: u16,
    height: u16,
};

pub fn pngInfoFromPath(path: []const u8) !ImageInfo {
    return (try readPngInfo(path)) orelse error.InvalidPngHeader;
}

pub fn canUseLocalPathPreview(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".png");
}

fn readPngInfo(path: []const u8) !?ImageInfo {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [24]u8 = undefined;
    const n = try file.readAll(&header);
    if (n < header.len) return null;

    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, header[0..8], &signature)) return null;
    if (!std.mem.eql(u8, header[12..16], "IHDR")) return null;

    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    return .{
        .width = @intCast(@min(width, std.math.maxInt(u16))),
        .height = @intCast(@min(height, std.math.maxInt(u16))),
    };
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

const testing = std.testing;

test "mimeFromPath" {
    try testing.expectEqualStrings("image/png", mimeFromPath("a.png").?);
    try testing.expectEqualStrings("image/jpeg", mimeFromPath("X.JPG").?);
    try testing.expect(mimeFromPath("foo.zig") == null);
}

test "mimeFromPath covers all supported types and ignores case and directories" {
    try testing.expectEqualStrings("image/jpeg", mimeFromPath("photo.jpeg").?);
    try testing.expectEqualStrings("image/gif", mimeFromPath("anim.GIF").?);
    try testing.expectEqualStrings("image/webp", mimeFromPath("/abs/dir/pic.webp").?);
    try testing.expect(mimeFromPath("noext") == null);
    try testing.expect(mimeFromPath("archive.png.txt") == null); // extension is .txt
}

test "canUseLocalPathPreview is png-only, case-insensitive" {
    try testing.expect(canUseLocalPathPreview("shot.png"));
    try testing.expect(canUseLocalPathPreview("SHOT.PNG"));
    try testing.expect(!canUseLocalPathPreview("shot.jpg"));
    try testing.expect(!canUseLocalPathPreview("shot"));
}

fn pngHeader(width: u32, height: u32) [24]u8 {
    var header = [_]u8{0} ** 24;
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    @memcpy(header[0..8], &signature);
    @memcpy(header[12..16], "IHDR");
    std.mem.writeInt(u32, header[16..20], width, .big);
    std.mem.writeInt(u32, header[20..24], height, .big);
    return header;
}

test "pngInfoFromPath reads dimensions from a valid header" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = pngHeader(800, 600);
    try tmp.dir.writeFile(.{ .sub_path = "ok.png", .data = &header });
    const path = try tmp.dir.realpathAlloc(alloc, "ok.png");
    defer alloc.free(path);

    const info = try pngInfoFromPath(path);
    try testing.expectEqual(@as(u16, 800), info.width);
    try testing.expectEqual(@as(u16, 600), info.height);
}

test "pngInfoFromPath clamps oversized dimensions to u16 max" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = pngHeader(70000, 1); // 70000 > u16 max
    try tmp.dir.writeFile(.{ .sub_path = "big.png", .data = &header });
    const path = try tmp.dir.realpathAlloc(alloc, "big.png");
    defer alloc.free(path);

    const info = try pngInfoFromPath(path);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), info.width);
}

test "pngInfoFromPath rejects a non-png header" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "fake.png", .data = "this is not a png file!!" });
    const path = try tmp.dir.realpathAlloc(alloc, "fake.png");
    defer alloc.free(path);

    try testing.expectError(error.InvalidPngHeader, pngInfoFromPath(path));
}

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("App.zig").App;
const image_attach = @import("image_attach.zig");

pub const max_lines_per_file: usize = 10;
pub const image_preview_rows: u16 = 12;

pub const Kind = enum { header, content, placeholder, image };

pub const Line = struct {
    text: []const u8,
    kind: Kind,
};

pub const PendingImage = struct {
    path: []const u8,
    image: vaxis.Image,
};

pub fn build(arena: std.mem.Allocator, paths: []const []u8, show_images: bool) ![]Line {
    var out = std.ArrayList(Line){};

    for (paths) |path| {
        const base = std.fs.path.basename(path);
        const header = try std.fmt.allocPrint(arena, "path: {s}", .{base});
        try out.append(arena, .{ .text = header, .kind = .header });

        if (image_attach.mimeFromPath(path) != null) {
            if (show_images) {
                const owned_path = try arena.dupe(u8, path);
                try out.append(arena, .{ .text = owned_path, .kind = .image });
                continue;
            }

            const size = fileSize(path) catch 0;
            const ph = try std.fmt.allocPrint(arena, "   [image: {s} — {d} bytes]", .{ base, size });
            try out.append(arena, .{ .text = ph, .kind = .placeholder });
            continue;
        }

        readPreviewLines(arena, path, &out) catch {
            const ph = try std.fmt.allocPrint(arena, "   [unreadable: {s}]", .{base});
            try out.append(arena, .{ .text = ph, .kind = .placeholder });
        };
    }

    return out.toOwnedSlice(arena);
}

fn fileSize(path: []const u8) !u64 {
    const f = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    return stat.size;
}

fn readPreviewLines(
    arena: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList(Line),
) !void {
    const f = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var buf: [8 * 1024]u8 = undefined;
    const n = try f.read(&buf);
    const data = buf[0..n];

    if (std.mem.indexOfScalar(u8, data, 0) != null) {
        const ph = try std.fmt.allocPrint(arena, "   [binary file — {d} bytes shown]", .{n});
        try out.append(arena, .{ .text = ph, .kind = .placeholder });
        return;
    }

    var it = std.mem.splitScalar(u8, data, '\n');
    var count: usize = 0;
    while (it.next()) |line| : (count += 1) {
        if (count >= max_lines_per_file) break;
        const owned = try std.fmt.allocPrint(arena, "   {s}", .{line});
        try out.append(arena, .{ .text = owned, .kind = .content });
    }
}

pub fn requestedHeight(paths: []const []u8, show_images: bool) u16 {
    if (paths.len == 0) return 0;
    var rows: u16 = 0;
    for (paths) |path| {
        rows +|= attachmentRows(path, show_images);
    }

    return rows +| 2;
}

pub fn attachmentRows(path: []const u8, show_images: bool) u16 {
    return 1 + if (image_attach.mimeFromPath(path) != null)
        if (show_images) image_preview_rows else 1
    else
        @as(u16, @intCast(max_lines_per_file));
}

pub fn totalContentRows(paths: []const []u8, show_images: bool) usize {
    var rows: usize = 0;
    for (paths) |path| {
        rows += 1;
        if (image_attach.mimeFromPath(path) != null) {
            rows += if (show_images) image_preview_rows else 1;
        } else {
            rows += max_lines_per_file;
        }
    }
    return rows;
}

pub fn syncPendingImages(
    alloc: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    app: *App,
    pending_images: *std.ArrayList(PendingImage),
) !void {
    var idx: usize = 0;
    while (idx < pending_images.items.len) {
        if (hasAttachment(app.pending_attachments.items, pending_images.items[idx].path)) {
            idx += 1;
            continue;
        }

        const removed = pending_images.orderedRemove(idx);
        vx.freeImage(tty.writer(), removed.image.id);
        alloc.free(removed.path);
    }

    if (!vx.caps.kitty_graphics) return;

    for (app.pending_attachments.items) |path| {
        if (image_attach.mimeFromPath(path) == null) continue;
        if (hasCachedImage(pending_images.items, path)) continue;

        const image = if (image_attach.canUseLocalPathPreview(path)) blk: {
            const info = image_attach.pngInfoFromPath(path) catch break :blk vx.loadImage(alloc, tty.writer(), .{ .path = path }) catch continue;
            break :blk vx.transmitLocalImagePath(
                alloc,
                tty.writer(),
                path,
                info.width,
                info.height,
                .file,
                .png,
            ) catch vx.loadImage(alloc, tty.writer(), .{ .path = path }) catch continue;
        } else vx.loadImage(alloc, tty.writer(), .{ .path = path }) catch continue;

        const owned_path = try alloc.dupe(u8, path);
        pending_images.append(alloc, .{ .path = owned_path, .image = image }) catch {
            alloc.free(owned_path);
            vx.freeImage(tty.writer(), image.id);
            return error.OutOfMemory;
        };
    }
}

pub fn deinitPendingImages(
    alloc: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    pending_images: *std.ArrayList(PendingImage),
) void {
    for (pending_images.items) |pending_image| {
        vx.freeImage(tty.writer(), pending_image.image.id);
        alloc.free(pending_image.path);
    }
    pending_images.deinit(alloc);
}

pub fn findPendingImage(pending_images: []const PendingImage, path: []const u8) ?PendingImage {
    for (pending_images) |pending_image| {
        if (std.mem.eql(u8, pending_image.path, path)) return pending_image;
    }
    return null;
}

fn hasAttachment(paths: []const []u8, target: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, target)) return true;
    }
    return false;
}

fn hasCachedImage(pending_images: []const PendingImage, target: []const u8) bool {
    for (pending_images) |pending_image| {
        if (std.mem.eql(u8, pending_image.path, target)) return true;
    }
    return false;
}

//! Self-update command. Port of scripts/install.sh:
//! resolve latest GitHub release, download the linux/x86_64 tarball,
//! extract the binary, install to ~/.local/bin via an atomic rename.
const std = @import("std");
const builtin = @import("builtin");

const repo = "ernesto27/agent-zig";
const binary = "agent-zig";
const asset = "agent-zig-linux-x86_64.tar.gz";
const api_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
const user_agent = "agent-zig-updater";

pub fn run(allocator: std.mem.Allocator) !void {
    // 1. OS/arch guard — only linux/x86_64 release builds exist.
    if (builtin.target.os.tag != .linux or builtin.target.cpu.arch != .x86_64) {
        std.debug.print("error: only linux x86_64 is supported\n", .{});
        return error.UnsupportedPlatform;
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = user_agent },
    };

    // 2. Resolve latest release -> download URL.
    std.debug.print("Resolving latest release for {s} ...\n", .{repo});
    var api_aw = std.Io.Writer.Allocating.init(allocator);
    defer api_aw.deinit();

    const api_res = try client.fetch(.{
        .location = .{ .url = api_url },
        .method = .GET,
        .extra_headers = &headers,
        .response_writer = &api_aw.writer,
    });
    if (api_res.status != .ok) {
        std.debug.print("error: GitHub API returned HTTP {d}\n", .{@intFromEnum(api_res.status)});
        return error.HttpRequestFailed;
    }

    const api_body = api_aw.written();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, api_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const download_url = findAssetUrl(parsed.value) orelse {
        std.debug.print("error: asset '{s}' not found in latest release\n", .{asset});
        return error.AssetNotFound;
    };

    // 3. Download the tarball into memory.
    std.debug.print("Downloading {s} from {s} ...\n", .{ binary, download_url });
    var tgz_aw = std.Io.Writer.Allocating.init(allocator);
    defer tgz_aw.deinit();

    const dl_res = try client.fetch(.{
        .location = .{ .url = download_url },
        .method = .GET,
        .extra_headers = &headers,
        .response_writer = &tgz_aw.writer,
    });
    if (dl_res.status != .ok) {
        std.debug.print("error: download returned HTTP {d}\n", .{@intFromEnum(dl_res.status)});
        return error.HttpRequestFailed;
    }
    const tgz_bytes = tgz_aw.written();

    // 4. Resolve install paths.
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const dir = try std.fs.path.join(allocator, &.{ home, ".local", "bin" });
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const final_path = try std.fs.path.join(allocator, &.{ dir, binary });
    defer allocator.free(final_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{final_path});
    defer allocator.free(tmp_path);
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // 5. Decompress + untar, streaming the matching entry into the temp file.
    if (!try extractBinary(tgz_bytes, tmp_path)) {
        std.debug.print("error: binary '{s}' not found in tarball\n", .{binary});
        return error.BinaryNotFound;
    }

    // Atomic swap into place so a half-written file never replaces a working one.
    try std.fs.renameAbsolute(tmp_path, final_path);

    std.debug.print("\n{s} installed to {s}\n", .{ binary, final_path });

    // 6. PATH hint.
    const path_env = std.posix.getenv("PATH") orelse "";
    if (!onPath(path_env, dir)) {
        std.debug.print("\n  Add this to your shell profile:\n", .{});
        std.debug.print("    export PATH=\"$HOME/.local/bin:$PATH\"\n", .{});
    }
}

/// Find assets[].browser_download_url where name == asset.
fn findAssetUrl(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const assets = (root.object.get("assets") orelse return null);
    if (assets != .array) return null;
    for (assets.array.items) |item| {
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, asset)) continue;
        const url = item.object.get("browser_download_url") orelse return null;
        if (url == .string) return url.string;
    }
    return null;
}

/// Gunzip + untar `tgz_bytes`, writing the entry whose name ends with `binary`
/// to `dest_path` with mode 0o755. Returns true if the binary was found.
fn extractBinary(tgz_bytes: []const u8, dest_path: []const u8) !bool {
    var in: std.Io.Reader = .fixed(tgz_bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gunzip: std.compress.flate.Decompress = .init(&in, .gzip, &window);

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gunzip.reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.basename(entry.name), binary)) continue;

        const file = try std.fs.createFileAbsolute(dest_path, .{ .truncate = true, .mode = 0o755 });
        defer file.close();

        var io_buf: [16 * 1024]u8 = undefined;
        var fw = file.writer(&io_buf);
        try it.streamRemaining(entry, &fw.interface);
        try fw.interface.flush();
        try file.chmod(0o755); // ensure exec bit regardless of umask
        return true;
    }
    return false;
}

/// True if `dir` appears as a `:`-delimited entry in `path_env`.
fn onPath(path_env: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

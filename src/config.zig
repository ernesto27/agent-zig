const std = @import("std");
const log = std.log.scoped(.config);

pub const Config = struct {
    apiKey: []const u8,
    baseUrl: []const u8,
    model: []const u8,
};

fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &.{ home, ".config", "agent-zig" });
}

fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "config.json" });
}

fn ensureConfigExists(allocator: std.mem.Allocator) !void {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const path = try configPath(allocator);
    defer allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch {
        const empty = Config{ .apiKey = "", .baseUrl = "", .model = "" };
        const json = try std.json.Stringify.valueAlloc(allocator, empty, .{ .whitespace = .indent_4 });
        defer allocator.free(json);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json);

        log.info("created config template at: {s}", .{path});
    };
}

pub fn save(allocator: std.mem.Allocator, cfg: Config) !void {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const json = try std.json.Stringify.valueAlloc(allocator, cfg, .{ .whitespace = .indent_4 });
    defer allocator.free(json);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);

    log.info("saved config to {s}", .{path});
}

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    try ensureConfigExists(allocator);

    const path = try configPath(allocator);
    defer allocator.free(path);

    log.info("Loading config from {s}", .{path});

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return err;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(Config, allocator, content, .{
        .allocate = .alloc_always,
    }) catch |err| {
        return err;
    };

    return parsed;
}

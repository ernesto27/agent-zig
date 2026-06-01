const std = @import("std");
const log = std.log.scoped(.config);

pub const ProviderConfig = struct {
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
};

pub const Providers = struct {
    selected: []const u8 = "",
    anthropic: ProviderConfig = .{ .baseUrl = "https://api.anthropic.com" },
    openai: ProviderConfig = .{ .baseUrl = "https://api.openai.com" },
    deepseek: ProviderConfig = .{ .baseUrl = "https://api.deepseek.com/anthropic" },

    pub fn forProvider(self: *Providers, name: []const u8) ?*ProviderConfig {
        if (std.mem.eql(u8, name, "Anthropic")) return &self.anthropic;
        if (std.mem.eql(u8, name, "OpenAI")) return &self.openai;
        if (std.mem.eql(u8, name, "DeepSeek")) return &self.deepseek;
        return null;
    }
};

pub const SessionEntry = struct {
    name: []const u8 = "",
    file: []const u8 = "",
};

pub const Config = struct {
    providers: Providers = .{},
    sessions: []const SessionEntry = &.{},
    mcpServers: std.json.Value = .null,
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
        const empty = Config{ .providers = .{} };
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

pub fn createSession(allocator: std.mem.Allocator, cfg: *Config, file: []const u8, name: []const u8) !void {
    const sessions = try allocator.alloc(SessionEntry, cfg.sessions.len + 1);
    errdefer allocator.free(sessions);

    for (cfg.sessions, 0..) |session, i| {
        sessions[i] = session;
    }

    const file_copy = try allocator.dupe(u8, file);
    errdefer allocator.free(file_copy);

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    sessions[cfg.sessions.len] = .{
        .name = name_copy,
        .file = file_copy,
    };

    var tmp = cfg.*;
    tmp.sessions = sessions;
    try save(allocator, tmp);
    cfg.sessions = sessions;
}

pub fn renameSession(allocator: std.mem.Allocator, cfg: *Config, file: []const u8, new_name: []const u8) !void {
    const sessions = try allocator.alloc(SessionEntry, cfg.sessions.len);
    errdefer allocator.free(sessions);

    var found = false;
    for (cfg.sessions, 0..) |session, i| {
        if (std.mem.eql(u8, session.file, file)) {
            sessions[i] = .{ .name = try allocator.dupe(u8, new_name), .file = session.file };
            found = true;
        } else {
            sessions[i] = session;
        }
    }
    if (!found) {
        allocator.free(sessions);
        return error.SessionNotFound;
    }

    var tmp = cfg.*;
    tmp.sessions = sessions;
    try save(allocator, tmp);
    cfg.sessions = sessions;
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

const std = @import("std");
const log = std.log.scoped(.config);

pub const Effort = enum {
    none,
    low,
    medium,
    high,
    max,

    pub fn next(self: Effort) Effort {
        return switch (self) {
            .none => .low,
            .low => .medium,
            .medium => .high,
            .high => .max,
            .max => .none,
        };
    }

    pub fn label(self: Effort) []const u8 {
        return switch (self) {
            .none => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .max => "max",
        };
    }

    /// The value sent to the LLM (and persisted to config.json), as opposed
    /// to `label()` which is the TUI display string ("off" for .none).
    pub fn apiValue(self: Effort) []const u8 {
        return @tagName(self);
    }
};

pub const ProviderConfig = struct { apiKey: []const u8 = "", baseUrl: []const u8 = "", model: []const u8 = "", thinkEffort: []const u8 = "" };

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

/// Pure data record — maps 1:1 to config.json. No behavior, no allocator.
pub const Config = struct {
    providers: Providers = .{},
    sessions: []const SessionEntry = &.{},
    mcpServers: std.json.Value = .null,
};

/// Owns the loaded config along with the allocator and parse arena backing it.
/// All mutating operations live here so call sites don't thread an allocator or
/// the Config around. `cfg` is the live, in-memory config; `parsed` keeps its
/// string fields alive until `deinit`.
pub const ConfigStore = struct {
    allocator: std.mem.Allocator,
    /// Owns every allocation produced by runtime mutations (session arrays,
    /// duped names, effort strings). Freed wholesale in `deinit`, which avoids
    /// having to track whether a replaced value came from the parse arena or
    /// from a prior mutation.
    arena: std.heap.ArenaAllocator,
    parsed: std.json.Parsed(Config),
    cfg: Config,

    pub fn init(allocator: std.mem.Allocator) !ConfigStore {
        try ensureConfigExists(allocator);

        const path = try configPath(allocator);
        defer allocator.free(path);

        log.info("Loading config from {s}", .{path});

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
            .allocate = .alloc_always,
        });

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .parsed = parsed,
            .cfg = parsed.value,
        };
    }

    pub fn deinit(self: *ConfigStore) void {
        self.arena.deinit();
        self.parsed.deinit();
    }

    /// Serialize the given config snapshot to config.json (truncating).
    fn write(self: *ConfigStore, cfg: Config) !void {
        const path = try configPath(self.allocator);
        defer self.allocator.free(path);

        const json = try std.json.Stringify.valueAlloc(self.allocator, cfg, .{ .whitespace = .indent_4 });
        defer self.allocator.free(json);

        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);

        log.info("saved config to {s}", .{path});
    }

    pub fn save(self: *ConfigStore) !void {
        try self.write(self.cfg);
    }

    pub fn createSession(self: *ConfigStore, file: []const u8, name: []const u8) !void {
        const allocator = self.arena.allocator();

        const sessions = try allocator.alloc(SessionEntry, self.cfg.sessions.len + 1);
        errdefer allocator.free(sessions);

        for (self.cfg.sessions, 0..) |session, i| {
            sessions[i] = session;
        }

        const file_copy = try allocator.dupe(u8, file);
        errdefer allocator.free(file_copy);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        sessions[self.cfg.sessions.len] = .{
            .name = name_copy,
            .file = file_copy,
        };

        var tmp = self.cfg;
        tmp.sessions = sessions;
        try self.write(tmp);
        self.cfg.sessions = sessions;
    }

    pub fn renameSession(self: *ConfigStore, file: []const u8, new_name: []const u8) !void {
        const allocator = self.arena.allocator();

        const sessions = try allocator.alloc(SessionEntry, self.cfg.sessions.len);
        errdefer allocator.free(sessions);

        var found = false;
        for (self.cfg.sessions, 0..) |session, i| {
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

        var tmp = self.cfg;
        tmp.sessions = sessions;
        try self.write(tmp);
        self.cfg.sessions = sessions;
    }

    pub fn updateThinkEffort(self: *ConfigStore, provider_name: []const u8, effort: Effort) !void {
        var tmp = self.cfg;
        const provider = tmp.providers.forProvider(provider_name) orelse return error.ProviderNotFound;

        const effort_copy = try self.arena.allocator().dupe(u8, effort.apiValue());

        provider.thinkEffort = effort_copy;
        try self.write(tmp);
        self.cfg.providers = tmp.providers;
    }

    /// The persisted thinking effort for a provider, parsed back from its
    /// stored `thinkEffort` string. Falls back to .none if unset/unrecognized.
    pub fn thinkEffort(self: *ConfigStore, provider_name: []const u8) Effort {
        const provider = self.cfg.providers.forProvider(provider_name) orelse return .none;
        return std.meta.stringToEnum(Effort, provider.thinkEffort) orelse .none;
    }
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

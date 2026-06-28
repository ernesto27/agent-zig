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
    gemini: ProviderConfig = .{ .baseUrl = "https://generativelanguage.googleapis.com" },

    pub fn forProvider(self: *Providers, name: []const u8) ?*ProviderConfig {
        if (std.mem.eql(u8, name, "Anthropic")) return &self.anthropic;
        if (std.mem.eql(u8, name, "OpenAI")) return &self.openai;
        if (std.mem.eql(u8, name, "DeepSeek")) return &self.deepseek;
        if (std.mem.eql(u8, name, "Gemini")) return &self.gemini;
        return null;
    }
};

pub const SessionEntry = struct {
    name: []const u8 = "",
    file: []const u8 = "",
};

pub const TrustedFolder = struct {
    path: []const u8 = "",
};

pub const HttpHeaders = std.json.ArrayHashMap([]const u8);

/// One `mcpServers` entry from config.json. A server is either stdio
/// (`command` + `args`) or http (`type` = "http" + `url`); the unused fields
/// stay at their empty defaults.
pub const McpServerConfig = struct {
    type: []const u8 = "",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    url: []const u8 = "",
    headers: HttpHeaders = .{},
};

pub const Settings = struct { showThinkingBlock: bool = true };

/// The whole `mcpServers` block: a name-keyed map of server configs, matching
/// the JSON object `{ "<name>": { ... } }`. Iterate via `.map`.
pub const McpServers = std.json.ArrayHashMap(McpServerConfig);

/// Pure data record — maps 1:1 to config.json. No behavior, no allocator.
pub const Config = struct {
    providers: Providers = .{},
    sessions: []const SessionEntry = &.{},
    trustedFolders: []const TrustedFolder = &.{},
    mcpServers: McpServers = .{},
    settings: Settings = .{},
    dockerImage: []const u8 = "ubuntu:24.04",
};

pub fn isTrusted(folders: []const TrustedFolder, cwd: []const u8) bool {
    for (folders) |f| if (std.mem.eql(u8, f.path, cwd)) return true;
    return false;
}

const apiKeyEnvVars = std.StaticStringMap([]const u8).initComptime(.{
    .{ "DeepSeek", "DEEPSEEK_API_KEY" },
});

/// If the provider has a corresponding *_API_KEY env var, return its value
/// (non-empty). Returns null when the var is not set, empty, or the provider
/// isn't mapped yet.
pub fn envApiKey(provider_name: []const u8) ?[]const u8 {
    const env_var = apiKeyEnvVars.get(provider_name) orelse return null;
    const key = std.posix.getenv(env_var) orelse return null;
    if (key.len == 0) return null;
    return key;
}

/// If api_key is empty, try the *_API_KEY env var for the given provider.
/// Logs when the env var fallback is used. Call after reading the config key.
pub fn resolveApiKey(api_key: *[]const u8, provider_name: []const u8) void {
    if (api_key.*.len > 0) return;
    const env_key = envApiKey(provider_name) orelse return;
    api_key.* = env_key;
    log.info("using {s}_API_KEY from environment", .{provider_name});
}

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

    /// Set any cfg field to `value` and persist. Dispatch is on the *field*
    /// type: only `[]const u8` fields are duped into the arena (so a borrowed
    /// slice outlives the call); every other field type is assigned by value.
    /// For a `[]const u8` field the `value` may be any slice that coerces to it
    /// (`[]u8`, `[:0]const u8`, a literal) — `dupe` handles the coercion.
    /// `field` is a pointer to the target field, e.g.:
    ///   try store.set(&store.cfg.dockerImage, "node:20");            // duped
    ///   try store.set(&store.cfg.settings.showThinkingBlock, true);  // by value
    pub fn set(self: *ConfigStore, field: anytype, value: anytype) !void {
        const Field = @typeInfo(@TypeOf(field)).pointer.child;
        if (Field == []const u8) {
            field.* = try self.arena.allocator().dupe(u8, value);
        } else {
            field.* = value;
        }
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

    pub fn addTrustedFolder(self: *ConfigStore, path: []const u8) !void {
        const allocator = self.arena.allocator();

        const folders = try allocator.alloc(TrustedFolder, self.cfg.trustedFolders.len + 1);

        for (self.cfg.trustedFolders, 0..) |folder, i| {
            folders[i] = folder;
        }

        folders[self.cfg.trustedFolders.len] = .{ .path = try allocator.dupe(u8, path) };

        var tmp = self.cfg;
        tmp.trustedFolders = folders;
        try self.write(tmp);
        self.cfg.trustedFolders = folders;
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

    /// Find a persisted session by its full `.file` ("...-808a3d09.jsonl").
    /// Returns the stored filename (borrowed from the config) or null.
    pub fn sessionByFile(self: *const ConfigStore, file: []const u8) ?[]const u8 {
        for (self.cfg.sessions) |s| {
            if (std.mem.eql(u8, s.file, file)) return s.file;
        }
        return null;
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

// === Tests ===

const testing = std.testing;

test "Effort.next cycles through every level and wraps to none" {
    try testing.expectEqual(Effort.low, Effort.none.next());
    try testing.expectEqual(Effort.medium, Effort.low.next());
    try testing.expectEqual(Effort.high, Effort.medium.next());
    try testing.expectEqual(Effort.max, Effort.high.next());
    try testing.expectEqual(Effort.none, Effort.max.next()); // wraps
}

test "Effort.label shows off for none, tag name otherwise" {
    try testing.expectEqualStrings("off", Effort.none.label());
    try testing.expectEqualStrings("low", Effort.low.label());
    try testing.expectEqualStrings("max", Effort.max.label());
}

test "Effort.apiValue round-trips through stringToEnum for every variant" {
    // thinkEffort() relies on this: whatever apiValue() persists must parse back.
    // Note none->"none" (not "off"), which is why apiValue differs from label.
    inline for (std.meta.tags(Effort)) |variant| {
        const parsed = std.meta.stringToEnum(Effort, variant.apiValue());
        try testing.expectEqual(variant, parsed.?);
    }
    try testing.expectEqualStrings("none", Effort.none.apiValue());
}

test "Providers.forProvider maps known names and rejects unknown" {
    var providers = Providers{};
    try testing.expectEqual(&providers.anthropic, providers.forProvider("Anthropic").?);
    try testing.expectEqual(&providers.openai, providers.forProvider("OpenAI").?);
    try testing.expectEqual(&providers.deepseek, providers.forProvider("DeepSeek").?);
    try testing.expect(providers.forProvider("Unknown") == null);
    try testing.expect(providers.forProvider("anthropic") == null); // case-sensitive
}

test "Providers default base URLs" {
    var providers = Providers{};
    try testing.expectEqualStrings("https://api.anthropic.com", providers.forProvider("Anthropic").?.baseUrl);
    try testing.expectEqualStrings("https://api.deepseek.com/anthropic", providers.forProvider("DeepSeek").?.baseUrl);
}

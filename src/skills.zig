const std = @import("std");
const utils = @import("utils.zig");

const log = std.log.scoped(.skills);

const skills_root = ".agents/skills";
const skill_file_name = "SKILL.md";
const max_skill_bytes = 512 * 1024;
const max_resource_bytes = 1024 * 1024;

pub fn buildSkillPrompt(alloc: std.mem.Allocator, skill_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "Use the `skill` tool to load and apply the `{s}` skill for this conversation.",
        .{skill_name},
    );
}

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    license: ?[]const u8,
    metadata: ?[]const u8,
    dir_path: []const u8,
    enabled: bool = true,

    fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.license) |v| allocator.free(v);
        if (self.metadata) |v| allocator.free(v);
        allocator.free(self.dir_path);
    }
};

pub const Registry = struct {
    skills: std.ArrayList(Skill) = .{},
    home: []const u8,
    skills_home_path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Registry {
        const home = try utils.homeDir(allocator);
        errdefer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, skills_root });
        return .{ .home = home, .skills_home_path = path };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.skills.items) |*skill| skill.deinit(allocator);
        self.skills.deinit(allocator);
        allocator.free(self.home);
        allocator.free(self.skills_home_path);
    }

    pub fn load(self: *Registry, allocator: std.mem.Allocator) !void {
        var dir = std.fs.cwd().openDir(skills_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close();

        var map = std.StringHashMap(bool).init(allocator);
        defer {
            var kit = map.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            map.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const gop = try map.getOrPut(entry.name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, entry.name);
                gop.value_ptr.* = false;
            }
        }

        try self.loadHomeSkills(&map);

        var it = map.iterator();
        while (it.next()) |entry| {
            const name_skill = entry.key_ptr.*;
            const is_home = entry.value_ptr.*;

            self.loadOne(allocator, name_skill, is_home) catch |err| {
                log.warn("skipping skill '{s}': {}", .{ name_skill, err });
                continue;
            };
        }
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Skill {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    pub fn buildAvailableSkillsMarkdown(self: *const Registry, allocator: std.mem.Allocator) ![]u8 {
        if (self.skills.items.len == 0) {
            return allocator.dupe(u8, "Available skills: none.");
        }

        var out = std.ArrayList(u8){};
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "Available skills:\n\n");
        for (self.skills.items) |skill| {
            if (!skill.enabled) continue;
            if (skill.license) |lic| {
                try out.writer(allocator).print("- `{s}`: {s} (license: {s})\n", .{ skill.name, skill.description, lic });
            } else {
                try out.writer(allocator).print("- `{s}`: {s}\n", .{ skill.name, skill.description });
            }
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn readSkill(self: *const Registry, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const skill = self.find(name) orelse return error.SkillNotFound;
        const path = try std.fs.path.join(allocator, &.{ skill.dir_path, skill_file_name });
        defer allocator.free(path);
        return readFile(allocator, path, max_skill_bytes);
    }

    pub fn readResource(self: *const Registry, allocator: std.mem.Allocator, name: []const u8, resource_path: []const u8) ![]u8 {
        const skill = self.find(name) orelse return error.SkillNotFound;
        try validateResourcePath(resource_path);
        const path = try std.fs.path.join(allocator, &.{ skill.dir_path, resource_path });
        defer allocator.free(path);
        return readFile(allocator, path, max_resource_bytes);
    }

    pub fn resolveScriptPath(self: *const Registry, allocator: std.mem.Allocator, name: []const u8, script_path: []const u8) ![]u8 {
        const skill = self.find(name) orelse return error.SkillNotFound;
        try validateResourcePath(script_path);

        const normalized = if (std.mem.startsWith(u8, script_path, "scripts/"))
            script_path
        else if (std.mem.indexOfScalar(u8, script_path, '/') == null)
            try std.mem.concat(allocator, u8, &.{ "scripts/", script_path })
        else
            return error.InvalidScriptPath;
        defer if (normalized.ptr != script_path.ptr) allocator.free(normalized);

        return std.fs.path.join(allocator, &.{ skill.dir_path, normalized });
    }

    fn loadOne(self: *Registry, allocator: std.mem.Allocator, dir_name: []const u8, is_home: bool) !void {
        if (!isValidName(dir_name)) return error.InvalidSkillName;

        const base = if (is_home) self.skills_home_path else skills_root;
        const dir_path = try std.fs.path.join(allocator, &.{ base, dir_name });
        errdefer allocator.free(dir_path);

        const skill_path = try std.fs.path.join(allocator, &.{ dir_path, skill_file_name });
        defer allocator.free(skill_path);

        const content = try readFile(allocator, skill_path, max_skill_bytes);
        defer allocator.free(content);

        const parsed = try parseFrontmatter(allocator, content);
        errdefer {
            allocator.free(parsed.name);
            allocator.free(parsed.description);
        }

        if (!std.mem.eql(u8, parsed.name, dir_name)) return error.SkillNameMismatch;
        if (!isValidName(parsed.name)) return error.InvalidSkillName;
        if (parsed.description.len == 0 or parsed.description.len > 1024) return error.InvalidSkillDescription;

        errdefer {
            if (parsed.license) |v| allocator.free(v);
            if (parsed.metadata) |v| allocator.free(v);
        }

        try self.skills.append(allocator, .{
            .name = parsed.name,
            .description = parsed.description,
            .license = parsed.license,
            .metadata = parsed.metadata,
            .dir_path = dir_path,
        });
    }

    fn loadHomeSkills(self: *Registry, map: *std.StringHashMap(bool)) !void {
        var dirHome = std.fs.openDirAbsolute(self.skills_home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dirHome.close();

        var iterHome = dirHome.iterate();
        while (try iterHome.next()) |entry| {
            if (entry.kind != .directory) continue;
            const gop = try map.getOrPut(entry.name);
            if (gop.found_existing) continue;
            log.info("skills home path not in current: {s}", .{entry.name});
            gop.key_ptr.* = try map.allocator.dupe(u8, entry.name);
            gop.value_ptr.* = true;
        }
    }
};

const ParsedFrontmatter = struct {
    name: []u8,
    description: []u8,
    license: ?[]u8 = null,
    metadata: ?[]u8 = null,
};

fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !ParsedFrontmatter {
    if (!std.mem.startsWith(u8, content, "---")) return error.MissingFrontmatter;
    const start: usize = if (std.mem.startsWith(u8, content, "---\r\n"))
        5
    else if (std.mem.startsWith(u8, content, "---\n"))
        4
    else
        return error.MissingFrontmatter;

    const close_rel = std.mem.indexOf(u8, content[start..], "\n---") orelse return error.MissingFrontmatterEnd;
    const frontmatter = content[start .. start + close_rel];

    var name: ?[]u8 = null;
    var description: ?[]u8 = null;
    var license: ?[]u8 = null;
    var metadata: ?[]u8 = null;

    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "name:")) {
            if (name) |old| allocator.free(old);
            name = try dupScalarValue(allocator, trimmed["name:".len..]);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "description:")) {
            if (description) |old| allocator.free(old);
            const value = std.mem.trim(u8, trimmed["description:".len..], " \t");
            if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, "|")) {
                description = try collectBlockScalar(allocator, &lines);
            } else {
                description = try dupScalarValue(allocator, value);
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "license:")) {
            if (license) |old| allocator.free(old);
            license = try dupScalarValue(allocator, trimmed["license:".len..]);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "metadata:")) {
            if (metadata) |old| allocator.free(old);
            const value = std.mem.trim(u8, trimmed["metadata:".len..], " \t");
            if (value.len == 0) {
                metadata = try collectRawBlock(allocator, &lines);
            } else {
                metadata = try allocator.dupe(u8, value);
            }
            continue;
        }
    }

    if (name == null) {
        if (description) |v| allocator.free(v);
        if (license) |v| allocator.free(v);
        if (metadata) |v| allocator.free(v);
        return error.MissingSkillName;
    }
    if (description == null) {
        allocator.free(name.?);
        if (license) |v| allocator.free(v);
        if (metadata) |v| allocator.free(v);
        return error.MissingSkillDescription;
    }

    return .{
        .name = name.?,
        .description = description.?,
        .license = license,
        .metadata = metadata,
    };
}

fn dupScalarValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
        }
    }
    return allocator.dupe(u8, trimmed);
}

fn collectBlockScalar(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar)) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') break;

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, trimmed);
    }

    return out.toOwnedSlice(allocator);
}

fn collectRawBlock(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar)) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') break;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, std.mem.trimRight(u8, line, " \t"));
    }
    return out.toOwnedSlice(allocator);
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;

    var prev_hyphen = false;
    for (name) |ch| {
        const valid = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-';
        if (!valid) return false;
        if (ch == '-' and prev_hyphen) return false;
        prev_hyphen = ch == '-';
    }
    return true;
}

fn validateResourcePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidResourcePath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidResourcePath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidResourcePath;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidResourcePath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidResourcePath;
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file) return error.NotAFile;

    return file.readToEndAlloc(allocator, max_bytes);
}

const std = @import("std");
const vaxis = @import("vaxis");
const modal_list = @import("modal_list.zig");

const log = std.log.scoped(.sessions);

const SessionEntry = struct { filename: []const u8, preview: []const u8, date: []const u8 };

pub const Sessions = struct {
    pub const max_visible: usize = 12;
    file: ?std.fs.File = null,
    pending_path: ?[]const u8 = null,
    active: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    allocator: std.mem.Allocator = undefined,
    entries: std.ArrayListUnmanaged(SessionEntry) = .{},

    pub fn open(self: *Sessions) void {
        self.active = true;
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn reset(self: *Sessions) void {
        self.active = false;
        self.selected = 0;
        self.scroll = 0;
    }

    fn sessionsDir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "sessions" });
    }

    pub fn init(self: *Sessions, allocator: std.mem.Allocator) !void {
        const dir_path = try sessionsDir(allocator);
        defer allocator.free(dir_path);
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        self.allocator = allocator;
        self.loadEntries(allocator, dir_path) catch |err| {
            log.err("failed to load session entries: {}", .{err});
        };

        self.pending_path = try self.createPendingPath();
    }

    fn loadEntries(self: *Sessions, allocator: std.mem.Allocator, dir_path: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer dir.close();

        const FileInfo = struct { name: []const u8, mtime: i128 };
        var file_list = std.ArrayListUnmanaged(FileInfo){};
        defer {
            for (file_list.items) |f| allocator.free(f.name);
            file_list.deinit(allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
            const stat = dir.statFile(entry.name) catch continue;
            const name_copy = try allocator.dupe(u8, entry.name);
            try file_list.append(allocator, .{ .name = name_copy, .mtime = stat.mtime });
        }

        std.mem.sort(FileInfo, file_list.items, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                return a.mtime > b.mtime;
            }
        }.lessThan);

        for (file_list.items) |f| {
            const filename = try allocator.dupe(u8, f.name);
            const date = try relativeTime(allocator, f.mtime);
            const preview = readFirstLine(allocator, dir, f.name) catch try allocator.dupe(u8, f.name);
            try self.entries.append(allocator, .{ .filename = filename, .preview = preview, .date = date });
        }
    }

    pub fn fork(self: *Sessions, text: []const u8) !void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        if (self.pending_path) |p| {
            self.allocator.free(p);
            self.pending_path = null;
        }

        self.pending_path = try self.createPendingPath();
        self.appendFmt(self.allocator, "{s}", .{text});
    }

    fn createPendingPath(self: *Sessions) ![]const u8 {
        const allocator = self.allocator;
        const dir_path = try sessionsDir(allocator);
        defer allocator.free(dir_path);

        const filename = try Sessions.generateFilename(allocator);
        defer allocator.free(filename);

        return std.fs.path.join(allocator, &.{ dir_path, filename });
    }

    const secs_per_month: u64 = 30 * std.time.s_per_day;
    const secs_per_year: u64 = 365 * std.time.s_per_day;

    fn relativeTime(allocator: std.mem.Allocator, mtime_ns: i128) ![]const u8 {
        const now: i128 = std.time.nanoTimestamp();
        const diff: i128 = @divTrunc(now - mtime_ns, std.time.ns_per_s);
        const s: u64 = if (diff < 0) 0 else @intCast(diff);

        if (s < std.time.s_per_min) return allocator.dupe(u8, "just now");
        if (s < std.time.s_per_hour) {
            const n = s / std.time.s_per_min;
            return std.fmt.allocPrint(allocator, "{d} minute{s} ago", .{ n, plural(n) });
        }
        if (s < std.time.s_per_day) {
            const n = s / std.time.s_per_hour;
            return std.fmt.allocPrint(allocator, "{d} hour{s} ago", .{ n, plural(n) });
        }
        if (s < 2 * std.time.s_per_day) return allocator.dupe(u8, "yesterday");
        if (s < std.time.s_per_week) {
            const n = s / std.time.s_per_day;
            return std.fmt.allocPrint(allocator, "{d} days ago", .{n});
        }
        if (s < secs_per_month) {
            const n = s / std.time.s_per_week;
            return std.fmt.allocPrint(allocator, "{d} week{s} ago", .{ n, plural(n) });
        }
        if (s < secs_per_year) {
            const n = s / secs_per_month;
            return std.fmt.allocPrint(allocator, "{d} month{s} ago", .{ n, plural(n) });
        }
        const n = s / secs_per_year;
        return std.fmt.allocPrint(allocator, "{d} year{s} ago", .{ n, plural(n) });
    }

    fn plural(n: u64) []const u8 {
        return if (n == 1) "" else "s";
    }

    fn readFirstLine(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![]const u8 {
        var file = try dir.openFile(name, .{});
        defer file.close();
        var buf: [80]u8 = undefined;
        const n = try file.read(&buf);
        if (n == 0) return error.Empty;
        const line = std.mem.sliceTo(buf[0..n], '\n');
        if (line.len == 0) return error.Empty;
        return allocator.dupe(u8, line);
    }

    fn generateFilename(allocator: std.mem.Allocator) ![]const u8 {
        const epoch = std.time.epoch;
        const ts: u64 = @intCast(std.time.timestamp());
        const epoch_secs = epoch.EpochSeconds{ .secs = ts };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const year = year_day.year;
        const month: u8 = @intCast(@intFromEnum(month_day.month));
        const day: u8 = month_day.day_index + 1;

        const day_secs = epoch_secs.getDaySeconds();
        const hour: u8 = @intCast(day_secs.secs / 3600);
        const minute: u8 = @intCast((day_secs.secs % 3600) / 60);
        const second: u8 = @intCast(day_secs.secs % 60);

        var rand_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        const hex = std.fmt.bytesToHex(rand_bytes, .lower);

        return std.fmt.allocPrint(
            allocator,
            "{d:0>2}-{d:0>2}-{d}-{d:0>2}:{d:0>2}:{d:0>2}-{s}.log",
            .{ day, month, year, hour, minute, second, hex },
        );
    }

    pub fn deinit(self: *Sessions) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        if (self.pending_path) |p| {
            self.allocator.free(p);
            self.pending_path = null;
        }
        if (self.entries.capacity > 0) {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.filename);
                self.allocator.free(entry.preview);
                self.allocator.free(entry.date);
            }
            self.entries.deinit(self.allocator);
        }
    }

    pub fn render(self: *const Sessions, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const count = @min(max_visible, self.entries.items.len -| self.scroll);
        var items_buf: [max_visible]modal_list.Item = undefined;
        for (0..count) |i| {
            const entry = self.entries.items[self.scroll + i];
            items_buf[i] = .{ .primary = entry.preview, .secondary = entry.date };
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " Resume session",
            .items = items_buf[0..count],
            .selected = self.selected -| self.scroll,
            .empty_message = "  No sessions found",
            .max_width = 70,
            .max_height = max_visible + 4,
        });
    }

    pub fn readFileContent(self: *Sessions, allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
        const max_bytes = 10 * 1024 * 1024;
        const dir_path = try sessionsDir(allocator);
        defer allocator.free(dir_path);
        const path = try std.fs.path.join(allocator, &.{ dir_path, filename });
        defer allocator.free(path);
        const f = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        const content = f.readToEndAlloc(allocator, max_bytes) catch |err| {
            f.close();
            return err;
        };
        f.seekFromEnd(0) catch |err| {
            f.close();
            allocator.free(content);
            return err;
        };
        if (self.file) |old| old.close();
        if (self.pending_path) |p| {
            allocator.free(p);
            self.pending_path = null;
        }
        self.file = f;
        return content;
    }

    pub fn appendFmt(self: *Sessions, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        if (self.file == null) {
            if (self.pending_path) |path| {
                self.file = std.fs.createFileAbsolute(path, .{}) catch return;
            } else return;
        }
        const f = self.file orelse return;
        const text = std.fmt.allocPrint(allocator, fmt, args) catch return;
        defer allocator.free(text);
        f.writeAll(text) catch {};
        f.writeAll("\n") catch {};
    }
};

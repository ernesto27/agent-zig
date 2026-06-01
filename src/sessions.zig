const std = @import("std");
const vaxis = @import("vaxis");
const modal_list = @import("modal_list.zig");
const config = @import("agent").config;

const log = std.log.scoped(.sessions);

const FileEntry = struct { filename: []const u8, preview: []const u8, date: []const u8 };

const YOU_PREFIX = "You: ";

fn stripYouPrefix(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, YOU_PREFIX)) text[YOU_PREFIX.len..] else text;
}

pub const Sessions = struct {
    pub const max_visible: usize = 12;
    file: ?std.fs.File = null,
    pending_path: ?[]const u8 = null,
    current_filename: ?[]const u8 = null,
    active: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    allocator: std.mem.Allocator = undefined,
    entries: std.ArrayListUnmanaged(FileEntry) = .{},
    rename_active: bool = false,
    rename_input: std.ArrayListUnmanaged(u8) = .{},
    config_ref: ?*config.Config = null,
    config_sessions: []const config.SessionEntry = &.{},

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

    pub fn openRename(self: *Sessions) void {
        self.rename_active = true;
        self.rename_input.clearRetainingCapacity();
    }

    pub fn resetRename(self: *Sessions) void {
        self.rename_active = false;
        self.rename_input.clearRetainingCapacity();
    }

    fn sessionsDir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "sessions" });
    }

    pub fn init(self: *Sessions, allocator: std.mem.Allocator, cfg: *config.Config) !void {
        self.config_ref = cfg;
        self.config_sessions = cfg.sessions;
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

        const FileInfo = struct { name: []const u8, display: ?[]const u8, mtime: i128 };
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
            const display = self.nameForFile(name_copy) orelse {
                allocator.free(name_copy);
                continue;
            };
            try file_list.append(allocator, .{ .name = name_copy, .display = display, .mtime = stat.mtime });
        }

        std.mem.sort(FileInfo, file_list.items, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                return a.mtime > b.mtime;
            }
        }.lessThan);

        for (file_list.items) |f| {
            const filename = try allocator.dupe(u8, f.name);
            const date = try relativeTime(allocator, f.mtime);
            const preview = if (f.display) |d|
                try allocator.dupe(u8, d)
            else
                readFirstLine(allocator, dir, f.name) catch try allocator.dupe(u8, f.name);
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
        if (self.current_filename) |name| {
            self.allocator.free(name);
            self.current_filename = null;
        }

        self.pending_path = try self.createPendingPath();
        self.appendFmt("{s}", .{text});
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

    fn nameForFile(self: *const Sessions, file: []const u8) ?[]const u8 {
        for (self.config_sessions) |s| {
            if (std.mem.eql(u8, s.file, file))
                return stripYouPrefix(s.name);
        }
        return null;
    }

    fn readFirstLine(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![]const u8 {
        var file = try dir.openFile(name, .{});
        defer file.close();
        var buf: [80]u8 = undefined;
        const n = try file.read(&buf);
        if (n == 0) return error.Empty;
        const line = std.mem.sliceTo(buf[0..n], '\n');
        if (line.len == 0) return error.Empty;
        const trimmed = stripYouPrefix(line);
        if (trimmed.len == 0) return error.Empty;
        return allocator.dupe(u8, trimmed);
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
        if (self.current_filename) |name| {
            self.allocator.free(name);
            self.current_filename = null;
        }
        if (self.entries.capacity > 0) {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.filename);
                self.allocator.free(entry.preview);
                self.allocator.free(entry.date);
            }
            self.entries.deinit(self.allocator);
        }
        self.rename_input.deinit(self.allocator);
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

    pub fn renderRename(self: *const Sessions, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const modal_w: u16 = @min(50, screen_w -| 4);
        const modal_h: u16 = 7;
        const modal_x: u16 = (screen_w -| modal_w) / 2;
        const modal_y: u16 = (screen_h -| modal_h) / 2;

        const modal = win.child(.{
            .x_off = modal_x,
            .y_off = modal_y,
            .width = modal_w,
            .height = modal_h,
            .border = .{ .where = .all, .glyphs = .single_rounded },
        });

        const modal_bg: vaxis.Color = .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };
        var fr: u16 = 0;
        while (fr < modal_h) : (fr += 1) {
            var fc: u16 = 0;
            while (fc < modal_w) : (fc += 1) {
                modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = modal_bg } });
            }
        }

        _ = modal.printSegment(.{
            .text = " Rename session",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });
        _ = modal.printSegment(.{
            .text = "esc ",
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = 0, .col_offset = modal_w -| 5 });

        const name_text = if (self.rename_input.items.len > 0)
            self.rename_input.items
        else
            "Enter new name...";
        const name_style: vaxis.Style = if (self.rename_input.items.len > 0)
            .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } }
        else
            .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } };

        _ = modal.printSegment(.{
            .text = name_text,
            .style = name_style,
        }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

        _ = modal.printSegment(.{
            .text = "Enter to save   esc to cancel",
            .style = .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } } },
        }, .{ .row_offset = 4, .col_offset = 2 });
    }

    pub fn readFileContent(self: *Sessions, filename: []const u8) ![]const u8 {
        const allocator = self.allocator;
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
            self.allocator.free(p);
            self.pending_path = null;
        }
        if (self.current_filename) |name| self.allocator.free(name);
        self.current_filename = try self.allocator.dupe(u8, filename);
        self.file = f;
        return content;
    }

    pub fn renameCurrent(self: *Sessions, new_name: []const u8) !void {
        const allocator = self.allocator;
        const filename = self.current_filename orelse return error.NoCurrentSession;
        const cfg = self.config_ref orelse return error.NoConfig;

        try config.renameSession(allocator, cfg, filename, new_name);
        self.config_sessions = cfg.sessions;

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.filename, filename)) {
                const preview = try allocator.dupe(u8, new_name);
                allocator.free(entry.preview);
                entry.preview = preview;
                break;
            }
        }
    }

    pub fn appendFmt(self: *Sessions, comptime fmt: []const u8, args: anytype) void {
        const allocator = self.allocator;
        const text = std.fmt.allocPrint(allocator, fmt, args) catch return;
        defer allocator.free(text);

        if (self.file == null) {
            if (self.pending_path) |path| {
                self.file = std.fs.createFileAbsolute(path, .{}) catch return;
                const filename = std.fs.path.basename(path);
                if (self.current_filename) |name| self.allocator.free(name);
                self.current_filename = self.allocator.dupe(u8, filename) catch null;
                if (self.config_ref) |cfg| {
                    const name = stripYouPrefix(text);
                    config.createSession(allocator, cfg, filename, name) catch |err| {
                        log.err("failed to create session config entry: {}", .{err});
                    };
                    self.config_sessions = cfg.sessions;
                }
            } else return;
        }
        const f = self.file orelse return;
        f.writeAll(text) catch {};
        f.writeAll("\n") catch {};
    }
};

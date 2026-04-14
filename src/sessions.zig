const std = @import("std");
const vaxis = @import("vaxis");

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

    pub fn init(self: *Sessions, allocator: std.mem.Allocator) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

        const dir_path = try std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "sessions" });
        defer allocator.free(dir_path);
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        self.allocator = allocator;
        self.loadEntries(allocator, dir_path) catch |err| {
            log.err("failed to load session entries: {}", .{err});
        };

        const filename = try Sessions.generateFilename(allocator);
        defer allocator.free(filename);

        const path = try std.fs.path.join(allocator, &.{ dir_path, filename });
        self.pending_path = path;
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
            const date = try parseDateFromFilename(allocator, f.name);
            const preview = readFirstLine(allocator, dir, f.name) catch try allocator.dupe(u8, f.name);
            try self.entries.append(allocator, .{ .filename = filename, .preview = preview, .date = date });
        }
    }

    fn parseDateFromFilename(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        // Format: DD-MM-YYYY-HH:MM:SS-hex.log → display as "DD-MM-YYYY HH:MM:SS"
        const without_ext = if (std.mem.endsWith(u8, name, ".log")) name[0 .. name.len - 4] else name;
        const last_dash = std.mem.lastIndexOfScalar(u8, without_ext, '-') orelse
            return allocator.dupe(u8, without_ext);
        const date_time = without_ext[0..last_dash];
        var buf = try allocator.dupe(u8, date_time);
        // Replace '-' between YYYY and HH (always at index 10 for DD-MM-YYYY)
        if (buf.len > 10 and buf[10] == '-') buf[10] = ' ';
        return buf;
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
        const visible: usize = @min(max_visible, self.entries.items.len);
        const n: u16 = @intCast(visible);
        const modal_w: u16 = @min(70, screen_w -| 4);
        const modal_h: u16 = if (self.entries.items.len == 0) 4 else n + 3;
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
            .text = " Resume session",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }, .bold = true },
        }, .{ .row_offset = 0, .col_offset = 1 });
        _ = modal.printSegment(.{
            .text = "esc ",
            .style = .{ .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } },
        }, .{ .row_offset = 0, .col_offset = modal_w -| 5 });

        if (self.entries.items.len == 0) {
            _ = modal.printSegment(.{
                .text = "  No sessions found",
                .style = .{ .fg = .{ .rgb = .{ 0x66, 0x66, 0x66 } }, .italic = true },
            }, .{ .row_offset = 1, .col_offset = 1 });
            return;
        }

        const slice = self.entries.items[self.scroll..@min(self.scroll + visible, self.entries.items.len)];
        for (slice, 0..) |entry, i| {
            const idx = self.scroll + i;
            const row: u16 = @intCast(i + 1);
            const is_sel = idx == self.selected;
            const bg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xC0, 0x70, 0x20 } } else .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };
            const fg: vaxis.Color = if (is_sel) .{ .rgb = .{ 0xFF, 0xFF, 0xFF } } else .{ .rgb = .{ 0xCC, 0xCC, 0xCC } };

            if (is_sel) {
                var c: u16 = 1;
                while (c < modal_w -| 1) : (c += 1) {
                    modal.writeCell(c, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
                }
            }

            const prefix: []const u8 = if (is_sel) " > " else "   ";
            const pre_res = modal.printSegment(.{
                .text = prefix,
                .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
            }, .{ .row_offset = row, .col_offset = 1 });
            const preview_res = modal.printSegment(.{
                .text = entry.preview,
                .style = .{ .fg = fg, .bg = bg, .bold = is_sel },
            }, .{ .row_offset = row, .col_offset = pre_res.col });
            _ = modal.printSegment(.{
                .text = entry.date,
                .style = .{ .fg = if (is_sel) .{ .rgb = .{ 0xFF, 0xCC, 0x88 } } else .{ .rgb = .{ 0x66, 0x66, 0x88 } }, .bg = bg },
            }, .{ .row_offset = row, .col_offset = preview_res.col + 1 });
        }
    }

    pub fn readFileContent(self: *Sessions, allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
        const max_bytes = 10 * 1024 * 1024;
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "sessions", filename });
        defer allocator.free(path);
        const f = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        const content = f.readToEndAlloc(allocator, max_bytes) catch |err| { f.close(); return err; };
        f.seekFromEnd(0) catch |err| { f.close(); allocator.free(content); return err; };
        if (self.file) |old| old.close();
        if (self.pending_path) |p| { allocator.free(p); self.pending_path = null; }
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

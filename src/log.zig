const std = @import("std");

pub const Logger = struct {
    var file: ?std.fs.File = null;
    var crash_log_path_buf: [512]u8 = undefined;
    var crash_log_path: []u8 = &.{};
    const filename = "agent.log";

    pub fn init(allocator: std.mem.Allocator) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", filename });
        defer allocator.free(path);

        const crash_path = try std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", "crash.log" });
        defer allocator.free(crash_path);
        if (crash_path.len > crash_log_path_buf.len) return error.NameTooLong;
        @memcpy(crash_log_path_buf[0..crash_path.len], crash_path);
        crash_log_path = crash_log_path_buf[0..crash_path.len];

        file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    }

    pub fn deinit() void {
        if (file) |f| {
            f.close();
            file = null;
        }
    }

    pub fn logToFile(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const f = file orelse return;
        const prefix = comptime "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ ") ";
        var buf: [1024 * 1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
        f.writeAll(msg) catch {};
    }

    pub fn writeCrashReport(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) void {
        if (crash_log_path.len == 0) return;

        const f = std.fs.createFileAbsolute(crash_log_path, .{ .truncate = false }) catch return;
        defer f.close();

        f.seekFromEnd(0) catch {};
        var write_buf: [4096]u8 = undefined;
        var w = f.writer(&write_buf);

        const ts = std.time.timestamp();
        w.interface.print("\n=== CRASH @ unix:{d} ===\n{s}\n", .{ ts, msg }) catch {};

        if (trace) |t| {
            const n = @min(t.index, t.instruction_addresses.len);
            w.interface.writeAll("Error return trace (raw addrs):\n") catch {};
            for (t.instruction_addresses[0..n]) |addr| {
                w.interface.print("  0x{x:0>16}\n", .{addr}) catch {};
            }
        }

        const debug_info = std.debug.getSelfDebugInfo() catch {
            w.interface.writeAll("(debug info unavailable for symbolication)\n") catch {};
            return;
        };
        const tty_cfg = std.io.tty.Config.no_color;
        if (trace) |t| {
            std.debug.writeStackTrace(t.*, &w.interface, debug_info, tty_cfg) catch {};
        }
        std.debug.writeCurrentStackTrace(&w.interface, debug_info, tty_cfg, ret_addr) catch {};
        w.interface.flush() catch {};
    }
};

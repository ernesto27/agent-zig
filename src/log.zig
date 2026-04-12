const std = @import("std");

pub const Logger = struct {
    var file: ?std.fs.File = null;
    const filename = "agent.log";

    pub fn init(allocator: std.mem.Allocator) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "agent-zig", filename });
        defer allocator.free(path);
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
};

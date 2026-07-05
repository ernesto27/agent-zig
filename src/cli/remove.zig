const std = @import("std");
const agent = @import("agent");

const binary = "agent-zig";

pub fn run(allocator: std.mem.Allocator) !void {
    const home = try agent.utils.homeDir(allocator);
    defer allocator.free(home);
    const path = try std.fs.path.join(allocator, &.{ home, ".local", "bin", binary });
    defer allocator.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("{s} is not installed at {s}\n", .{ binary, path });
            return;
        },
        else => return err,
    };

    std.debug.print("removed {s}\n", .{path});
}

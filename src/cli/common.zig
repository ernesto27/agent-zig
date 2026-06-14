const std = @import("std");
const update = @import("update.zig");
const remove = @import("remove.zig");

const Command = struct {
    name: []const u8,
    run: *const fn (std.mem.Allocator) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "update", .run = update.run },
    .{ .name = "remove", .run = remove.run },
};

pub fn dispatch(allocator: std.mem.Allocator, cmd: []const u8) bool {
    for (commands) |c| {
        if (!std.mem.eql(u8, cmd, c.name)) continue;
        c.run(allocator) catch |err| {
            std.debug.print("{s} failed: {s}\n", .{ c.name, @errorName(err) });
            std.process.exit(1);
        };
        return true;
    }
    return false;
}

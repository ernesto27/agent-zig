//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const llm = @import("llm.zig");
pub const build = @import("build_info.zig");
pub const config = @import("config.zig");
pub const json_helpers = @import("json_helpers.zig");
pub const markdown = @import("markdown.zig");
pub const tools = @import("tools.zig");
pub const sandbox = @import("sandbox.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const skills = @import("skills.zig");
pub const utils = @import("utils.zig");
pub const message_queue = @import("message_queue.zig");
pub const settings = @import("commands/settings.zig");
pub const modal_list = @import("modal_list.zig");
pub const mcp = struct {
    pub const protocol = @import("mcp/protocol.zig");
    pub const client = @import("mcp/client.zig");
    pub const registry = @import("mcp/registry.zig");
    pub const stdio_transport = @import("mcp/stdio_transport.zig");
    pub const http_transport = @import("mcp/http_transport.zig");
};

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

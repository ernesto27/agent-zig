const std = @import("std");
const message = @import("llm/message.zig");

const log = std.log.scoped(.tools);

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

const read_file_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "file_path": {
    \\      "type": "string",
    \\      "description": "Absolute path to the file to read"
    \\    }
    \\  },
    \\  "required": ["file_path"]
    \\}
;

pub fn getDefinitions(allocator: std.mem.Allocator) ![]const message.ToolDefinition {
    const schema_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        read_file_schema_json,
        .{},
    );

    const defs = try allocator.alloc(message.ToolDefinition, 1);
    defs[0] = .{
        .name = "read_file",
        .description = "Read the contents of a file at the given path. Returns the file content as text.",
        .input_schema = .{
            .type = "object",
            .properties = schema_parsed.value.object.get("properties") orelse .null,
            .required = &.{"file_path"},
        },
    };
    return defs;
}

pub fn execute(allocator: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) ToolResult {
    if (std.mem.eql(u8, tool_name, "read_file")) {
        return readFile(allocator, input);
    }
    return .{
        .content = "Unknown tool",
        .is_error = true,
    };
}

fn readFile(allocator: std.mem.Allocator, input: std.json.Value) ToolResult {
    const file_path = blk: {
        if (input != .object) break :blk null;
        const val = input.object.get("file_path") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk val.string;
    };

    if (file_path == null) {
        return .{
            .content = "Invalid input: expected { file_path: string }",
            .is_error = true,
        };
    }

    log.info("reading file: {s}", .{file_path.?});

    const max_size = 1 * 1024 * 1024;
    const contents = blk: {
        // Support both absolute and relative paths
        const file = (if (std.fs.path.isAbsolute(file_path.?))
            std.fs.openFileAbsolute(file_path.?, .{})
        else
            std.fs.cwd().openFile(file_path.?, .{})) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Error opening file: {}", .{err}) catch
                return .{ .content = "Error opening file", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        defer file.close();
        break :blk file.readToEndAlloc(allocator, max_size) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Error reading file: {}", .{err}) catch
                return .{ .content = "Error reading file", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    };

    log.info("read {d} bytes from {s}", .{ contents.len, file_path.? });
    return .{ .content = contents };
}

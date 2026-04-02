const std = @import("std");
const message = @import("llm/message.zig");

const log = std.log.scoped(.tools);

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub fn getStringField(input: std.json.Value, field: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const val = input.object.get(field) orelse return null;
    if (val != .string) return null;
    return val.string;
}

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

const write_file_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "file_path": {
    \\      "type": "string",
    \\      "description": "Absolute or relative path to the file to write"
    \\    },
    \\    "content": {
    \\      "type": "string",
    \\      "description": "The full content to write to the file"
    \\    }
    \\  },
    \\  "required": ["file_path", "content"]
    \\}
;

const edit_file_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "file_path": {
    \\      "type": "string",
    \\      "description": "Absolute or relative path to the file to edit"
    \\    },
    \\    "old_string": {
    \\      "type": "string",
    \\      "description": "The exact string to find and replace"
    \\    },
    \\    "new_string": {
    \\      "type": "string",
    \\      "description": "The string to replace old_string with"
    \\    }
    \\  },
    \\  "required": ["file_path", "old_string", "new_string"]
    \\}
;

const bash_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "The shell command to execute"
    \\    }
    \\  },
    \\  "required": ["command"]
    \\}
;

const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    required: []const []const u8,
};

const tool_specs = [_]ToolSpec{
    .{
        .name = "read_file",
        .description = "Read the contents of a file at the given path. Returns the file content as text.",
        .schema_json = read_file_schema_json,
        .required = &.{"file_path"},
    },
    .{
        .name = "write_file",
        .description = "Write content to a file at the given path. Creates the file if it doesn't exist, overwrites if it does.",
        .schema_json = write_file_schema_json,
        .required = &.{ "file_path", "content" },
    },
    .{
        .name = "edit_file",
        .description = "Edit a file by replacing an exact string with a new string. old_string must appear exactly once in the file.",
        .schema_json = edit_file_schema_json,
        .required = &.{ "file_path", "old_string", "new_string" },
    },
    .{
        .name = "bash",
        .description = "Run a shell command and return its output. Use for file system operations, running tests, compiling code, etc.",
        .schema_json = bash_schema_json,
        .required = &.{"command"},
    },
};

pub fn getDefinitions(allocator: std.mem.Allocator) ![]const message.ToolDefinition {
    const defs = try allocator.alloc(message.ToolDefinition, tool_specs.len);
    for (tool_specs, 0..) |spec, i| {
        const schema = try std.json.parseFromSlice(std.json.Value, allocator, spec.schema_json, .{});
        defs[i] = .{
            .name = spec.name,
            .description = spec.description,
            .input_schema = .{
                .type = "object",
                .properties = schema.value.object.get("properties") orelse .null,
                .required = spec.required,
            },
        };
    }

    return defs;
}

pub fn execute(allocator: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) ToolResult {
    if (std.mem.eql(u8, tool_name, "read_file")) {
        return readFile(allocator, input);
    }
    if (std.mem.eql(u8, tool_name, "write_file")) {
        return writeFile(allocator, input);
    }
    if (std.mem.eql(u8, tool_name, "edit_file")) {
        return editFile(allocator, input);
    }
    if (std.mem.eql(u8, tool_name, "bash")) {
        return runBash(allocator, input);
    }

    return .{
        .content = "Unknown tool",
        .is_error = true,
    };
}

fn readFile(allocator: std.mem.Allocator, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path");

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

fn writeFile(allocator: std.mem.Allocator, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path");
    const content = getStringField(input, "content");

    if (file_path == null or content == null) {
        return .{
            .content = "Invalid input: expected { file_path: string, content: string }",
            .is_error = true,
        };
    }

    log.info("writing file: {s}", .{file_path.?});

    const file = (if (std.fs.path.isAbsolute(file_path.?))
        std.fs.createFileAbsolute(file_path.?, .{})
    else
        std.fs.cwd().createFile(file_path.?, .{})) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error creating file: {}", .{err}) catch
            return .{ .content = "Error creating file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(content.?) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error writing file: {}", .{err}) catch
            return .{ .content = "Error writing file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    log.info("wrote {d} bytes to {s}", .{ content.?.len, file_path.? });

    const result = std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{
        content.?.len,
        file_path.?,
    }) catch return .{ .content = "File written", .is_error = false };

    return .{ .content = result };
}

fn editFile(allocator: std.mem.Allocator, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path");
    const old_string = getStringField(input, "old_string");
    const new_string = getStringField(input, "new_string");

    if (file_path == null or old_string == null or new_string == null) {
        return .{
            .content = "Invalid input: expected { file_path, old_string, new_string }",
            .is_error = true,
        };
    }

    log.info("editing file: {s}", .{file_path.?});

    const max_size = 1 * 1024 * 1024;
    const original = blk: {
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
    defer allocator.free(original);

    const idx = std.mem.indexOf(u8, original, old_string.?) orelse {
        const msg = std.fmt.allocPrint(allocator, "old_string not found in {s}", .{file_path.?}) catch
            return .{ .content = "old_string not found", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (std.mem.indexOf(u8, original[idx + old_string.?.len ..], old_string.?) != null) {
        return .{
            .content = "old_string appears more than once — be more specific",
            .is_error = true,
        };
    }

    const new_content = std.mem.concat(allocator, u8, &.{
        original[0..idx],
        new_string.?,
        original[idx + old_string.?.len ..],
    }) catch return .{ .content = "Out of memory", .is_error = true };
    defer allocator.free(new_content);

    const file = (if (std.fs.path.isAbsolute(file_path.?))
        std.fs.createFileAbsolute(file_path.?, .{})
    else
        std.fs.cwd().createFile(file_path.?, .{})) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error opening file for write: {}", .{err}) catch
            return .{ .content = "Error opening file for write", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error writing file: {}", .{err}) catch
            return .{ .content = "Error writing file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    log.info("edited {s}: replaced {d} bytes with {d} bytes", .{ file_path.?, old_string.?.len, new_string.?.len });

    const result = std.fmt.allocPrint(allocator, "Successfully edited {s}", .{file_path.?}) catch
        return .{ .content = "File edited", .is_error = false };
    return .{ .content = result };
}

fn runBash(allocator: std.mem.Allocator, input: std.json.Value) ToolResult {
    const command = getStringField(input, "command") orelse return .{ .content = "Invalid input: expected { command: string }", .is_error = true };
    log.info("running bash: {s}", .{command});

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-c", command },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run command: {}", .{err}) catch
            return .{ .content = "Failed to run command", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };

    const output = if (result.stderr.len == 0)
        allocator.dupe(u8, result.stdout) catch
            return .{ .content = "Out of memory", .is_error = true }
    else
        std.mem.concat(allocator, u8, &.{ result.stdout, "\n[stderr]\n", result.stderr }) catch
            return .{ .content = "Out of memory", .is_error = true };

    return .{ .content = output, .is_error = exit_code != 0 };
}

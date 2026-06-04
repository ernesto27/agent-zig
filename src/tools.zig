const std = @import("std");
const json_helpers = @import("json_helpers.zig");
const message = @import("llm/message.zig");
const skills = @import("skills.zig");
const web = @import("tools/web.zig");
const mcp_registry = @import("mcp/registry.zig");
const sandbox_mod = @import("sandbox.zig");

const log = std.log.scoped(.tools);

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub const Context = struct {
    skill_registry: ?*const skills.Registry = null,
    mcp_registry: ?*mcp_registry.McpRegistry = null,
    /// When set and active, the filesystem tools run inside the sandbox
    /// container (against the mounted worktree at /workspace) instead of the host.
    sandbox: ?*sandbox_mod.Sandbox = null,
};

pub fn getStringField(input: std.json.Value, field: []const u8) ?[]const u8 {
    return json_helpers.getStringField(input, field);
}

pub fn getField(input: std.json.Value, field: []const u8) ?std.json.Value {
    return json_helpers.getField(input, field);
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

const glob_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Glob pattern to match file paths, such as **/*.zig or src/*.zig"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File or directory path to search. Defaults to current directory."
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
;

const grep_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Literal text to search for"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File or directory path to search. Defaults to current directory."
    \\    },
    \\    "include": {
    \\      "type": "string",
    \\      "description": "Optional filename filter like *.zig, .zig, or tools.zig"
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
;

const web_search_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Web search query"
    \\    },
    \\    "max_results": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results to return"
    \\    },
    \\    "topic": {
    \\      "type": "string",
    \\      "description": "Search topic, such as general or news"
    \\    }
    \\  },
    \\  "required": ["query"]
    \\}
;

const web_extract_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "urls": {
    \\      "description": "Single URL or array of URLs to extract"
    \\    },
    \\    "format": {
    \\      "type": "string",
    \\      "description": "Output format, such as markdown or text"
    \\    },
    \\    "extract_depth": {
    \\      "type": "string",
    \\      "description": "Extraction depth, basic or advanced"
    \\    }
    \\  },
    \\  "required": ["urls"]
    \\}
;

const skill_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": {
    \\      "type": "string",
    \\      "description": "Name of the skill to load"
    \\    }
    \\  },
    \\  "required": ["name"]
    \\}
;

const skill_resource_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "skill": {
    \\      "type": "string",
    \\      "description": "Name of the skill that owns the resource"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Relative path to a supporting file inside the skill directory"
    \\    }
    \\  },
    \\  "required": ["skill", "path"]
    \\}
;

const skill_script_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "skill": {
    \\      "type": "string",
    \\      "description": "Name of the skill that owns the script"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Relative path to a script inside the skill's scripts/ directory"
    \\    }
    \\  },
    \\  "required": ["skill", "path"]
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
    .{
        .name = "glob",
        .description = "Find files by glob pattern. Returns matching file paths, one per line.",
        .schema_json = glob_schema_json,
        .required = &.{"pattern"},
    },
    .{
        .name = "grep",
        .description = "Search file contents for a literal text pattern. Returns matching file paths, line numbers, and lines.",
        .schema_json = grep_schema_json,
        .required = &.{"pattern"},
    },
    .{
        .name = "web_search",
        .description = "Search the web and return relevant results with title, URL, and extracted snippets.",
        .schema_json = web_search_schema_json,
        .required = &.{"query"},
    },
    .{
        .name = "web_extract",
        .description = "Extract page content from one or more URLs and return the cleaned content.",
        .schema_json = web_extract_schema_json,
        .required = &.{"urls"},
    },
    .{
        .name = "skill",
        .description = "Load a reusable skill by name. Use this when a skill description matches the user's request. The result is the full SKILL.md instructions for that skill, which may reference bundled scripts or other supporting files.",
        .schema_json = skill_schema_json,
        .required = &.{"name"},
    },
    .{
        .name = "skill_resource",
        .description = "Read a non-script supporting file from a previously loaded skill directory. Use this only for files referenced by the skill instructions.",
        .schema_json = skill_resource_schema_json,
        .required = &.{ "skill", "path" },
    },
    .{
        .name = "skill_script",
        .description = "Resolve the full filesystem path to a bundled skill script under scripts/. Use this before running a script referenced by a skill.",
        .schema_json = skill_script_schema_json,
        .required = &.{ "skill", "path" },
    },
};

pub fn getDefinitions(allocator: std.mem.Allocator, ctx: Context) ![]const message.ToolDefinition {
    var builtins: std.ArrayList(message.ToolDefinition) = .{};
    try builtins.ensureTotalCapacity(allocator, tool_specs.len);
    for (tool_specs) |spec| {
        const schema = try std.json.parseFromSlice(std.json.Value, allocator, spec.schema_json, .{});
        const description = if (std.mem.eql(u8, spec.name, "skill") and ctx.skill_registry != null) blk: {
            const available = try ctx.skill_registry.?.buildAvailableSkillsMarkdown(allocator);
            break :blk try std.mem.concat(allocator, u8, &.{ spec.description, "\n\n", available });
        } else spec.description;
        try builtins.append(allocator, .{
            .name = spec.name,
            .description = description,
            .input_schema = .{
                .type = "object",
                .properties = schema.value.object.get("properties") orelse .null,
                .required = spec.required,
            },
        });
    }

    if (ctx.mcp_registry) |reg| {
        const mcp_defs = reg.collectTools(allocator) catch |err| blk: {
            log.warn("collectTools failed: {}", .{err});
            break :blk &[_]message.ToolDefinition{};
        };
        for (mcp_defs) |d| try builtins.append(allocator, d);
    }

    return builtins.toOwnedSlice(allocator);
}

pub fn execute(allocator: std.mem.Allocator, ctx: Context, tool_name: []const u8, input: std.json.Value) ToolResult {
    // MCP tools are prefixed `mcp__<server>__<tool>`. routeCall returns null
    // for non-MCP names so the built-in dispatch below runs unchanged.
    if (ctx.mcp_registry) |reg| {
        if (reg.routeCall(allocator, tool_name, input)) |r| {
            return .{ .content = r.content, .is_error = r.is_error };
        }
    }

    // Filesystem tools are written once against `Exec`; pick the backend. When a
    // sandbox is active they run in the container, otherwise natively on the host.
    const exec: Exec = if (ctx.sandbox) |sb|
        (if (sb.active) Exec{ .sandbox = sb } else .host)
    else
        .host;

    if (std.mem.eql(u8, tool_name, "read_file")) return readTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "write_file")) return writeTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "edit_file")) return editTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "bash")) return bashTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "glob")) return globTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "grep")) return grepTool(allocator, exec, input);
    if (std.mem.eql(u8, tool_name, "web_search")) {
        const result = web.search(allocator, input);
        return .{ .content = result.content, .is_error = result.is_error };
    }
    if (std.mem.eql(u8, tool_name, "web_extract")) {
        const result = web.extract(allocator, input);
        return .{ .content = result.content, .is_error = result.is_error };
    }
    if (std.mem.eql(u8, tool_name, "skill")) {
        return loadSkill(allocator, ctx, input);
    }
    if (std.mem.eql(u8, tool_name, "skill_resource")) {
        return loadSkillResource(allocator, ctx, input);
    }
    if (std.mem.eql(u8, tool_name, "skill_script")) {
        return resolveSkillScript(allocator, ctx, input);
    }

    return .{
        .content = "Unknown tool",
        .is_error = true,
    };
}

pub fn runBashCommand(allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    var tool_input: std.json.Value = .{ .object = std.json.ObjectMap.init(allocator) };
    defer tool_input.object.deinit();

    try tool_input.object.put("command", .{ .string = command });

    return execute(allocator, .{}, "bash", tool_input);
}

/// Where a filesystem tool runs: natively on the host (portable std.fs /
/// std.process) or inside the sandbox container (shell via `docker exec`). Each
/// tool below is written once against this; only the per-backend primitives differ.
const Exec = union(enum) {
    host,
    sandbox: *sandbox_mod.Sandbox,

    fn shell(self: Exec, allocator: std.mem.Allocator, command: []const u8) ToolResult {
        return switch (self) {
            .host => hostShell(allocator, command),
            .sandbox => |sb| fromResult(sb.execShell(allocator, command)),
        };
    }

    fn readFile(self: Exec, allocator: std.mem.Allocator, path: []const u8) ToolResult {
        return switch (self) {
            .host => hostReadFile(allocator, path),
            .sandbox => |sb| fromResult(sb.runArgv(allocator, &.{ "cat", "--", sb.rel(path) })),
        };
    }

    fn writeFile(self: Exec, allocator: std.mem.Allocator, path: []const u8, content: []const u8) ToolResult {
        return switch (self) {
            .host => hostWriteFile(allocator, path, content),
            .sandbox => |sb| fromResult(sb.writeFile(allocator, sb.rel(path), content)),
        };
    }

    fn glob(self: Exec, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8) ToolResult {
        return switch (self) {
            .host => hostGlob(allocator, pattern, path),
            .sandbox => |sb| sbxGlob(allocator, sb, pattern, path),
        };
    }

    fn grep(self: Exec, allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, include: ?[]const u8) ToolResult {
        return switch (self) {
            .host => hostGrep(allocator, pattern, path, include),
            .sandbox => |sb| sbxGrep(allocator, sb, pattern, path, include),
        };
    }
};

fn fromResult(r: sandbox_mod.Result) ToolResult {
    return .{ .content = r.content, .is_error = r.is_error };
}

// ---- Filesystem tools (backend-agnostic) --------------------------------
// Each parses its input, then delegates to the active `Exec` backend.

fn bashTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const command = getStringField(input, "command") orelse
        return .{ .content = "Invalid input: expected { command: string }", .is_error = true };
    log.info("running bash: {s}", .{command});
    return exec.shell(allocator, command);
}

fn readTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path") orelse
        return .{ .content = "Invalid input: expected { file_path: string }", .is_error = true };
    return exec.readFile(allocator, file_path);
}

fn writeTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path");
    const content = getStringField(input, "content");
    if (file_path == null or content == null) {
        return .{ .content = "Invalid input: expected { file_path: string, content: string }", .is_error = true };
    }
    return exec.writeFile(allocator, file_path.?, content.?);
}

/// One implementation for both backends: read via the backend, do the
/// find/replace here, write back via the backend.
fn editTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const file_path = getStringField(input, "file_path");
    const old_string = getStringField(input, "old_string");
    const new_string = getStringField(input, "new_string");
    if (file_path == null or old_string == null or new_string == null) {
        return .{ .content = "Invalid input: expected { file_path, old_string, new_string }", .is_error = true };
    }

    const read = exec.readFile(allocator, file_path.?);
    if (read.is_error) return read; // transfer ownership of the error message
    defer allocator.free(read.content);
    const original = read.content;

    const idx = std.mem.indexOf(u8, original, old_string.?) orelse {
        const msg = std.fmt.allocPrint(allocator, "old_string not found in {s}", .{file_path.?}) catch
            return .{ .content = "old_string not found", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    if (std.mem.indexOf(u8, original[idx + old_string.?.len ..], old_string.?) != null) {
        return .{ .content = "old_string appears more than once — be more specific", .is_error = true };
    }

    const new_content = std.mem.concat(allocator, u8, &.{
        original[0..idx],
        new_string.?,
        original[idx + old_string.?.len ..],
    }) catch return .{ .content = "Out of memory", .is_error = true };
    defer allocator.free(new_content);

    const w = exec.writeFile(allocator, file_path.?, new_content);
    if (w.is_error) return w;
    allocator.free(w.content);
    const result = std.fmt.allocPrint(allocator, "Successfully edited {s}", .{file_path.?}) catch
        return .{ .content = "File edited" };
    return .{ .content = result };
}

fn globTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const pattern = getStringField(input, "pattern") orelse
        return .{ .content = "Invalid input: expected { pattern: string, path?: string }", .is_error = true };
    if (pattern.len == 0) return .{ .content = "Pattern must not be empty", .is_error = true };
    const path = getStringField(input, "path") orelse ".";
    return exec.glob(allocator, pattern, path);
}

fn grepTool(allocator: std.mem.Allocator, exec: Exec, input: std.json.Value) ToolResult {
    const pattern = getStringField(input, "pattern") orelse
        return .{ .content = "Invalid input: expected { pattern: string, path?: string, include?: string }", .is_error = true };
    if (pattern.len == 0) return .{ .content = "Pattern must not be empty", .is_error = true };
    const path = getStringField(input, "path") orelse ".";
    const include = getStringField(input, "include");
    return exec.grep(allocator, pattern, path, include);
}

fn loadSkill(allocator: std.mem.Allocator, ctx: Context, input: std.json.Value) ToolResult {
    const registry = ctx.skill_registry orelse return .{ .content = "Skills are not available", .is_error = true };
    const name = getStringField(input, "name") orelse return .{ .content = "Invalid input: expected { name: string }", .is_error = true };

    const content = registry.readSkill(allocator, name) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error loading skill '{s}': {}", .{ name, err }) catch
            return .{ .content = "Error loading skill", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    return .{ .content = content };
}

fn loadSkillResource(allocator: std.mem.Allocator, ctx: Context, input: std.json.Value) ToolResult {
    const registry = ctx.skill_registry orelse return .{ .content = "Skills are not available", .is_error = true };
    const name = getStringField(input, "skill") orelse return .{ .content = "Invalid input: expected { skill: string, path: string }", .is_error = true };
    const path = getStringField(input, "path") orelse return .{ .content = "Invalid input: expected { skill: string, path: string }", .is_error = true };

    const content = registry.readResource(allocator, name, path) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error loading skill resource '{s}/{s}': {}", .{ name, path, err }) catch
            return .{ .content = "Error loading skill resource", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    return .{ .content = content };
}

fn resolveSkillScript(allocator: std.mem.Allocator, ctx: Context, input: std.json.Value) ToolResult {
    const registry = ctx.skill_registry orelse return .{ .content = "Skills are not available", .is_error = true };
    const name = getStringField(input, "skill") orelse return .{ .content = "Invalid input: expected { skill: string, path: string }", .is_error = true };
    const path = getStringField(input, "path") orelse return .{ .content = "Invalid input: expected { skill: string, path: string }", .is_error = true };

    const resolved = registry.resolveScriptPath(allocator, name, path) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error resolving skill script '{s}/{s}': {}", .{ name, path, err }) catch
            return .{ .content = "Error resolving skill script", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    return .{ .content = resolved };
}

fn hostReadFile(allocator: std.mem.Allocator, file_path: []const u8) ToolResult {
    log.info("reading file: {s}", .{file_path});

    const max_size = 1 * 1024 * 1024;
    const contents = blk: {
        // Support both absolute and relative paths
        const file = (if (std.fs.path.isAbsolute(file_path))
            std.fs.openFileAbsolute(file_path, .{})
        else
            std.fs.cwd().openFile(file_path, .{})) catch |err| {
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

    log.info("read {d} bytes from {s}", .{ contents.len, file_path });
    return .{ .content = contents };
}

fn hostWriteFile(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ToolResult {
    log.info("writing file: {s}", .{file_path});

    const file = (if (std.fs.path.isAbsolute(file_path))
        std.fs.createFileAbsolute(file_path, .{})
    else
        std.fs.cwd().createFile(file_path, .{})) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error creating file: {}", .{err}) catch
            return .{ .content = "Error creating file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error writing file: {}", .{err}) catch
            return .{ .content = "Error writing file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    log.info("wrote {d} bytes to {s}", .{ content.len, file_path });

    const result = std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{
        content.len,
        file_path,
    }) catch return .{ .content = "File written", .is_error = false };

    return .{ .content = result };
}

fn hostShell(allocator: std.mem.Allocator, command: []const u8) ToolResult {
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

// ---- Sandbox (Docker) primitives ----------------------------------------
// Container backends for glob/grep (shell `find`/`grep` via docker exec). bash,
// read, write and edit reuse Sandbox.execShell/runArgv/writeFile directly from
// the `Exec.sandbox` arm above. Returned content is owned by `allocator`.

fn sbxGlob(allocator: std.mem.Allocator, sb: *sandbox_mod.Sandbox, pattern_raw: []const u8, path_raw: []const u8) ToolResult {
    // `find -name` matches a basename at any depth; drop a leading "**/".
    const pattern = if (std.mem.startsWith(u8, pattern_raw, "**/")) pattern_raw[3..] else pattern_raw;
    const path = sb.rel(path_raw);

    const r = sb.runArgv(allocator, &.{ "find", path, "-type", "f", "-name", pattern });
    if (!r.is_error and r.content.len == 0) {
        allocator.free(r.content);
        return .{ .content = allocator.dupe(u8, "No matches found") catch "No matches found" };
    }
    return .{ .content = r.content, .is_error = r.is_error };
}

fn sbxGrep(allocator: std.mem.Allocator, sb: *sandbox_mod.Sandbox, pattern: []const u8, path_raw: []const u8, include: ?[]const u8) ToolResult {
    const path = sb.rel(path_raw);

    const r = if (include) |inc| blk: {
        const inc_arg = std.fmt.allocPrint(allocator, "--include={s}", .{inc}) catch
            return .{ .content = "Out of memory", .is_error = true };
        defer allocator.free(inc_arg);
        break :blk sb.runArgv(allocator, &.{ "grep", "-rn", inc_arg, "--", pattern, path });
    } else sb.runArgv(allocator, &.{ "grep", "-rn", "--", pattern, path });

    // grep exits 1 with no output when there are no matches — not an error.
    if (r.content.len == 0) {
        allocator.free(r.content);
        return .{ .content = allocator.dupe(u8, "No matches found") catch "No matches found" };
    }
    return .{ .content = r.content, .is_error = r.is_error };
}

fn hostGlob(allocator: std.mem.Allocator, pattern: []const u8, search_path: []const u8) ToolResult {
    log.info("running glob: pattern='{s}' path='{s}'", .{ pattern, search_path });

    var matches = std.ArrayList([]u8){};
    defer {
        for (matches.items) |item| allocator.free(item);
        matches.deinit(allocator);
    }

    const abs_path = std.fs.path.isAbsolute(search_path);
    const dir_result = if (abs_path)
        std.fs.openDirAbsolute(search_path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(search_path, .{ .iterate = true });

    if (dir_result) |dir| {
        var search_dir = dir;
        defer search_dir.close();

        collectGlobMatches(allocator, search_dir, search_path, abs_path, pattern, &matches) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Search failed: {}", .{err}) catch
                return .{ .content = "Search failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    } else |_| {
        const basename = std.fs.path.basename(search_path);
        if (!globMatchesPath(pattern, basename) and !globMatchesPath(pattern, search_path)) {
            const empty = allocator.dupe(u8, "No matches found") catch return .{ .content = "No matches found" };
            return .{ .content = empty };
        }

        const owned_path = allocator.dupe(u8, search_path) catch return .{ .content = "Out of memory", .is_error = true };
        matches.append(allocator, owned_path) catch {
            allocator.free(owned_path);
            return .{ .content = "Out of memory", .is_error = true };
        };
    }

    if (matches.items.len == 0) {
        const empty = allocator.dupe(u8, "No matches found") catch return .{ .content = "No matches found" };
        return .{ .content = empty };
    }

    std.mem.sort([]u8, matches.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (matches.items) |item| {
        out.appendSlice(allocator, item) catch return .{ .content = "Out of memory", .is_error = true };
        out.append(allocator, '\n') catch return .{ .content = "Out of memory", .is_error = true };
    }

    const owned = out.toOwnedSlice(allocator) catch return .{ .content = "Out of memory", .is_error = true };
    return .{ .content = owned };
}

fn hostGrep(allocator: std.mem.Allocator, pattern: []const u8, search_path: []const u8, include: ?[]const u8) ToolResult {
    log.info("running grep: pattern='{s}' path='{s}'", .{ pattern, search_path });

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    const abs_path = std.fs.path.isAbsolute(search_path);
    const dir_result = if (abs_path)
        std.fs.openDirAbsolute(search_path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(search_path, .{ .iterate = true });

    if (dir_result) |dir| {
        var search_dir = dir;
        defer search_dir.close();

        const display_prefix = if (std.mem.eql(u8, search_path, ".")) "" else search_path;
        walkAndSearch(allocator, search_dir, display_prefix, pattern, include, &out) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Search failed: {}", .{err}) catch
                return .{ .content = "Search failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    } else |_| {
        searchSingleFilePath(allocator, &out, search_path, search_path, pattern, include) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Search failed: {}", .{err}) catch
                return .{ .content = "Search failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    }

    if (out.items.len == 0) {
        const empty = allocator.dupe(u8, "No matches found") catch return .{ .content = "No matches found" };
        return .{ .content = empty };
    }

    const owned = out.toOwnedSlice(allocator) catch return .{ .content = "Out of memory", .is_error = true };
    return .{ .content = owned };
}

fn collectGlobMatches(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    search_path: []const u8,
    abs_path: bool,
    pattern: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!globMatchesPath(pattern, entry.path)) continue;

        const display_path = if (std.mem.eql(u8, search_path, "."))
            try allocator.dupe(u8, entry.path)
        else if (abs_path)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ search_path, entry.path })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ search_path, entry.path });
        errdefer allocator.free(display_path);

        try out.append(allocator, display_path);
    }
}

fn globMatchesPath(pattern: []const u8, path: []const u8) bool {
    return matchPathParts(trimSlashes(pattern), trimSlashes(path));
}

fn matchPathParts(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    const pattern_part = splitFirstPathPart(pattern) orelse return path.len == 0;
    if (std.mem.eql(u8, pattern_part.part, "**")) {
        if (matchPathParts(pattern_part.rest, path)) return true;
        const path_part = splitFirstPathPart(path) orelse return false;
        return matchPathParts(pattern, path_part.rest);
    }

    const path_part = splitFirstPathPart(path) orelse return false;
    if (!matchSegment(pattern_part.part, path_part.part)) return false;
    return matchPathParts(pattern_part.rest, path_part.rest);
}

fn matchSegment(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= value.len) : (i += 1) {
            if (matchSegment(pattern[1..], value[i..])) return true;
        }
        return false;
    }
    if (value.len == 0 or pattern[0] != value[0]) return false;
    return matchSegment(pattern[1..], value[1..]);
}

const PathPart = struct {
    part: []const u8,
    rest: []const u8,
};

fn splitFirstPathPart(path: []const u8) ?PathPart {
    const trimmed = trimLeadingSlashes(path);
    if (trimmed.len == 0) return null;

    const idx = std.mem.indexOfScalar(u8, trimmed, '/') orelse {
        return .{ .part = trimmed, .rest = "" };
    };

    return .{
        .part = trimmed[0..idx],
        .rest = trimmed[idx + 1 ..],
    };
}

fn trimSlashes(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

fn trimLeadingSlashes(path: []const u8) []const u8 {
    return std.mem.trimLeft(u8, path, "/");
}

fn walkAndSearch(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    display_prefix: []const u8,
    pattern: []const u8,
    include: ?[]const u8,
    out: *std.ArrayList(u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const display_path = if (display_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ display_prefix, entry.name });
        defer allocator.free(display_path);

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                try walkAndSearch(allocator, sub, display_path, pattern, include, out);
            },
            .file => try searchSingleFileInDir(allocator, out, dir, entry.name, display_path, pattern, include),
            else => {},
        }
    }
}

fn searchSingleFilePath(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    open_path: []const u8,
    display_path: []const u8,
    pattern: []const u8,
    include: ?[]const u8,
) !void {
    if (!matchesInclude(display_path, include)) return;

    const file = (if (std.fs.path.isAbsolute(open_path))
        std.fs.openFileAbsolute(open_path, .{})
    else
        std.fs.cwd().openFile(open_path, .{})) catch |err| switch (err) {
        error.IsDir => return,
        else => return err,
    };
    defer file.close();

    try appendFileMatches(allocator, out, file, display_path, pattern);
}

fn searchSingleFileInDir(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    dir: std.fs.Dir,
    entry_name: []const u8,
    display_path: []const u8,
    pattern: []const u8,
    include: ?[]const u8,
) !void {
    if (!matchesInclude(display_path, include)) return;

    const file = dir.openFile(entry_name, .{}) catch |err| switch (err) {
        error.IsDir => return,
        else => return err,
    };
    defer file.close();

    try appendFileMatches(allocator, out, file, display_path, pattern);
}

fn appendFileMatches(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    file: std.fs.File,
    display_path: []const u8,
    pattern: []const u8,
) !void {
    const max_size = 1 * 1024 * 1024;
    const contents = file.readToEndAlloc(allocator, max_size) catch |err| switch (err) {
        error.FileTooBig => return,
        else => return err,
    };
    defer allocator.free(contents);

    if (isProbablyBinary(contents)) return;

    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 1;
    while (line_iter.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.indexOf(u8, trimmed, pattern) == null) continue;

        const match_line = try std.fmt.allocPrint(allocator, "{s}:{d}: {s}\n", .{ display_path, line_number, trimmed });
        defer allocator.free(match_line);
        try out.appendSlice(allocator, match_line);
    }
}

fn matchesInclude(path: []const u8, include: ?[]const u8) bool {
    const rule = include orelse return true;

    if (std.mem.startsWith(u8, rule, "*.")) {
        return std.mem.endsWith(u8, path, rule[1..]);
    }
    if (rule.len > 0 and rule[0] == '.') {
        return std.mem.endsWith(u8, path, rule);
    }
    return std.mem.eql(u8, std.fs.path.basename(path), rule);
}

fn isProbablyBinary(contents: []const u8) bool {
    const sample_len = @min(contents.len, 512);
    for (contents[0..sample_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

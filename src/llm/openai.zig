const std = @import("std");
const json_helpers = @import("../json_helpers.zig");
const message = @import("message.zig");

const appendJsonString = json_helpers.appendJsonString;
const appendObjectFieldName = json_helpers.appendObjectFieldName;

/// Serialize messages and tools to an OpenAI Chat Completions request JSON body.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const message.Message,
    tools: []const message.ToolDefinition,
    system_prompt: ?[]const u8,
    stream: bool,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, &out, "model");
    try appendJsonString(allocator, &out, model);
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "stream");
    try out.appendSlice(allocator, if (stream) "true" else "false");
    if (stream) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "stream_options");
        try out.appendSlice(allocator, "{\"include_usage\":true}");
    }

    if (tools.len > 0) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "tools");
        try out.append(allocator, '[');
        for (tools, 0..) |tool, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, &out, "type");
            try appendJsonString(allocator, &out, "function");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "function");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, &out, "name");
            try appendJsonString(allocator, &out, tool.name);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "description");
            try appendJsonString(allocator, &out, tool.description);
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, &out, "parameters");
            const schema_json = try std.json.Stringify.valueAlloc(allocator, tool.input_schema, .{});
            defer allocator.free(schema_json);
            try out.appendSlice(allocator, schema_json);
            try out.appendSlice(allocator, "}}");
        }
        try out.append(allocator, ']');
    }

    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, &out, "messages");
    try out.append(allocator, '[');

    var first_msg = true;
    if (system_prompt) |sp| {
        try appendChatMessagePrefix(allocator, &out, &first_msg, "system");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, &out, "content");
        try appendJsonString(allocator, &out, sp);
        try out.append(allocator, '}');
    }

    for (messages) |msg| {
        switch (msg.content) {
            .text => |text| {
                try appendChatMessagePrefix(allocator, &out, &first_msg, @tagName(msg.role));
                try out.append(allocator, ',');
                try appendObjectFieldName(allocator, &out, "content");
                try appendJsonString(allocator, &out, text);
                try out.append(allocator, '}');
            },
            .content_blocks => |blocks| {
                if (msg.role == .user) {
                    try appendUserContentBlocks(allocator, &out, &first_msg, blocks);
                } else {
                    try appendAssistantContentBlocks(allocator, &out, &first_msg, blocks);
                }
            },
            .tool_result_blocks => |blocks| {
                try appendToolResultBlocks(allocator, &out, &first_msg, blocks);
            },
        }
    }

    try out.append(allocator, ']');
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn appendUserContentBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendChatMessagePrefix(allocator, out, first_msg, "user");
    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, out, "content");
    try out.append(allocator, '[');

    var first_part = true;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "text");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "text");
            try appendJsonString(allocator, out, blk.text orelse "");
            try out.append(allocator, '}');
        } else if (std.mem.eql(u8, blk.type, "image")) {
            const src = blk.source orelse continue;
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "image_url");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "image_url");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "url");
            const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ src.media_type, src.data });
            defer allocator.free(url);
            try appendJsonString(allocator, out, url);
            try out.appendSlice(allocator, "}}");
        }
    }

    try out.append(allocator, ']');
    try out.append(allocator, '}');
}

fn appendAssistantContentBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ContentBlock,
) !void {
    try appendChatMessagePrefix(allocator, out, first_msg, "assistant");

    var text_content: ?[]const u8 = null;
    var tool_use_count: usize = 0;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.type, "text")) text_content = blk.text;
        if (std.mem.eql(u8, blk.type, "tool_use")) tool_use_count += 1;
    }

    try out.append(allocator, ',');
    try appendObjectFieldName(allocator, out, "content");
    try appendJsonString(allocator, out, text_content orelse "");

    if (tool_use_count > 0) {
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "tool_calls");
        try out.append(allocator, '[');
        var first_tc = true;
        for (blocks) |blk| {
            if (!std.mem.eql(u8, blk.type, "tool_use")) continue;
            if (!first_tc) try out.append(allocator, ',');
            first_tc = false;
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "id");
            try appendJsonString(allocator, out, blk.id orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "type");
            try appendJsonString(allocator, out, "function");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "function");
            try out.appendSlice(allocator, "{");
            try appendObjectFieldName(allocator, out, "name");
            try appendJsonString(allocator, out, blk.name orelse "");
            try out.append(allocator, ',');
            try appendObjectFieldName(allocator, out, "arguments");
            const args_json = try std.json.Stringify.valueAlloc(allocator, blk.input, .{});
            defer allocator.free(args_json);
            try appendJsonString(allocator, out, args_json);
            try out.appendSlice(allocator, "}}");
        }
        try out.append(allocator, ']');
    }

    try out.append(allocator, '}');
}

fn appendToolResultBlocks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    blocks: []const message.ToolResultBlock,
) !void {
    for (blocks) |blk| {
        try appendChatMessagePrefix(allocator, out, first_msg, "tool");
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "tool_call_id");
        try appendJsonString(allocator, out, blk.tool_use_id);
        try out.append(allocator, ',');
        try appendObjectFieldName(allocator, out, "content");
        try appendJsonString(allocator, out, blk.content);
        try out.append(allocator, '}');
    }
}

fn appendChatMessagePrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first_msg: *bool,
    role: []const u8,
) !void {
    if (!first_msg.*) try out.append(allocator, ',');
    first_msg.* = false;
    try out.appendSlice(allocator, "{");
    try appendObjectFieldName(allocator, out, "role");
    try appendJsonString(allocator, out, role);
}

const std = @import("std");

pub fn getField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

pub fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    const child = getField(value, field) orelse return null;
    if (child != .object) return null;
    return child;
}

pub fn getStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    const child = getField(value, field) orelse return null;
    if (child != .string) return null;
    return child.string;
}

pub fn getIntegerField(value: std.json.Value, field: []const u8) ?usize {
    const child = getField(value, field) orelse return null;
    return switch (child) {
        .integer => |num| if (num >= 0) @intCast(num) else null,
        .float => |num| if (num >= 0) @intFromFloat(num) else null,
        .number_string => |num| std.fmt.parseUnsigned(usize, num, 10) catch null,
        else => null,
    };
}

pub fn getU64Field(value: std.json.Value, field: []const u8) ?u64 {
    const child = getField(value, field) orelse return null;
    return switch (child) {
        .integer => |num| if (num >= 0) @intCast(num) else null,
        .float => |num| if (num >= 0) @intFromFloat(num) else null,
        .number_string => |num| std.fmt.parseUnsigned(u64, num, 10) catch null,
        else => null,
    };
}

pub fn appendObjectFieldName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
}

pub fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hexDigit(ch >> 4));
                    try out.append(allocator, hexDigit(ch & 0x0F));
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

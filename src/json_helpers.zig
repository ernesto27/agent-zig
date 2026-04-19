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

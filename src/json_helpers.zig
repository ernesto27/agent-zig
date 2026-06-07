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

// === Tests ===

const testing = std.testing;

fn parseValue(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "getStringField returns string, null on wrong type or missing" {
    const alloc = testing.allocator;
    const parsed = try parseValue(alloc,
        \\{"name":"hello","count":7}
    );
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqualStrings("hello", getStringField(root, "name").?);
    try testing.expect(getStringField(root, "count") == null); // not a string
    try testing.expect(getStringField(root, "missing") == null); // absent
}

test "getField returns null for non-object input" {
    const alloc = testing.allocator;
    const parsed = try parseValue(alloc,
        \\[1,2,3]
    );
    defer parsed.deinit();
    try testing.expect(getField(parsed.value, "anything") == null);
}

test "getIntegerField parses integer, float, number_string; rejects negatives and quoted strings" {
    const alloc = testing.allocator;
    // "big" exceeds i64, so std.json represents it as a number_string.
    const parsed = try parseValue(alloc,
        \\{"i":42,"f":3.0,"big":10000000000000000000,"neg":-5,"str":"100"}
    );
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(usize, 42), getIntegerField(root, "i").?);
    try testing.expectEqual(@as(usize, 3), getIntegerField(root, "f").?);
    try testing.expectEqual(@as(usize, 10000000000000000000), getIntegerField(root, "big").?);
    try testing.expect(getIntegerField(root, "neg") == null); // negative rejected
    try testing.expect(getIntegerField(root, "str") == null); // quoted string is not a number
    try testing.expect(getIntegerField(root, "missing") == null);
}

test "getU64Field parses values and rejects negatives" {
    const alloc = testing.allocator;
    const parsed = try parseValue(alloc,
        \\{"big":9000000000,"neg":-1,"str":"42"}
    );
    defer parsed.deinit();
    const root = parsed.value;

    try testing.expectEqual(@as(u64, 9000000000), getU64Field(root, "big").?);
    try testing.expect(getU64Field(root, "neg") == null);
    try testing.expect(getU64Field(root, "str") == null); // quoted string is not a number
}

test "appendJsonString wraps plain text in quotes" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendJsonString(alloc, &out, "hello");
    try testing.expectEqualStrings("\"hello\"", out.items);
}

test "appendJsonString escapes quotes, backslash and control chars" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendJsonString(alloc, &out, "a\"b\\c\n\r\t");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\"", out.items);
}

test "appendJsonString emits \\u00XX for low control chars" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendJsonString(alloc, &out, &.{0x01});
    try testing.expectEqualStrings("\"\\u0001\"", out.items);
}

test "hexDigit covers numeric and alpha nibbles" {
    try testing.expectEqual(@as(u8, '0'), hexDigit(0));
    try testing.expectEqual(@as(u8, '9'), hexDigit(9));
    try testing.expectEqual(@as(u8, 'A'), hexDigit(10));
    try testing.expectEqual(@as(u8, 'F'), hexDigit(15));
}

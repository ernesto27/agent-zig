const std = @import("std");
const json_helpers = @import("../json_helpers.zig");
const provider = @import("tavily.zig");
const types = @import("types.zig");

pub const ExecResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub fn search(allocator: std.mem.Allocator, input: std.json.Value) ExecResult {
    const query = json_helpers.getStringField(input, "query") orelse return .{
        .content = "Invalid input: expected { query: string, max_results?: integer, topic?: string }",
        .is_error = true,
    };

    const params = types.WebSearchParams{
        .query = query,
        .max_results = json_helpers.getIntegerField(input, "max_results") orelse 5,
        .topic = json_helpers.getStringField(input, "topic") orelse "general",
    };

    const content = provider.search(allocator, params) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Web search failed: {}", .{err}) catch
            return .{ .content = "Web search failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    return .{ .content = content };
}

pub fn extract(allocator: std.mem.Allocator, input: std.json.Value) ExecResult {
    const urls = getUrlsField(allocator, input, "urls") catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Invalid input: {}", .{err}) catch
            return .{ .content = "Invalid input for web_extract", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(urls);

    if (urls.len == 0) {
        return .{
            .content = "Invalid input: expected { urls: string | []string, format?: string, extract_depth?: string }",
            .is_error = true,
        };
    }

    const params = types.WebExtractParams{
        .urls = urls,
        .format = json_helpers.getStringField(input, "format") orelse "markdown",
        .extract_depth = json_helpers.getStringField(input, "extract_depth") orelse "basic",
    };

    const content = provider.extract(allocator, params) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Web extract failed: {}", .{err}) catch
            return .{ .content = "Web extract failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    return .{ .content = content };
}

fn getUrlsField(allocator: std.mem.Allocator, input: std.json.Value, field: []const u8) ![]const []const u8 {
    const val = json_helpers.getField(input, field) orelse return error.MissingUrls;

    return switch (val) {
        .string => blk: {
            const urls = try allocator.alloc([]const u8, 1);
            urls[0] = val.string;
            break :blk urls;
        },
        .array => |items| blk: {
            const urls = try allocator.alloc([]const u8, items.items.len);
            var count: usize = 0;
            for (items.items) |item| {
                if (item != .string) {
                    allocator.free(urls);
                    return error.InvalidUrls;
                }
                urls[count] = item.string;
                count += 1;
            }
            break :blk urls;
        },
        else => error.InvalidUrls,
    };
}

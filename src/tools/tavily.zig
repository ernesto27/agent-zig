const std = @import("std");
const build_info = @import("../build_info.zig");
const types = @import("types.zig");

const log = std.log.scoped(.tavily);

const base_url = "https://api.tavily.com";
const api_key = build_info.tavily_api_key;

pub fn search(allocator: std.mem.Allocator, params: types.WebSearchParams) ![]u8 {
    const request_body = types.TavilySearchRequest{
        .query = params.query,
        .max_results = params.max_results,
        .topic = params.topic,
        .search_depth = params.search_depth,
    };

    const body = try std.json.Stringify.valueAlloc(allocator, request_body, .{});
    defer allocator.free(body);

    const response_bytes = try postJson(allocator, "/search", body);
    defer allocator.free(response_bytes);

    const parsed = try std.json.parseFromSlice(types.TavilySearchResponse, allocator, response_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const results = try allocator.alloc(types.WebSearchResult, parsed.value.results.len);
    defer allocator.free(results);

    for (parsed.value.results, 0..) |result, i| {
        results[i] = .{
            .title = result.title orelse "",
            .url = result.url orelse "",
            .content = result.content orelse "",
            .score = result.score,
        };
    }

    const output = types.WebSearchOutput{
        .query = parsed.value.query orelse params.query,
        .answer = parsed.value.answer,
        .results = results,
    };

    return std.json.Stringify.valueAlloc(allocator, output, .{ .whitespace = .indent_2 });
}

pub fn extract(allocator: std.mem.Allocator, params: types.WebExtractParams) ![]u8 {
    const request_body = types.TavilyExtractRequest{
        .urls = params.urls,
        .format = params.format,
        .extract_depth = params.extract_depth,
    };

    const body = try std.json.Stringify.valueAlloc(allocator, request_body, .{});
    defer allocator.free(body);

    const response_bytes = try postJson(allocator, "/extract", body);
    defer allocator.free(response_bytes);

    const parsed = try std.json.parseFromSlice(types.TavilyExtractResponse, allocator, response_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const results = try allocator.alloc(types.WebExtractResult, parsed.value.results.len);
    defer allocator.free(results);

    for (parsed.value.results, 0..) |result, i| {
        results[i] = .{
            .url = result.url orelse "",
            .content = result.content orelse result.raw_content orelse "",
            .favicon = result.favicon,
        };
    }

    const output = types.WebExtractOutput{
        .results = results,
        .failed_results = parsed.value.failed_results,
    };

    return std.json.Stringify.valueAlloc(allocator, output, .{ .whitespace = .indent_2 });
}

fn postJson(allocator: std.mem.Allocator, endpoint: []const u8, body: []const u8) ![]u8 {
    if (api_key.len == 0) return error.MissingApiKey;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, endpoint });
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
    };

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &extra_headers,
        .response_writer = &aw.writer,
    });

    const response = aw.writer.buffer[0..aw.writer.end];
    if (result.status != .ok) {
        log.err("Tavily request failed with HTTP {d}: {s}", .{ @intFromEnum(result.status), response });
        return error.HttpRequestFailed;
    }

    return allocator.dupe(u8, response);
}

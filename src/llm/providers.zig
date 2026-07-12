const std = @import("std");
const json_helpers = @import("../json_helpers.zig");

const log = std.log.scoped(.providers);

/// Conservative output-token ceiling for models that don't advertise their own
/// `max_completion_tokens`. Output is always a fraction of the context window.
const output_cap: u64 = 32_768;

pub const Model = struct {
    id: []const u8,
    display: []const u8,
    free: bool = false,
    supports_thinking: bool = false,
    max_context: u32 = 200_000,
    max_output: u32,
};

pub const FindResult = struct {
    provider: *const Provider,
    model: *const Model,
};

pub const Provider = struct {
    name: []const u8,
    models: []const Model,
};

pub const providers = [_]Provider{
    .{
        .name = "Anthropic",
        .models = &[_]Model{
            .{ .id = "claude-opus-4-6", .display = "Claude Opus 4.6", .supports_thinking = true, .max_output = 128_000 },
            .{ .id = "claude-sonnet-4-6", .display = "Claude Sonnet 4.6", .supports_thinking = true, .max_output = 128_000 },
            .{ .id = "claude-haiku-4-5-20251001", .display = "Claude Haiku 4.5", .max_output = 64_000 },
        },
    },
    .{
        .name = "OpenAI",
        .models = &[_]Model{
            .{ .id = "gpt-5.5", .display = "GPT-5.5", .supports_thinking = true, .max_context = 1_050_000, .max_output = 128_000 },
            .{ .id = "gpt-5.4", .display = "GPT-5.4", .supports_thinking = true, .max_context = 272_000, .max_output = 128_000 },
            .{ .id = "gpt-5.4-pro", .display = "GPT-5.4 Pro", .supports_thinking = true, .max_context = 272_000, .max_output = 128_000 },
            .{ .id = "gpt-5.4-mini", .display = "GPT-5.4 Mini", .supports_thinking = true, .max_context = 128_000, .max_output = 64_000 },
            .{ .id = "gpt-5.4-nano", .display = "GPT-5.4 Nano", .supports_thinking = true, .max_context = 128_000, .max_output = 64_000 },
            .{ .id = "gpt-5", .display = "GPT-5", .supports_thinking = true, .max_context = 128_000, .max_output = 64_000 },
            .{ .id = "gpt-5-mini", .display = "GPT-5 Mini", .supports_thinking = true, .max_context = 128_000, .max_output = 64_000 },
        },
    },
    .{
        .name = "DeepSeek",
        .models = &[_]Model{
            .{ .id = "deepseek-v4-flash", .display = "DeepSeek V4 Flash", .supports_thinking = true, .max_context = 1_000_000, .max_output = 64_000 },
            .{ .id = "deepseek-v4-pro", .display = "DeepSeek V4 Pro", .supports_thinking = true, .max_context = 1_000_000, .max_output = 64_000 },
        },
    },
    .{
        .name = "Gemini",
        .models = &[_]Model{
            .{ .id = "gemini-2.5-pro", .display = "Gemini 2.5 Pro", .supports_thinking = true, .max_context = 1_048_576, .max_output = 65_536 },
            .{ .id = "gemini-2.5-flash", .display = "Gemini 2.5 Flash", .supports_thinking = true, .max_context = 1_048_576, .max_output = 65_536 },
            .{ .id = "gemini-2.5-flash-lite", .display = "Gemini 2.5 Flash Lite", .max_context = 1_048_576, .max_output = 65_536 },
        },
    },
};

// === Dynamic OpenRouter model store ===
//
// The four providers above are compile-time data. OpenRouter has hundreds of
// models that change over time, so its list is fetched from the API at startup
// (see OpenRouterStore.fetch) into the module-level `openrouter_store`. Exactly
// one publish happens per session, so `models_slice` goes empty -> populated
// once and the backing arena is freed only in deinit; therefore any *const
// Model returned by find/findModel stays valid for the whole app lifetime.

const openrouter_url = "https://openrouter.ai/api/v1/models";

pub const OpenRouterStore = struct {
    mutex: std.Thread.Mutex = .{},
    arena: ?std.heap.ArenaAllocator = null,
    models_slice: []const Model = &.{},
    provider_entry: Provider = .{ .name = "OpenRouter", .models = &.{} },

    /// Stable-address synthetic OpenRouter provider. Always valid; its `.models`
    /// may be empty until `fetch` publishes.
    pub fn provider(self: *OpenRouterStore) *const Provider {
        return &self.provider_entry;
    }

    /// Snapshot of the currently published models. Elements live for the app's
    /// lifetime (arena freed only in `deinit`), so the returned slice may be
    /// iterated after the lock is released.
    pub fn models(self: *OpenRouterStore) []const Model {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.models_slice;
    }

    /// Resolve a dynamic OpenRouter model id to its provider + model pointers.
    pub fn find(self: *OpenRouterStore, id: []const u8) ?FindResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.models_slice) |*m| {
            if (std.mem.eql(u8, m.id, id)) return .{ .provider = &self.provider_entry, .model = m };
        }
        return null;
    }

    /// Takes ownership of `arena` and publishes `ms` (which must be allocated
    /// from `arena`). Called once, from the fetch thread.
    fn publish(self: *OpenRouterStore, arena: std.heap.ArenaAllocator, ms: []const Model) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.arena = arena;
        self.models_slice = ms;
        self.provider_entry.models = ms;
    }

    /// Frees the store arena. Call once at shutdown, before the gpa is deinited.
    pub fn deinit(self: *OpenRouterStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.arena) |*aptr| aptr.deinit();
        self.arena = null;
        self.models_slice = &.{};
        self.provider_entry.models = &.{};
    }

    /// Fetch the OpenRouter model list, keep only tool-capable models, and
    /// publish them into the store. Blocking; call from a background thread. On
    /// any failure the store is left untouched (empty) and the error is returned
    /// for the caller to log.
    pub fn fetch(self: *OpenRouterStore, gpa: std.mem.Allocator) !void {
        var client = std.http.Client{ .allocator = gpa };
        defer client.deinit();

        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = openrouter_url },
            .method = .GET,
            .response_writer = &aw.writer,
            // An explicitly-empty decompress buffer forces std's flate
            // Decompress onto its "direct" path (decompresses straight into the
            // growing Allocating writer). The default path allocates a window
            // buffer and takes the "indirect" path, whose internal writer has an
            // unreachableRebase vtable that panics ("reached unreachable code")
            // on gzip responses whose window fills mid-stream — e.g. OpenRouter's
            // /api/v1/models.
            .decompress_buffer = &.{},
        });

        const body = aw.writer.buffer[0..aw.writer.end];
        if (result.status != .ok) {
            log.err("OpenRouter models fetch failed: HTTP {d}", .{@intFromEnum(result.status)});
            return error.HttpRequestFailed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();

        const data = json_helpers.getField(parsed.value, "data") orelse return error.MissingData;
        if (data != .array) return error.MissingData;

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var list: std.ArrayList(Model) = .{};

        for (data.array.items) |item| {
            const params = json_helpers.getField(item, "supported_parameters") orelse continue;
            if (params != .array) continue;

            var has_tools = false;
            var has_reasoning = false;
            for (params.array.items) |pv| {
                if (pv != .string) continue;
                if (std.mem.eql(u8, pv.string, "tools")) has_tools = true;
                if (std.mem.eql(u8, pv.string, "reasoning")) has_reasoning = true;
            }
            if (!has_tools) continue;

            const id = json_helpers.getStringField(item, "id") orelse continue;
            const name = json_helpers.getStringField(item, "name") orelse id;
            // orelse only catches a missing/null field; an explicit 0 must also
            // fall back, since max_context is a divisor in App.onUsage.
            const raw_ctx = json_helpers.getU64Field(item, "context_length") orelse 200_000;
            const ctx_len: u64 = if (raw_ctx == 0) 200_000 else raw_ctx;
            const max_ctx: u32 = if (ctx_len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(ctx_len);

            // When the endpoint omits an explicit output cap, don't assume the
            // full context window (output is always a fraction of it): clamp to
            // a conservative ceiling.
            const out_fallback: u64 = @min(ctx_len, output_cap);
            const raw_out: u64 = if (json_helpers.getObjectField(item, "top_provider")) |tp|
                json_helpers.getU64Field(tp, "max_completion_tokens") orelse out_fallback
            else
                out_fallback;
            const out_len: u64 = if (raw_out == 0) out_fallback else raw_out;
            const max_out: u32 = if (out_len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(out_len);

            var is_free = false;
            if (json_helpers.getObjectField(item, "pricing")) |pricing| {
                const prompt = json_helpers.getStringField(pricing, "prompt") orelse "";
                const completion = json_helpers.getStringField(pricing, "completion") orelse "";
                is_free = std.mem.eql(u8, prompt, "0") and std.mem.eql(u8, completion, "0");
            }

            try list.append(a, .{
                .id = try a.dupe(u8, id),
                .display = try a.dupe(u8, name),
                .free = is_free,
                .supports_thinking = has_reasoning,
                .max_context = max_ctx,
                .max_output = max_out,
            });
        }

        const ms = try list.toOwnedSlice(a);
        log.info("OpenRouter: loaded {d} tool-capable models", .{ms.len});
        self.publish(arena, ms);
    }
};

pub var openrouter_store: OpenRouterStore = .{};

pub fn findModel(id: []const u8) ?FindResult {
    for (&providers) |*p| {
        for (p.models) |*m| {
            if (std.mem.eql(u8, m.id, id)) return .{ .provider = p, .model = m };
        }
    }
    return openrouter_store.find(id);
}

// === Tests ===

const testing = std.testing;

test "findModel locates a model and its owning provider" {
    const found = findModel("claude-opus-4-6").?;
    try testing.expectEqualStrings("Anthropic", found.provider.name);
    try testing.expectEqualStrings("Claude Opus 4.6", found.model.display);
    try testing.expect(found.model.supports_thinking);
}

test "findModel resolves provider isolation for same-named lookups across providers" {
    try testing.expectEqualStrings("OpenAI", findModel("gpt-5.5").?.provider.name);
    try testing.expectEqualStrings("DeepSeek", findModel("deepseek-v4-pro").?.provider.name);
}

test "findModel returns null for unknown id" {
    try testing.expect(findModel("does-not-exist") == null);
    try testing.expect(findModel("") == null);
}

test "Model defaults apply when fields omitted" {
    const haiku = findModel("claude-haiku-4-5-20251001").?.model;
    try testing.expect(!haiku.supports_thinking); // default false
    try testing.expectEqual(@as(u32, 200_000), haiku.max_context); // default
}

test "every model id is unique across all providers" {
    for (&providers) |*p| {
        for (p.models) |*m| {
            // A duplicate id would resolve to the first provider, not this one.
            try testing.expectEqual(p, findModel(m.id).?.provider);
        }
    }
}

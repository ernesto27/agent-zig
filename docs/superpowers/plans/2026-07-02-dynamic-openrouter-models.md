# Dynamic OpenRouter Model Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the OpenRouter model list from the live API at startup instead of hardcoding ~10 entries, filtering to tool-capable models, while keeping the other four providers hardcoded and the `findModel` pointer API unchanged.

**Architecture:** A module-level runtime store in `src/llm/providers.zig` owns an arena and a published `[]Model` slice plus a stable-address synthetic `Provider{ .name = "OpenRouter" }`. A background thread spawned at startup fetches `https://openrouter.ai/api/v1/models`, parses+filters into the arena, and publishes once. `findModel` and both pickers consult the four static providers plus this store. No disk cache — every launch fetches fresh; offline means an empty OpenRouter section.

**Tech Stack:** Zig 0.15.2+, `std.http.Client` (as in `src/tools/tavily.zig` / `src/cli/update.zig`), `std.json` + `src/json_helpers.zig`, `std.Thread` + `ui.wakeLoop` (as in `versionCheckThread` / `mcpLoadEntry`).

## Global Constraints

- Zig 0.15.2+ idioms: unmanaged `std.ArrayList` (`.{}` init, allocator passed per-call); `std.Io.Writer.Allocating` for HTTP response capture.
- Repo rule — **no silent catch**: every `catch` logs its error (use `std.log.scoped`). Never `catch {}`.
- Repo rule — **do not commit automatically**: leave changes unstaged; commit only when the user asks. Work on `master`, no feature branch.
- Repo rule — **no unprompted unit tests**: do not add new test blocks; verification is `zig build`, the existing `zig build test`, and manual TUI checks. The existing `providers.zig` tests must still pass.
- Repo rule — **user runs verification**: do not run `zig build`/`zig build test`/`zig build run` yourself; present the exact command and ask the user to run it and paste output.
- OpenRouter fetch URL is exactly `https://openrouter.ai/api/v1/models` (public, no auth header).
- Provider name string is exactly `"OpenRouter"` (matches `config.Providers.forProvider`).

---

### Task 1: Runtime store + fetch in `providers.zig`

**Files:**
- Modify: `src/llm/providers.zig` (remove the hardcoded OpenRouter block at lines 57-71; add store, accessors, fetch, publish, deinit; extend `findModel`)

**Interfaces:**
- Consumes: `src/json_helpers.zig` (`getField`, `getObjectField`, `getStringField`, `getU64Field`); relative import path from `src/llm/` is `../json_helpers.zig`.
- Produces (used by Tasks 2 and 3) — a single `pub var openrouter_store: OpenRouterStore` instance with methods:
  - `pub fn provider(self) *const Provider` — stable-address synthetic provider, always valid, models possibly empty.
  - `pub fn models(self) []const Model` — snapshot of the published slice (elements live for the app's lifetime).
  - `pub fn find(self, id) ?FindResult` — resolve a dynamic id.
  - `pub fn fetch(self, gpa) !void` — blocking HTTP+parse+publish; call from a background thread.
  - `pub fn deinit(self) void` — frees the store arena; call once at shutdown.
  - `findModel` now delegates to `openrouter_store.find(id)` after scanning the static providers.

- [ ] **Step 1: Add the import and scoped logger at the top of `providers.zig`**

After the existing `const std = @import("std");` (line 1), add:

```zig
const json_helpers = @import("../json_helpers.zig");

const log = std.log.scoped(.providers);
```

- [ ] **Step 2: Remove the hardcoded OpenRouter provider block**

Delete the entire `OpenRouter` entry (current lines 57-71) from the `providers` array, so the array ends after the `Gemini` block:

```zig
    .{
        .name = "Gemini",
        .models = &[_]Model{
            .{ .id = "gemini-2.5-pro", .display = "Gemini 2.5 Pro", .supports_thinking = true, .max_context = 1_048_576 },
            .{ .id = "gemini-2.5-flash", .display = "Gemini 2.5 Flash", .supports_thinking = true, .max_context = 1_048_576 },
            .{ .id = "gemini-2.5-flash-lite", .display = "Gemini 2.5 Flash Lite", .max_context = 1_048_576 },
        },
    },
};
```

- [ ] **Step 3: Add the runtime store, accessors, publish, and deinit**

Insert immediately after the `providers` array (before `pub fn findModel`):

```zig
// === Dynamic OpenRouter model store ===
//
// The four providers above are compile-time data. OpenRouter has hundreds of
// models that change over time, so its list is fetched from the API at startup
// (see fetchOpenRouter) into this module-level store. Exactly one publish
// happens per session, so `store.models` goes empty -> populated once and the
// backing arena is freed only in deinitStore; therefore any *const Model
// returned by findModel stays valid for the whole app lifetime.

const openrouter_url = "https://openrouter.ai/api/v1/models";

const OpenRouterStore = struct {
    mutex: std.Thread.Mutex = .{},
    arena: ?std.heap.ArenaAllocator = null,
    models: []const Model = &.{},
    provider: Provider = .{ .name = "OpenRouter", .models = &.{} },
};

var store: OpenRouterStore = .{};

/// Stable-address synthetic OpenRouter provider. Always valid; `.models` may be
/// empty until fetchOpenRouter publishes.
pub fn openRouterProvider() *const Provider {
    return &store.provider;
}

/// Snapshot of the currently published OpenRouter models. Elements live for the
/// app's lifetime (arena freed only in deinitStore), so the returned slice may
/// be iterated after the internal lock is released.
pub fn openRouterModels() []const Model {
    store.mutex.lock();
    defer store.mutex.unlock();
    return store.models;
}

/// Takes ownership of `arena` and publishes `models` (which must be allocated
/// from `arena`). Called once, from the fetch thread.
fn publish(arena: std.heap.ArenaAllocator, models: []const Model) void {
    store.mutex.lock();
    defer store.mutex.unlock();
    store.arena = arena;
    store.models = models;
    store.provider.models = models;
}

/// Frees the store arena. Call once at shutdown, before the gpa is deinited.
pub fn deinitStore() void {
    store.mutex.lock();
    defer store.mutex.unlock();
    if (store.arena) |*a| a.deinit();
    store.arena = null;
    store.models = &.{};
    store.provider.models = &.{};
}
```

- [ ] **Step 4: Extend `findModel` to resolve dynamic OpenRouter ids**

Replace the existing `findModel` body (current lines 74-81) with:

```zig
pub fn findModel(id: []const u8) ?FindResult {
    for (&providers) |*p| {
        for (p.models) |*m| {
            if (std.mem.eql(u8, m.id, id)) return .{ .provider = p, .model = m };
        }
    }
    store.mutex.lock();
    defer store.mutex.unlock();
    for (store.models) |*m| {
        if (std.mem.eql(u8, m.id, id)) return .{ .provider = &store.provider, .model = m };
    }
    return null;
}
```

- [ ] **Step 5: Add the fetch function**

Insert after `findModel` (before the `// === Tests ===` marker):

```zig
/// Fetch the OpenRouter model list, keep only tool-capable models, and publish
/// them into the store. Blocking; call from a background thread. On any failure
/// the store is left untouched (empty) and the error is returned for the caller
/// to log.
pub fn fetchOpenRouter(gpa: std.mem.Allocator) !void {
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = openrouter_url },
        .method = .GET,
        .response_writer = &aw.writer,
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
        const ctx_len = json_helpers.getU64Field(item, "context_length") orelse 200_000;
        const max_ctx: u32 = if (ctx_len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(ctx_len);

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
        });
    }

    const models = try list.toOwnedSlice(a);
    log.info("OpenRouter: loaded {d} tool-capable models", .{models.len});
    publish(arena, models);
}
```

- [ ] **Step 6: Ask the user to build**

Run: `zig build`
Expected: compiles with no errors.

- [ ] **Step 7: Ask the user to run the existing tests**

Run: `zig build test`
Expected: PASS. The existing `providers.zig` tests reference only static ids (`claude-opus-4-6`, `gpt-5.5`, `deepseek-v4-pro`, `claude-haiku-4-5-20251001`) and iterate the static `providers` array, so removing the OpenRouter block does not affect them.

- [ ] **Step 8: (No commit — repo rule: commit only when the user asks.)**

---

### Task 2: Show dynamic OpenRouter models in the pickers

**Files:**
- Modify: `src/model_picker.zig` (`refresh`, current lines 49-66; and `render` — window fix below)
- Modify: `src/provider_picker.zig` (`refresh`, current lines 27-38)

**Note (found during execution):** `model_picker.render` used a fixed 64-item
stack buffer but passed the absolute `self.selected`. With hundreds of models,
`selected > 64` made `modal_list.render` slice `items[first..]` out of bounds
("start index N is larger than end index 64"). Fix: pass a windowed slice that
always contains `selected`, with a window-relative selected index
(`.selected = self.selected - start`). `modal_list` scrolls within the slice.

**Interfaces:**
- Consumes: `p.openrouter_store.provider()`, `p.openrouter_store.models()` from Task 1 (`p` is `agent.llm.providers`).
- Produces: pickers now list the four static providers plus the dynamic OpenRouter entries.

- [ ] **Step 1: Append dynamic OpenRouter models in `model_picker.zig` `refresh`**

In `refresh` (current lines 49-66), after the existing `for (&p.providers) |*prov| { ... }` loop and before the closing brace of the function, add:

```zig
        const or_prov = p.openrouter_store.provider();
        for (p.openrouter_store.models()) |*m| {
            const q = self.query.items;
            const matches = q.len == 0 or
                std.ascii.indexOfIgnoreCase(m.display, q) != null or
                std.ascii.indexOfIgnoreCase(m.id, q) != null or
                std.ascii.indexOfIgnoreCase(or_prov.name, q) != null;
            if (!matches) continue;
            try self.results.append(alloc, m);
            try self.labels.append(alloc, try buildLabel(alloc, or_prov.name, m.id));
        }
```

(`for (p.openRouterModels()) |*m|` yields `*const Model` pointing into the store arena — valid to append and use after `refresh` returns.)

- [ ] **Step 2: Append the OpenRouter provider in `provider_picker.zig` `refresh`**

In `refresh` (current lines 27-38), after the existing `for (&p.providers) |*prov| { ... }` loop and before the closing brace of the function, add:

```zig
        const or_prov = p.openrouter_store.provider();
        const q = self.query.items;
        if (q.len == 0 or std.ascii.indexOfIgnoreCase(or_prov.name, q) != null) {
            try self.results.append(alloc, or_prov);
        }
```

- [ ] **Step 3: Ask the user to build**

Run: `zig build`
Expected: compiles with no errors.

- [ ] **Step 4: (No commit yet.)**

---

### Task 3: Spawn the fetch thread at startup, re-resolve selection, free at shutdown

**Files:**
- Modify: `src/main.zig` (add `openRouterFetchThread`; spawn it near `versionCheckThread` at current lines 233-234)
- Modify: `src/App.zig` (call `agent.llm.providers.deinitStore()` in `deinit`, current lines 340-361)

**Interfaces:**
- Consumes: `agent.llm.providers.openrouter_store.fetch`, `findModel`, `openrouter_store.deinit` (Task 1); `ui.wakeLoop`, `App`, `EventLoop` (already imported in `main.zig`).
- Produces: OpenRouter models populate live shortly after launch; a previously-selected OpenRouter model is re-resolved into the client config after the fetch; the store arena is freed at shutdown.

- [ ] **Step 1: Add `openRouterFetchThread` in `main.zig`**

Immediately after the `versionCheckThread` function (current lines 40-49), add:

```zig
fn openRouterFetchThread(app: *App, loop: *EventLoop) void {
    agent.llm.providers.openrouter_store.fetch(app.alloc) catch |err| {
        log.err("OpenRouter model fetch failed: {}", .{err});
        return;
    };

    app.mutex.lock();
    // If the persisted selection is an OpenRouter model, it wasn't resolvable at
    // startup (store was empty). Now that the list is loaded, wire up the client
    // config. Guard on an empty provider_name so we never clobber an already
    // resolved (static-provider) selection or an in-flight request's config.
    if (app.llm_client.config.provider_name.len == 0) {
        if (agent.llm.providers.findModel(app.llm_client.config.model)) |found| {
            app.llm_client.config.provider_name = found.provider.name;
            if (app.config_store.cfg.providers.forProvider(found.provider.name)) |pc| {
                app.llm_client.config.base_url = pc.baseUrl;
                app.llm_client.config.api_key = pc.apiKey;
                agent.config.resolveApiKey(&app.llm_client.config.api_key, found.provider.name);
                app.llm_client.config.effort = app.config_store.thinkEffort(found.provider.name);
            }
        }
    }
    app.needs_redraw = true;
    app.mutex.unlock();

    ui.wakeLoop(loop);
}
```

- [ ] **Step 2: Spawn the thread at startup**

After the existing version-thread spawn (current lines 233-234):

```zig
    const version_thread = try std.Thread.spawn(.{}, versionCheckThread, .{ &app, &loop });
    version_thread.detach();
```

add:

```zig
    const openrouter_thread = try std.Thread.spawn(.{}, openRouterFetchThread, .{ &app, &loop });
    openrouter_thread.detach();
```

- [ ] **Step 3: Free the store arena in `App.deinit`**

In `src/App.zig` `deinit` (current lines 340-361), add as the last statement before the closing brace (after `if (self.latest_version) |v| self.alloc.free(v);`):

```zig
        agent.llm.providers.openrouter_store.deinit();
```

- [ ] **Step 4: Ask the user to build**

Run: `zig build`
Expected: compiles with no errors.

- [ ] **Step 5: Ask the user to run the app and verify manually**

Run: `zig build run`
Expected (with network):
1. App starts normally.
2. Open the model picker with `/model` — within ~1-2s the list includes many `... [openrouter]` entries (tool-capable models only); free models show the "Free" badge.
3. `/provider` lists `OpenRouter`.
4. Select an OpenRouter model, send a message — it routes through the OpenRouter base URL and works (requires an OpenRouter API key configured via `/provider`).
5. Quit and relaunch with the OpenRouter model still selected — after the fetch lands, sending a message still works (re-resolution path).

Offline check: with no network, the app starts, `/model` shows only the four static providers' models, and no crash occurs (check `~/.config/agent-zig/agent.log` for the logged fetch error).

- [ ] **Step 6: (No commit — the user will commit when ready.)**

---

## Notes / tradeoffs

- **Detached fetch thread** mirrors `versionCheckThread`. If the user quits within the ~1s fetch window, there is a benign teardown race (same class as the existing version thread). `deinitStore` is mutex-guarded; a publish that lands after `deinitStore` would leak one small arena at process exit only.
- **No new unit tests** per repo convention. The parse/filter logic in `fetchOpenRouter` is pure below the HTTP call and could be extracted + tested if the user later wants it; not included here.
- **No config schema change.** Startup selection of a dynamic model is handled by the re-resolution step in `openRouterFetchThread` rather than persisting a provider name.

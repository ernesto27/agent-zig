# Dynamic OpenRouter Model Loading — Design

Date: 2026-07-02
Status: approved (design)

## Problem

`src/llm/providers.zig` hardcodes ~10 OpenRouter models in a compile-time
`providers` array. OpenRouter offers hundreds of models that change over time,
so a hardcoded list is always stale and incomplete. We want the OpenRouter model
list loaded dynamically from the OpenRouter API at runtime, while the other four
providers (Anthropic, OpenAI, DeepSeek, Gemini) stay hardcoded.

## Goals

- Load the OpenRouter model list from the live API each launch.
- Filter to models usable by an agent (tool-capable).
- Keep the existing `findModel()` pointer-returning API and all downstream
  consumers working unchanged.
- Never crash on network/parse failure; degrade to an empty OpenRouter section.

## Non-goals (YAGNI)

- **No disk cache.** Always fetch from the API on each launch; no
  `openrouter_models.json`.
- No TTL / staleness logic, no manual `/model refresh` command.
- No API-key gating — always fetch (the list endpoint is public).
- No config schema change — OpenRouter's `ProviderConfig` already exists.
- No changes to the other four providers beyond removing the hardcoded
  OpenRouter block.

## Decisions (from brainstorming)

1. **Fetch trigger:** startup, asynchronously in a background thread (mirrors
   `versionCheckThread` / `mcpLoadEntry`).
2. **Filtering:** only models whose `supported_parameters` includes `"tools"`.
3. **No hardcoded fallback:** the OpenRouter block is removed; the section is
   empty until the fetch lands (and stays empty for offline runs).
4. **Always fetch**, regardless of whether an OpenRouter API key is configured.
5. **No cache file:** always go to the API; empty until each launch's fetch
   completes.

## Data source & mapping

`GET https://openrouter.ai/api/v1/models` (public, no auth). Response shape:

```json
{ "data": [
  { "id": "...", "name": "...", "context_length": 200000,
    "supported_parameters": ["tools", "reasoning", ...],
    "pricing": { "prompt": "0", "completion": "0", ... } }
] }
```

For each entry:

- **Filter:** keep only if `supported_parameters` contains `"tools"`.
- `id` → `Model.id` (owned in the store arena).
- `name` → `Model.display` (owned). No `"OR:"` prefix — the picker label already
  appends `[openrouter]`.
- `context_length` → `max_context` (saturate to `u32`; default `200_000` if
  absent).
- `supports_thinking` = `supported_parameters` contains `"reasoning"`.
- `free` = `pricing.prompt == "0"` AND `pricing.completion == "0"`.

## Architecture (Approach A — separate runtime store)

The compile-time `providers` array stays as-is for the four hardcoded providers
(only the OpenRouter block is removed). All dynamic complexity is isolated in a
module-level runtime store in `src/llm/providers.zig`.

### Runtime store

```
OpenRouterStore:
  arena:    std.heap.ArenaAllocator   // backing memory for published models
  models:   []const Model = &.{}      // currently published slice
  provider: Provider = .{ .name = "OpenRouter", .models = &.{} }
  mutex:    std.Thread.Mutex
```

- `provider` has a **stable address** so `findModel` can return
  `&store.provider`; its `.models` is repointed on publish.
- `publish(models)`: under `mutex`, set `store.models` and
  `store.provider.models`.
- Exactly **one** publish happens per session (the fetch), so there is a single
  arena and no generation-swap. Any `*const Model` returned by `findModel`
  remains valid for the whole app lifetime (arena freed only at `deinit`).

### Startup flow

1. App start: OpenRouter section is empty (`store.models` is empty).
2. Spawn a background thread (like `versionCheckThread`):
   - HTTP `GET` the models endpoint (via `std.http.Client`, as in
     `tools/tavily.zig` / `cli/update.zig`).
   - Parse JSON, filter to tool-capable, map into the store arena.
   - `store.publish(models)`.
   - Under `app.mutex`: `needs_redraw = true`; then `ui.wakeLoop(loop)`.
3. The picker/UI reflects the populated list on the next render.

### `findModel` & picker integration

- `findModel(id)`: scan the four static providers first; if not found, lock the
  store, scan `store.models`, and return
  `.{ .provider = &store.provider, .model = &store.models[i] }`.
- Pickers (`model_picker.zig`, `provider_picker.zig`) iterate the four static
  providers **plus** `store.models` / `store.provider`, via a small accessor
  helper. They lock the store mutex while copying pointers / building labels,
  then may use the (arena-lifetime) pointers after unlocking.
- The downstream contract is unchanged: `supports_thinking`, `max_context`,
  `.free`, `provider.name` are all read the same way.

## Error handling (repo rule: no silent catch)

- Network failure / non-200 / JSON parse error → **log to `agent.log`** and leave
  `store.models` empty. Never crash, never `catch {}`.
- Every `catch` logs its error (per `feedback_no_silent_catch`).
- First run / offline → OpenRouter section simply empty for the session.

## Blast radius

- `src/llm/providers.zig` — remove hardcoded OpenRouter block; add store, fetch,
  accessor; extend `findModel`.
- `src/model_picker.zig` / `src/provider_picker.zig` — iterate static + store.
- Startup wiring (`src/main.zig` and/or `src/App.zig`) — spawn the fetch thread.
- No changes needed in `openai.zig` / `gemini.zig` / `anthropic.zig`,
  `App.zig` context-usage, `cli/print.zig`, `input_handler.zig` — they call
  `findModel` and read the same fields.

## Testing notes

- `providers.zig` existing tests must still pass (static providers, uniqueness).
- Store behavior (parse+filter mapping, publish) is unit-testable with a sample
  JSON payload without network. (Only add tests if requested — repo convention
  is no unprompted tests.)

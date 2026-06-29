# Plan: Add OpenRouter LLM Provider

- **Date:** 2026-06-28
- **Domain(s):** backend (LLM provider integration)
- **Author:** plan-from-spec (reviewed with ernesto@pigmalion.co)
- **Status:** Draft

## 1. Summary

Add OpenRouter (https://openrouter.ai) as a fifth selectable LLM provider. OpenRouter
exposes an OpenAI-compatible Chat Completions API, so it reuses the existing
`src/llm/openai.zig` backend rather than adding a new one. The work is mostly
registration (provider list, config struct, backend dispatch map) plus one behavioral
addition: OpenRouter reasoning/thinking support, implemented in the OpenAI backend and
gated so plain OpenAI requests are byte-for-byte unchanged. A curated list of 10 popular
OpenRouter models ships in the static provider table; `/provider` and `/model` pickers
discover the new provider automatically.

## 2. Scope

### In scope
- Register `OpenRouter` provider with a curated 10-model list.
- Persisted config: `providers.openrouter` block with default base URL. Key is set via
  `/provider` only (no env-var fallback).
- Backend dispatch: route `OpenRouter` to the existing `.openai` backend.
- Reasoning support for OpenRouter: send `reasoning.effort` on requests and parse
  `delta.reasoning` stream deltas into a thinking block + live `on_thinking_chunk`
  callbacks. Gated to OpenRouter only.

### Out of scope / non-goals
- Dynamic model discovery from `/api/v1/models` (curated static list only).
- Free-text / arbitrary slug entry in the pickers.
- `HTTP-Referer` / `X-Title` ranking headers (deliberately skipped).
- All automated tests, unit and integration (verification is manual — see §8).
- Reasoning support for the plain OpenAI provider (unchanged; still no reasoning param).
- `reasoning_details` round-tripping / signature preservation (OpenRouter does not give
  an Anthropic-style signature; reconstructed thinking blocks are display-only and are
  already dropped by `appendAssistantContentBlocks`, so they never re-enter a request).

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | How to offer OpenRouter's 300+ models? | Curated hardcoded list (10 models) in `providers.zig`. |
| 2 | Reasoning/thinking support? | Implement now, in the OpenAI backend, gated to OpenRouter. |
| 3 | `HTTP-Referer` / `X-Title` ranking headers? | Skip them. |
| 4 | Base URL value? | `https://openrouter.ai/api` — `openai.zig` appends `/v1/chat/completions`, yielding the correct `https://openrouter.ai/api/v1/chat/completions`. |
| 5 | API key env fallback? | No env-var fallback (per user). Key is entered via `/provider` and persisted to config. |
| 6 | Effort → OpenRouter reasoning mapping? | `none`→omit, `low`→`low`, `medium`→`medium`, `high`→`high`, `max`→`high`. OpenRouter normalizes per-model (e.g. `xhigh`); unified API takes `low/medium/high`. |
| 7 | Which 10 curated models? | See §4 table (confirmed against live `/api/v1/models`, biased to the most-popular page). |
| 8 | Test approach? | No automated tests (per user). Manual, documented acceptance steps only. |

## 4. Design

### Reuse strategy
OpenRouter is OpenAI-wire-compatible. The dispatcher in `src/llm/client.zig`
(`backendFor`) maps provider name → `Backend` enum; adding `"OpenRouter" → .openai`
routes all requests through `src/llm/openai.zig`. No new provider file.

### Curated model list (slugs confirmed against live `/api/v1/models`)

| Slug (`id`) | `display` | `max_context` | `supports_thinking` |
|---|---|---|---|
| `deepseek/deepseek-v4-flash` | OR: DeepSeek V4 Flash | 1_048_576 | true |
| `xiaomi/mimo-v2.5` | OR: Xiaomi MiMo-V2.5 | 1_048_576 | true |
| `minimax/minimax-m3` | OR: MiniMax M3 | 1_048_576 | true |
| `openrouter/owl-alpha` | OR: Owl Alpha (free) | 1_048_756 | false |
| `anthropic/claude-opus-4.7` | OR: Claude Opus 4.7 | 1_000_000 | true |
| `z-ai/glm-5.2` | OR: GLM 5.2 | 1_048_576 | true |
| `deepseek/deepseek-v4-pro` | OR: DeepSeek V4 Pro | 1_048_576 | true |
| `anthropic/claude-opus-4.8` | OR: Claude Opus 4.8 | 1_000_000 | true |
| `openai/gpt-5.5` | OR: GPT-5.5 | 1_050_000 | true |
| `google/gemini-2.5-pro` | OR: Gemini 2.5 Pro | 1_048_576 | true |

Slugs are unique vs existing ids (e.g. `deepseek/deepseek-v4-pro` ≠ `deepseek-v4-pro`),
so `findModel` resolves each correctly.

### Config surface
`src/config.zig` gains one `ProviderConfig` field (`openrouter`) with the default base
URL and a `forProvider` branch. No env-var fallback. No schema migration needed —
`Config` parses with `ignore_unknown_fields` and the new field defaults cleanly for
existing `config.json` files.

### Reasoning data flow
1. `client.Config` already carries `provider_name` and `effort: config_mod.Effort`.
2. In `openai.sendMessageStreaming`, compute an optional reasoning-effort string via a
   new `reasoningEffort(provider_name, supports_thinking, effort)` helper (returns `null`
   unless provider is `OpenRouter` AND the model declares `supports_thinking`, mirroring
   the Anthropic gate). `supports_thinking` comes from `providers.findModel`. Thread the
   result into `buildRequestBody`.
3. `buildRequestBody` emits `"reasoning":{"effort":"<x>"}` only when the arg is non-null.
4. `parseSseStream` reads `choices[0].delta.reasoning` (string) deltas, appends to a new
   `OpenAIStreamAccumulator.thinking` buffer, and forwards each to `on_thinking_chunk`.
5. `buildStreamedResponseJson` prepends a `{"type":"thinking","thinking":...}` content
   block when thinking text was accumulated (no `signature` — OpenRouter doesn't supply
   one). `message.zig`'s `ContentBlock` already serializes thinking blocks.

## 5. Interfaces & contracts

**OpenRouter request (built by `openai.buildRequestBody`)** — identical to OpenAI plus,
when reasoning is active:
```json
{ "model": "deepseek/deepseek-v4-flash", "stream": true,
  "stream_options": {"include_usage": true},
  "reasoning": {"effort": "high"},
  "messages": [ ... ] }
```
- Endpoint: `POST https://openrouter.ai/api/v1/chat/completions`
- Headers: `Authorization: Bearer <key>`, `accept: text/event-stream`,
  `content-type: application/json` (unchanged from OpenAI backend).
- Errors: reuse `client.statusToError` (401/403 → `ProviderAuthenticationFailed`, else
  `ProviderHttpRequestFailed`).

**Streaming response delta of interest:**
```json
{"choices":[{"delta":{"reasoning":"...partial reasoning..."}}]}
{"choices":[{"delta":{"content":"...answer..."}}]}
```

## 6. Behavior & states

- Provider not OpenRouter → `reasoningEffort` returns `null` → request body and stream
  parsing behave exactly as today (regression-safe).
- OpenRouter + `effort == .none` → no `reasoning` field sent; `delta.reasoning` is still
  parsed defensively (harmless if absent).
- OpenRouter + `supports_thinking` model + effort `low/medium/high/max` →
  `reasoning.effort` sent; `max` clamps to `high`.
- OpenRouter + non-thinking model (e.g. `owl-alpha`) → no `reasoning` field even with
  effort set, so OpenRouter won't 400 on a reasoning param it can't use.
- Reconstructed thinking block enters chat history but is dropped on the next request by
  `appendAssistantContentBlocks` (only serializes `text` + `tool_use`), so no malformed
  follow-up request.
- Idempotency / iteration loop unchanged — `stop_reason` mapping in
  `buildStreamedResponseJson` is untouched.

## 7. Implementation tasks

### Task 1 — Register the OpenRouter provider + models
- **Why:** Make OpenRouter and its curated models appear in `/provider` and `/model`.
- **Files & changes:**
  - `src/llm/providers.zig` (edit, append a new entry to the `providers` array, after the
    `Gemini` block, before the closing `};` at line 56-57):
    ```diff
         .{
             .name = "Gemini",
             .models = &[_]Model{
                 .{ .id = "gemini-2.5-pro", .display = "Gemini 2.5 Pro", .supports_thinking = true, .max_context = 1_048_576 },
                 .{ .id = "gemini-2.5-flash", .display = "Gemini 2.5 Flash", .supports_thinking = true, .max_context = 1_048_576 },
                 .{ .id = "gemini-2.5-flash-lite", .display = "Gemini 2.5 Flash Lite", .max_context = 1_048_576 },
             },
         },
    +    .{
    +        .name = "OpenRouter",
    +        .models = &[_]Model{
    +            .{ .id = "deepseek/deepseek-v4-flash", .display = "OR: DeepSeek V4 Flash", .supports_thinking = true, .max_context = 1_048_576 },
    +            .{ .id = "xiaomi/mimo-v2.5", .display = "OR: Xiaomi MiMo-V2.5", .supports_thinking = true, .max_context = 1_048_576 },
    +            .{ .id = "minimax/minimax-m3", .display = "OR: MiniMax M3", .supports_thinking = true, .max_context = 1_048_576 },
    +            .{ .id = "openrouter/owl-alpha", .display = "OR: Owl Alpha (free)", .free = true, .max_context = 1_048_756 },
    +            .{ .id = "anthropic/claude-opus-4.7", .display = "OR: Claude Opus 4.7", .supports_thinking = true, .max_context = 1_000_000 },
    +            .{ .id = "z-ai/glm-5.2", .display = "OR: GLM 5.2", .supports_thinking = true, .max_context = 1_048_576 },
    +            .{ .id = "deepseek/deepseek-v4-pro", .display = "OR: DeepSeek V4 Pro", .supports_thinking = true, .max_context = 1_048_576 },
    +            .{ .id = "anthropic/claude-opus-4.8", .display = "OR: Claude Opus 4.8", .supports_thinking = true, .max_context = 1_000_000 },
    +            .{ .id = "openai/gpt-5.5", .display = "OR: GPT-5.5", .supports_thinking = true, .max_context = 1_050_000 },
    +            .{ .id = "google/gemini-2.5-pro", .display = "OR: Gemini 2.5 Pro", .supports_thinking = true, .max_context = 1_048_576 },
    +        },
    +    },
         };
    ```
- **Depends on:** —

### Task 2 — Add OpenRouter config block
- **Why:** Persist the base URL / key / model / effort, and resolve the provider name.
- **Files & changes:**
  - `src/config.zig` (edit, `Providers` struct, lines 40-53):
    ```diff
     pub const Providers = struct {
         selected: []const u8 = "",
         anthropic: ProviderConfig = .{ .baseUrl = "https://api.anthropic.com" },
         openai: ProviderConfig = .{ .baseUrl = "https://api.openai.com" },
         deepseek: ProviderConfig = .{ .baseUrl = "https://api.deepseek.com/anthropic" },
         gemini: ProviderConfig = .{ .baseUrl = "https://generativelanguage.googleapis.com" },
    +    openrouter: ProviderConfig = .{ .baseUrl = "https://openrouter.ai/api" },

         pub fn forProvider(self: *Providers, name: []const u8) ?*ProviderConfig {
             if (std.mem.eql(u8, name, "Anthropic")) return &self.anthropic;
             if (std.mem.eql(u8, name, "OpenAI")) return &self.openai;
             if (std.mem.eql(u8, name, "DeepSeek")) return &self.deepseek;
             if (std.mem.eql(u8, name, "Gemini")) return &self.gemini;
    +        if (std.mem.eql(u8, name, "OpenRouter")) return &self.openrouter;
             return null;
         }
     };
    ```
- **Depends on:** —

### Task 3 — Route OpenRouter to the OpenAI backend
- **Why:** Dispatch OpenRouter requests through the OpenAI-compatible code path.
- **Files & changes:**
  - `src/llm/client.zig` (edit, `backendFor`, lines 73-78):
    ```diff
         const map = std.StaticStringMap(Backend).initComptime(.{
             .{ "Anthropic", .anthropic },
             .{ "OpenAI", .openai },
             .{ "DeepSeek", .anthropic }, // uses DeepSeek's Anthropic-compatible /anthropic/v1/messages
             .{ "Gemini", .gemini },
    +        .{ "OpenRouter", .openai }, // OpenAI-compatible /api/v1/chat/completions
         });
    ```
- **Depends on:** Task 1, Task 2 (so the provider/config exist when selected).

### Task 4 — OpenRouter reasoning: request param (gated)
- **Why:** Send `reasoning.effort` for OpenRouter without changing plain OpenAI requests.
- **Files & changes:**
  - `src/llm/openai.zig` (edit, imports at top, after line 4):
    ```diff
     const std = @import("std");
     const json_helpers = @import("../json_helpers.zig");
     const message = @import("message.zig");
     const client = @import("client.zig");
    +const config_mod = @import("../config.zig");
    ```
  - `src/llm/openai.zig` (new helper, add just above `buildRequestBody` at line 11):
    ```zig
    /// OpenRouter reasoning effort string, or null when reasoning must not be sent.
    /// Gated to OpenRouter so plain OpenAI requests are unchanged. `max` clamps to
    /// `high` (OpenRouter's unified reasoning API accepts low/medium/high).
    fn reasoningEffort(provider_name: []const u8, effort: config_mod.Effort) ?[]const u8 {
        if (!std.mem.eql(u8, provider_name, "OpenRouter")) return null;
        return switch (effort) {
            .none => null,
            .low => "low",
            .medium => "medium",
            .high, .max => "high",
        };
    }
    ```
  - `src/llm/openai.zig` (edit, `buildRequestBody` signature + body, lines 12-33):
    ```diff
     pub fn buildRequestBody(
         allocator: std.mem.Allocator,
         model: []const u8,
         messages: []const message.Message,
         tools: []const message.ToolDefinition,
         system_prompt: ?[]const u8,
         stream: bool,
    +    reasoning_effort: ?[]const u8,
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
    +    if (reasoning_effort) |eff| {
    +        try out.append(allocator, ',');
    +        try appendObjectFieldName(allocator, &out, "reasoning");
    +        try out.appendSlice(allocator, "{");
    +        try appendObjectFieldName(allocator, &out, "effort");
    +        try appendJsonString(allocator, &out, eff);
    +        try out.appendSlice(allocator, "}");
    +    }
    ```
  - `src/llm/openai.zig` (edit, the call site in `sendMessageStreaming`, line 247):
    ```diff
    -    const body = try buildRequestBody(allocator, self.config.model, messages, tools, system_prompt, true);
    +    const reasoning_eff = reasoningEffort(self.config.provider_name, self.config.effort);
    +    const body = try buildRequestBody(allocator, self.config.model, messages, tools, system_prompt, true, reasoning_eff);
    ```
- **Depends on:** Task 3.

### Task 5 — OpenRouter reasoning: stream parsing + thinking block
- **Why:** Surface reasoning tokens live and persist a thinking block in the response.
- **Files & changes:**
  - `src/llm/openai.zig` (edit, `OpenAIStreamAccumulator`, lines 328-347): add a thinking
    buffer and free it.
    ```diff
     const OpenAIStreamAccumulator = struct {
         allocator: std.mem.Allocator,
         id: std.ArrayList(u8) = .{},
         text: std.ArrayList(u8) = .{},
    +    thinking: std.ArrayList(u8) = .{},
         tool_calls: std.ArrayList(OpenAIToolCall) = .{},
         stop_reason: std.ArrayList(u8) = .{},
         input_tokens: u64 = 0,
         output_tokens: u64 = 0,

         fn init(allocator: std.mem.Allocator) OpenAIStreamAccumulator {
             return .{ .allocator = allocator };
         }

         fn deinit(self: *OpenAIStreamAccumulator) void {
             self.id.deinit(self.allocator);
             self.text.deinit(self.allocator);
    +        self.thinking.deinit(self.allocator);
             for (self.tool_calls.items) |*tc| tc.deinit(self.allocator);
             self.tool_calls.deinit(self.allocator);
             self.stop_reason.deinit(self.allocator);
         }
    ```
  - `src/llm/openai.zig` (edit, `sendMessageStreaming` body, lines 246 + 298): stop
    discarding `on_thinking_chunk`; pass it through.
    ```diff
    -    _ = on_thinking_chunk; // OpenAI streaming does not emit separate thinking deltas
         const reasoning_eff = reasoningEffort(self.config.provider_name, self.config.effort);
    ```
    ```diff
    -    try parseSseStream(allocator, body_reader, &oai_stream, ctx, on_chunk, should_cancel);
    +    try parseSseStream(allocator, body_reader, &oai_stream, ctx, on_chunk, on_thinking_chunk, should_cancel);
    ```
  - `src/llm/openai.zig` (edit, `parseSseStream` signature, lines 357-364): add the
    thinking callback.
    ```diff
     fn parseSseStream(
         allocator: std.mem.Allocator,
         reader: *std.Io.Reader,
         stream: *OpenAIStreamAccumulator,
         ctx: *anyopaque,
         on_chunk: *const fn (*anyopaque, []const u8) void,
    +    on_thinking_chunk: *const fn (*anyopaque, []const u8) void,
         should_cancel: client.CancelFn,
     ) !void {
    ```
  - `src/llm/openai.zig` (edit, inside the delta handling, after the text-content block at
    lines 426-431): parse `delta.reasoning`.
    ```diff
         // Text content
         if (json_helpers.getStringField(delta, "content")) |text| {
             if (text.len > 0) {
                 try stream.text.appendSlice(allocator, text);
                 on_chunk(ctx, text);
             }
         }
    +
    +    // Reasoning content (OpenRouter)
    +    if (json_helpers.getStringField(delta, "reasoning")) |think| {
    +        if (think.len > 0) {
    +            try stream.thinking.appendSlice(allocator, think);
    +            on_thinking_chunk(ctx, think);
    +        }
    +    }
    ```
  - `src/llm/openai.zig` (edit, `buildStreamedResponseJson`, lines 488-500): emit the
    thinking block first and make the text block comma-aware.
    ```diff
         var first_block = true;

    +    // Thinking block (OpenRouter reasoning); no signature available
    +    if (stream.thinking.items.len > 0) {
    +        first_block = false;
    +        try out.appendSlice(allocator, "{");
    +        try appendObjectFieldName(allocator, &out, "type");
    +        try appendJsonString(allocator, &out, "thinking");
    +        try out.append(allocator, ',');
    +        try appendObjectFieldName(allocator, &out, "thinking");
    +        try appendJsonString(allocator, &out, stream.thinking.items);
    +        try out.append(allocator, '}');
    +    }
    +
         // Text block
         if (stream.text.items.len > 0) {
    +        if (!first_block) try out.append(allocator, ',');
             first_block = false;
             try out.appendSlice(allocator, "{");
             try appendObjectFieldName(allocator, &out, "type");
             try appendJsonString(allocator, &out, "text");
             try out.append(allocator, ',');
             try appendObjectFieldName(allocator, &out, "text");
             try appendJsonString(allocator, &out, stream.text.items);
             try out.append(allocator, '}');
         }
    ```
- **Depends on:** Task 4.

## 8. Verification

- **No automated tests** (per user). `zig build` must still compile and `zig build test`
  must stay green (no new tests added, existing tests unaffected).
- **Manual acceptance:**
  1. `zig build run`
  2. `/provider` → select **OpenRouter**, paste an OpenRouter API key.
  3. `/model` → pick `OR: DeepSeek V4 Flash`.
  4. Cycle thinking effort to `high` (existing effort keybinding), send a prompt; confirm
     a streamed reply and a thinking block appears.
  5. Send a prompt with effort `off`; confirm a normal reply and that
     `~/.config/agent-zig/agent.log` shows a request body **without** a `reasoning` field.
  6. Switch back to `/provider` OpenAI, confirm its requests still contain no `reasoning`
     field (regression check via the log).

## 9. Acceptance criteria

| Criterion | How verified |
|---|---|
| OpenRouter appears in `/provider` and its 10 models in `/model`. | Manual (§8 steps 2-3). |
| Selecting an OpenRouter model + key produces a streamed completion. | Manual (§8 step 4). |
| Reasoning is sent only for OpenRouter and only when effort ≠ off; `max`→`high`. | Manual log inspection (§8 steps 4-6). |
| Plain OpenAI requests are unchanged (no `reasoning` field). | Manual log inspection (§8 step 6). |
| Existing provider behavior (Anthropic/DeepSeek/Gemini/OpenAI) unaffected. | `zig build` + `zig build test` green; manual smoke of one other provider. |

## 10. Risks & open items

- **Model slugs / context lengths drift.** Slugs were confirmed against the live
  `/api/v1/models` on 2026-06-28 but OpenRouter's catalog changes frequently. Mitigation:
  curated list is trivially editable; a wrong slug fails at request time with a clear
  provider error, not a crash.
- **No automated tests** (by decision). Regressions in the OpenRouter path — including the
  plain-OpenAI no-`reasoning` invariant and the effort mapping — are caught only by manual
  acceptance and log inspection. Accepted per user preference.
- **`delta.reasoning` shape assumption.** Implementation parses the documented string
  `delta.reasoning`. If a chosen model instead emits only structured `reasoning_details`,
  the live thinking stream would be empty (answer still works). Out of scope to handle
  both; revisit if a target model needs it.

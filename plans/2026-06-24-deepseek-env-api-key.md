# Plan: DeepSeek API Key Env Var Fallback

- **Date:** 2026-06-24
- **Domain(s):** backend
- **Author:** plan-from-spec
- **Status:** Done

## 1. Summary

Add `DEEPSEEK_API_KEY` environment variable as a **fallback** for the DeepSeek API key. When `config.json` has no DeepSeek key (empty/missing), read `DEEPSEEK_API_KEY` from the environment. Config wins when both are present.

## 2. Scope

### In scope
- `DEEPSEEK_API_KEY` env var as fallback when config has no DeepSeek API key
- `StaticStringMap` constant `apiKeyEnvVars` mapping provider name → env var name (only DeepSeek wired, trivially extensible)
- `envApiKey(provider_name)` — returns `?[]const u8` from the env, null if unmapped/unset/empty
- `resolveApiKey(api_key: *[]const u8, provider_name)` — single call-site helper that checks emptiness, calls `envApiKey`, mutates + logs in one line
- Three call sites covered: startup (`main.zig`), model-switch (`input_handler.zig`), headless print mode (`cli/print.zig`)
- Info-level log when env var fallback is used (never log the value)

### Out of scope / non-goals
- Other providers (Anthropic, OpenAI, Gemini) — add rows to `apiKeyEnvVars` when needed
- Shell-mode API key resolution
- Changing the `/provider` key-input flow

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Config vs env var priority? | Config wins. Env var is only a fallback when config key is empty/missing. |
| 2 | Apply at startup, model-switch, and headless? | Yes, all three `pc.apiKey` read sites: `main.zig`, `input_handler.zig`, `cli/print.zig`. |
| 3 | Empty env var behavior? | Treat empty string same as unset — no-op. |
| 4 | Logging? | `log.info("using {s}_API_KEY from environment", .{provider_name})` from `.config` scope. Never log the key. |
| 5 | Helper structure? | `apiKeyEnvVars` (StaticStringMap constant) + `envApiKey` (public fn) + `resolveApiKey` (public fn, the single call-site API). All in `config.zig`. |
| 6 | `/provider` explicit key set? | Writes to config.json so config then wins on next read. No special handling needed. |
| 7 | Avoid hardcoded provider strings? | Yes — `apiKeyEnvVars` is a data table, not if-else chains. |

## 4. Design

All logic lives in `src/config.zig`:

```zig
const apiKeyEnvVars = std.StaticStringMap([]const u8).initComptime(.{
    .{ "DeepSeek", "DEEPSEEK_API_KEY" },
});

pub fn envApiKey(provider_name: []const u8) ?[]const u8 { ... }

pub fn resolveApiKey(api_key: *[]const u8, provider_name: []const u8) void { ... }
```

Each of the three call sites reads `pc.apiKey` from config then calls:
```zig
agent.config.resolveApiKey(&api_key_field, found.provider.name);
```

| Site | File | What it covers |
|------|------|----------------|
| Startup | `src/main.zig:112` | Initial `llm_client_cfg` construction |
| Model switch | `src/input_handler.zig:506` | `/model` picker mid-session |
| Headless print | `src/cli/print.zig:80` | `agent -p "..."` scripting/CI |

## 5. Interfaces & contracts

`envApiKey(provider_name: []const u8) ?[]const u8`
- Returns the env var value if set and non-empty, else null
- Only `"DeepSeek"` → `DEEPSEEK_API_KEY` is wired; other names return null
- Caller never owns the returned slice (borrowed from environment)

`resolveApiKey(api_key: *[]const u8, provider_name: []const u8) void`
- If `api_key.*` is non-empty: no-op (config wins)
- Otherwise calls `envApiKey`; if it returns non-null, assigns to `api_key.*` and logs

## 6. Behavior & states

No state machine. Simple read-once-at-resolution.

Edge cases:
- `DEEPSEEK_API_KEY=""` (empty) → treated as not set → config empty → "Missing API key" error
- `DEEPSEEK_API_KEY` set, config also has key → config wins, env var ignored, no log
- Provider is not DeepSeek → `apiKeyEnvVars.get` returns null → no-op

## 7. Implementation tasks

- [x] Task 1 — Add `apiKeyEnvVars` constant and `envApiKey` public fn in `config.zig`
- [x] Task 2 — Add `resolveApiKey` public fn in `config.zig` (extracted duplicated 4-line block)
- [x] Task 3 — Wire `resolveApiKey` in `src/main.zig` startup path
- [x] Task 4 — Wire `resolveApiKey` in `src/input_handler.zig` model-switch path
- [x] Task 5 — Wire `resolveApiKey` in `src/cli/print.zig` headless path

## 8. Testing

- **Unit tests** — Skipped per user decision. `getenv` can't be mocked in Zig unit tests and the logic is thin enough.
- **Integration tests** — Manual: unset DeepSeek API key in config.json, export `DEEPSEEK_API_KEY`, verify TUI and `agent -p "..."` both use it and log the fallback.

## 9. Acceptance criteria

- With empty config key + `DEEPSEEK_API_KEY` set → TUI, model-switch, and headless mode all use the env var key and log the fallback
- With config key set + `DEEPSEEK_API_KEY` set → config key wins, no fallback log
- With empty config key + no env var → "Missing API key" error (existing behavior preserved)

## 10. Risks & open items

None.

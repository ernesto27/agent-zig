# Plan: Model Picker Shows Only Configured Providers

- **Date:** 2026-07-04
- **Domain(s):** frontend (TUI)
- **Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com)
- **Status:** Draft

## 1. Summary

The `/model` picker currently lists every model from all compile-time providers (Anthropic, OpenAI, DeepSeek, Gemini) plus the dynamically fetched OpenRouter catalog, regardless of whether the user has an API key for those providers. Change `ModelPicker.refresh` to skip any provider whose `apiKey` in `config.json` is empty, so the picker only offers models the user can actually run.

## 2. Scope

### In scope
- Filtering in `src/model_picker.zig` (`refresh`, `open`).
- A const helper `Providers.isConfigured(name)` in `src/config.zig`.
- Updating the single `model_picker.open` call site in `src/input_handler.zig`.

### Out of scope / non-goals
- `/provider` picker — still shows all providers (it is the way to configure new ones).
- OpenRouter startup fetch — unchanged; its models are only hidden in the picker.
- Env-var API keys (`envApiKey`) — deliberately NOT counted as "configured".
- Current model selection / `findModel` resolution — untouched; filtering is display-only.
- Live re-filter if a key is added while the picker is open (picker re-reads config on every `open`).

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What counts as "configured"? | Non-empty `apiKey` in `config.json` only; env-var fallback (DeepSeek) does NOT count. |
| 2 | Picker with zero configured providers? | Opens with an empty list. |
| 3 | Skip OpenRouter network fetch when unconfigured? | No — keep startup fetch as-is, filter display only. |
| 4 | Unit/integration tests? | None — per user's standing "no tests unless asked" preference. |
| 5 | How does the picker access config? | `open()` receives `*const Providers`, stored on the picker; `refresh()` signature unchanged (confirmed via read-back). |

## 4. Design

- `Providers` (in `src/config.zig`) gains `isConfigured(name)` — a `*const` lookup mirroring the existing `authenticated()` inline-for pattern, returning `apiKey.len > 0` for the named provider field.
- `ModelPicker` gains a `providers_cfg: ?*const agent.config.Providers` field, set by `open()`. It stays valid for the app lifetime: `config_store` in `main.zig` outlives the picker.
- `refresh()` consults `providers_cfg` before emitting a provider's models. Provider names in `llm/providers.zig` ("Anthropic", "OpenAI", "DeepSeek", "Gemini", "OpenRouter") match the `Providers` struct field names exactly, so name-based lookup is safe.
- If `providers_cfg` is null (never happens today — `refresh` is only reachable after `open`), the filter is bypassed and all models show, preserving old behavior as the safe fallback.

## 5. Interfaces & contracts

- `Providers.isConfigured(self: *const Providers, name: []const u8) bool` — `true` iff a `ProviderConfig` field with that exact name exists and its `apiKey` is non-empty. Unknown names → `false`.
- `ModelPicker.open(self, alloc, providers_cfg: *const agent.config.Providers) !void` — signature change; the only caller is `input_handler.zig:252`.
- `ModelPicker.refresh(self, alloc) !void` — signature unchanged (called from typing/backspace handlers in `input_handler.zig`).

## 6. Behavior & states

- `/model` with N configured providers → picker lists only their models; search/labels/selection behave as before.
- `/model` with zero configured providers → empty modal list; user escapes and uses `/provider`.
- OpenRouter models appear only when `OpenRouter.apiKey` is non-empty in `config.json`, and only after the background fetch has published (existing behavior).
- Typing/backspace re-runs `refresh`, which re-applies the same filter from the stored pointer.
- Selecting a model is unchanged (`input_handler.zig:557` path).

## 7. Implementation tasks

### Task 1 — `Providers.isConfigured` helper
- **Why:** const-safe configured check by provider name (`forProvider` needs `*Providers` and would allow mutation).
- **Files & changes:**
  - `src/config.zig` (edit, inside `Providers`, after `forProvider`):
    ```zig
    pub fn isConfigured(self: *const Providers, name: []const u8) bool {
        inline for (@typeInfo(Providers).@"struct".fields) |f| {
            if (f.type == ProviderConfig and std.mem.eql(u8, f.name, name)) {
                return @field(self, f.name).apiKey.len > 0;
            }
        }
        return false;
    }
    ```
- **Depends on:** —

### Task 2 — filter in `ModelPicker`
- **Why:** the actual feature: skip providers without a configured key.
- **Files & changes:**
  - `src/model_picker.zig` (edit, struct fields):
    ```diff
     pub const ModelPicker = struct {
         active: bool = false,
         query: std.ArrayList(u8) = .{},
         selected: usize = 0,
         results: std.ArrayList(*const Model) = .{},
         labels: std.ArrayList([]const u8) = .{},
    +    providers_cfg: ?*const agent.config.Providers = null,
    ```
  - `src/model_picker.zig` (edit, in `refresh`, static provider loop):
    ```diff
         for (&p.providers) |*prov| {
    +        if (self.providers_cfg) |cfg| {
    +            if (!cfg.isConfigured(prov.name)) continue;
    +        }
             for (prov.models) |*m| {
    ```
  - `src/model_picker.zig` (edit, in `refresh`, OpenRouter section):
    ```diff
         const or_prov = p.openrouter_store.provider();
    +    const or_configured = if (self.providers_cfg) |cfg| cfg.isConfigured(or_prov.name) else true;
    +    if (!or_configured) return;
         for (p.openrouter_store.models()) |*m| {
    ```
  - `src/model_picker.zig` (edit, `open`):
    ```diff
    -    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator) !void {
    +    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator, providers_cfg: *const agent.config.Providers) !void {
             self.active = true;
    +        self.providers_cfg = providers_cfg;
             self.query.clearRetainingCapacity();
             self.selected = 0;
             try self.refresh(alloc);
         }
    ```
- **Depends on:** Task 1

### Task 3 — pass config at the call site
- **Why:** wire the picker to the live `ConfigStore`.
- **Files & changes:**
  - `src/input_handler.zig` (edit, line 252, in the slash-command dispatch):
    ```diff
    -        .model => try ctx.model_picker.open(ctx.alloc),
    +        .model => try ctx.model_picker.open(ctx.alloc, &ctx.config.cfg.providers),
    ```
- **Depends on:** Task 2

## 8. Testing

- **Unit tests:** omitted — user's standing preference is no tests unless explicitly requested (Decision #4).
- **Integration tests:** omitted for the same reason. Manual verification instead:
  1. `zig build` compiles clean.
  2. `zig build run`, `/model` → only models of providers with a key in `~/.config/agent-zig/config.json` appear.
  3. Blank all `apiKey` values → `/model` opens empty.
  4. Type a query matching a hidden provider's model (e.g. "gemini" with no Gemini key) → no results from that provider.

## 9. Acceptance criteria

- `/model` lists a provider's models iff that provider's `apiKey` in `config.json` is non-empty.
- OpenRouter models are hidden when its key is empty, even after the startup fetch succeeds.
- With no configured providers, the picker opens with an empty list (no crash).
- Search, labels, selection, and model switching behave exactly as before for visible models.
- `zig build` and existing `zig build test` pass unchanged.

## 10. Risks & open items

- A DeepSeek user relying solely on `DEEPSEEK_API_KEY` (env var, empty `apiKey` in config) will not see DeepSeek models — accepted explicitly in Decision #1.
- Keys added via `/provider` while the app runs are picked up on the next `/model` open (config is read per-open), so no staleness risk.

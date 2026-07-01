## Context

`agent-zig` has a family of modal pickers reached via slash commands. Four of them — `/model` (`src/model_picker.zig`), `/skills` (`src/skills_picker.zig`), `/mcp` (`src/mcp_picker.zig`), and `/logout` (`src/logout_picker.zig`) — already render through a shared component, `src/modal_list.zig`. That component provides: a centered rounded modal, a bold title with a right-aligned `esc` hint, an optional search-query row (`Search...` placeholder), per-row `❯` selection cursor, bold cyan selected text, secondary text + badges, and scroll-follows-selection when items overflow.

`/provider` (`src/provider_picker.zig`) is the holdout. It hand-rolls its own `render`: no query/search row, no `❯` cursor, no scroll. It does have a second phase — `.key_input` — for entering the API key, which is a text-input modal and correctly bespoke (a search list is the wrong UX for secret entry).

The provider list is small today (the entries in `agent.llm.providers.providers`), so the missing scroll is not yet painful, but the missing selection cursor and the visual inconsistency with the model picker (which the user opens one command later) are the immediate problem. The user wants `/provider` to match `/model` in format.

Reference implementation to mirror: `ModelPicker` (`src/model_picker.zig`), which holds `query`, `results`, `labels`, `selected`, calls `refresh(alloc)` on input, and delegates rendering entirely to `modal_list.render`. Input wiring lives in `src/input_handler.zig` (`handleTextInput`, `handleBackspace`, up/down, Enter, `handleEscape`).

## Goals / Non-Goals

**Goals:**
- Make `/provider` list phase visually and behaviorally consistent with `/model`: shared `modal_list` rendering, live search/filter, visible `❯` selection cursor, scroll-follows-selection.
- Keep the `.key_input` (API key entry) phase behavior byte-for-byte unchanged.
- Keep the rest of the picker family and `modal_list.zig` untouched.
- No config, persistence, or CLI surface changes.

**Non-Goals:**
- No new fields on `modal_list.Options` (it already supports everything needed: title, query, items, selected, empty_message).
- No change to how API keys are resolved/persisted (`config.cfg.providers.forProvider(...)` path in `input_handler.zig` stays as-is).
- No change to the command picker or at-picker (those are inline autocomplete overlays, a different pattern).
- No test additions beyond `zig build test` passing (the repo has no existing picker UI tests; adding a TUI-render harness is out of scope).
- No change to `ModelPicker`/`SkillsPicker`/`McpPicker`/`LogoutPicker`.

## Decisions

### D1: Mirror `ModelPicker`'s data model exactly

**Choice:** Give `ProviderPicker` the same fields `ModelPicker` has for the list phase: `query: std.ArrayList(u8)`, `results: std.ArrayList(*const p.Provider)`, `labels: std.ArrayList([]const u8)`, plus `selected: usize` (kept). Add a `refresh(alloc)` that filters `p.providers` by case-insensitive substring of the provider name and rebuilds `results` + `labels`, resetting `selected` to 0.

**Rationale:** `ModelPicker` is the exact template the user asked to match, and it already solves filter→reset→render. Copying the proven structure minimizes risk and review surface. The only divergence is the filter key: `ModelPicker` matches against `display`, `id`, and `provider name`; `ProviderPicker` has only a `name`, so it matches against `name` only.

**Alternatives considered:**
- Filter against a provider "display" string: there is no separate display field today; `name` is the only user-facing label. Rejected as needless.
- Keep no query and just adopt the cursor/scroll visuals: rejected — the user explicitly listed "search is missing" as a defect to fix, and matching the model picker means matching its search row.

### D2: `selectedProvider()` resolves through `results`, not `p.providers`

**Choice:** `selectedProvider()` returns `self.results.items[self.selected]` (the filtered entry). This replaces the current `&p.providers[self.selected]`.

**Rationale:** Once filtering exists, `selected` is an index into the filtered set; indexing the original array would desync the cursor from the highlighted row whenever a query is active. The spec's "resolves from the filtered set" requirement mandates this.

**Alternatives considered:**
- Store a `*const Provider` directly instead of an index: would work but diverges from `ModelPicker` (which keeps `selected: usize` + `results`), hurting consistency. Rejected.

### D3: Keep `.key_input` render bespoke; only `list` phase uses `modal_list`

**Choice:** The `render` switch stays two-armed. The `.list` arm builds a `modal_list.Item` array (primary = provider name, no badge/secondary) and calls `modal_list.render`. The `.key_input` arm keeps its current hand-drawn modal verbatim.

**Rationale:** `modal_list` is a list widget; a single text field with a placeholder and save/cancel hint is not a list. Forcing the key phase through `modal_list` (e.g. by abusing a one-item list) would be a regression in clarity. The user's complaint is about the list phase specifically ("provider picker looks different... arrow selected is not show").

**Alternatives considered:**
- Route key_input through `modal_list` with a single fake item: rejected — misleading and loses the placeholder/cursor UX.

### D4: `open()` takes an allocator and `reset()` takes one, matching `ModelPicker`

**Choice:** Change `ProviderPicker.open` to `open(self, alloc)` (call `refresh`), and `reset` to `reset(self, alloc)` (free query/labels/results), mirroring `ModelPicker.open`/`reset`. Update the two call sites: `runSlashCommand` (`.provider => try ctx.provider_picker.open(ctx.alloc)`) and `handleEscape`/Enter paths (`ctx.provider_picker.reset(ctx.alloc)`).

**Rationale:** `ModelPicker` requires an allocator on open/reset because it owns heap `ArrayList`s. Adopting the same fields means adopting the same lifecycle. `input_handler.zig` already has `ctx.alloc` available at every call site.

**Alternatives considered:**
- Lazily allocate / keep `open()` allocator-free by deferring `refresh`: rejected — `ModelPicker` calls `refresh` in `open` so the list is populated before first render, and matching that avoids an empty-first-frame edge case.

### D5: `moveUp`/`moveDown` operate on `results.len`, gated on `.list` phase

**Choice:** `moveUp`/`moveDown` clamp to `self.results.items.len` and only act in `.list` phase (unchanged guard). They no longer reference `p.providers.len`.

**Rationale:** Direct consequence of D2 — selection lives in the filtered set. The existing `.list`-phase guard already prevents navigation from clobbering the key phase.

## Risks / Trade-offs

- **[Filtering can empty the list, blocking Enter-to-key-entry]** → Mitigation: `modal_list` already renders an `empty_message` for zero items, and the Enter handler must guard `self.results.items.len > 0` before reading `results[selected]` (mirror `ModelPicker`'s `if (ctx.model_picker.results.items.len > 0)` guard). The `selectedProvider()` accessor should only be called after that guard.
- **[Allocator lifecycle mismatch if a call site forgets to pass alloc]** → Mitigation: D4 makes `open`/`reset` signatures match `ModelPicker`, so any missed site is a compile error, not a leak.
- **[Selected index stale after filter shrinks below it]** → Mitigation: `refresh` resets `selected = 0` on every filter change (same as `ModelPicker`), so the index is always valid for the current result set.
- **[No automated test for the new render]** → Accepted: the repo has no TUI-render test harness; verification is `zig build test` (compiles + existing tests) and manual `zig build run` of `/provider`. Adding a render-harness is an explicit non-goal.

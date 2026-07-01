## Why

The `/provider` picker is the only modal selector still using a hand-rolled, bespoke render. It diverges from the other pickers (`/model`, `/skills`, `/mcp`, `/logout`) which all share `src/modal_list.zig`. Concretely the provider picker is missing the live search/filter input, has no visible selection cursor (no `❯` arrow), and does not scroll. As the number of configured providers grows this is inconsistent and harder to use than the model picker the user reaches for one keystroke later.

## What Changes

- Convert the provider picker's **list phase** to render through the shared `src/modal_list.zig` component, matching the model picker format: centered rounded modal, title row with `esc` hint, a search/filter query row (`Search...` placeholder), per-row `❯` selection cursor, bold cyan selected text, and scroll when results exceed the visible area.
- Add a live `query` to `ProviderPicker` with a `refresh(alloc)` step that filters `p.providers` by name (case-insensitive substring), mirroring `ModelPicker.refresh`.
- Wire text input, backspace, up/down, enter, and escape in `src/input_handler.zig` for the provider picker's **list phase** to update the query and refresh results — keeping the existing **key_input phase** (API key entry) behavior unchanged.
- Keep `selectedProvider()` meaningful: after filtering, the selected index maps into the filtered result set; the API-key phase and the eventual save continue to resolve the chosen provider by the selected entry.
- No change to the model picker, skills picker, mcp picker, logout picker, command picker, or `modal_list.zig` itself.
- No change to `config.json` shape or to how API keys are persisted.

## Capabilities

### New Capabilities
- `provider-picker`: The `/provider` modal selector UI — list rendering, search/filter, selection, and phase flow (list → key entry).

### Modified Capabilities
<!-- None. No existing spec covers picker UI behavior. -->

## Impact

- `src/provider_picker.zig`: primary change — adopt `modal_list`, add `query`/`results`/`labels`/`refresh`, rework `render` (list phase), `open`, `reset`, `moveUp`/`moveDown`, `selectedProvider`. `.key_input` phase render stays custom.
- `src/input_handler.zig`: add provider-picker list-phase handling for text input (append to `query` + `refresh`), backspace (remove + `refresh`), and ensure up/down/enter/escape route to the filtered set. Existing key_input-phase handling preserved.
- `src/App.zig`: only the render call site (no structural change expected; `render` signature is unchanged).
- No new dependencies, no config changes, no CLI changes, no release-build impact.

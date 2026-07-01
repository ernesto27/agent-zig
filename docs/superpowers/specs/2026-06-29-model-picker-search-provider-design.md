# Model Picker: Search by Provider Name

## Goal

Extend the model picker's search so typing a provider name (e.g. "anthropic", "openrouter") surfaces that provider's models, in addition to the existing matches on model `display` name and `id`.

## Context

`src/model_picker.zig` `ModelPicker.refresh()` builds the filtered result list shown in the "Select model" modal. Currently the query is matched case-insensitively against:

- `m.display` (human-readable model name, e.g. "Claude Opus 4.6")
- `m.id` (API model id, e.g. "claude-opus-4-6")

The provider name is already rendered in each row's label (lowercased, in brackets: `"<id> [<provider>]"`) but is not part of the match. Provider names come from `Provider.name` (`src/llm/providers.zig`); there are no aliases.

## Design

Add a third `or` clause to the `matches` expression in `refresh()`:

```zig
const matches = q.len == 0 or
    std.ascii.indexOfIgnoreCase(m.display, q) != null or
    std.ascii.indexOfIgnoreCase(m.id, q) != null or
    std.ascii.indexOfIgnoreCase(prov.name, q) != null;
```

`prov` is already the loop variable in scope (`for (&p.providers) |*prov|`), so no other wiring is needed.

## Behavior

- Empty query: all models shown (unchanged).
- Query "anthropic": all Anthropic models shown.
- Query "free": no special handling — only matches if "free" appears in a name/id/provider (unchanged semantics).

## Non-goals

- No new searchable fields (flags, aliases, context-window ranges).
- No UI/label changes.
- No changes to `provider_picker.zig`.

## Testing

Manual: run `zig build run`, open model picker (e.g. via `/model`), type a provider name, confirm that provider's models appear. Then `zig build test` to confirm compilation/library tests still pass.

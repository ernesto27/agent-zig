## 1. Provider picker data model (list phase)

- [x] 1.1 In `src/provider_picker.zig`, add fields mirroring `ModelPicker`: `query: std.ArrayList(u8)`, `results: std.ArrayList(*const p.Provider)`, `labels: std.ArrayList([]const u8)` (keep `active`, `selected`, `phase`, `key_input`).
- [x] 1.2 Add `clearLabels(alloc)` and `buildLabel(alloc, name)` helpers mirroring `ModelPicker`'s label helpers (provider list items have no id, so the label is just the provider name; reuse the same allocation/free pattern).
- [x] 1.3 Add `refresh(alloc)` that clears labels/results, resets `selected = 0`, and pushes every provider whose `name` case-insensitively contains `query.items` (empty query matches all) into `results` and a matching label into `labels`.
- [x] 1.4 Change `selectedProvider()` to return `self.results.items[self.selected]` (filtered-set lookup) instead of `&p.providers[self.selected]`.
- [x] 1.5 Change `moveUp`/`moveDown` to clamp against `self.results.items.len` (still gated on `.list` phase).

## 2. Provider picker lifecycle signatures

- [x] 2.1 Change `open()` to `open(self, alloc)` that sets `active=true`, `selected=0`, `phase=.list`, clears `query`, and calls `refresh(alloc)`.
- [x] 2.2 Change `reset()` to `reset(self, alloc)` that clears `query`, frees labels (via `clearLabels`), clears `results`, and resets `active`/`selected`/`phase`. Update `deinit` to free `query`/`labels`/`results` like `ModelPicker.deinit`.

## 3. Provider picker render (list phase via modal_list)

- [x] 3.1 In `render`, replace the `.list` arm's hand-drawn modal with a `modal_list.render` call: build a stack `modal_list.Item` array from `self.results`/`self.labels` (primary = label, no badge/secondary), pass `.title = " Select provider"`, `.query = self.query.items`, `.items`, `.selected`, `.max_width`/`.max_height` matching the model picker (e.g. 60/20).
- [x] 3.2 Leave the `.key_input` arm of `render` byte-for-byte unchanged.

## 4. Input handler wiring (list phase)

- [x] 4.1 In `runSlashCommand`, update `.provider` to `try ctx.provider_picker.open(ctx.alloc)`.
- [x] 4.2 In `handleEscape`, change `ctx.provider_picker.reset()` to `ctx.provider_picker.reset(ctx.alloc)` (both list and key_input phases close).
- [x] 4.3 In `handleBackspace`, add a provider-picker **list-phase** branch (before the key_input branch or alongside it): when `phase == .list` and `query` non-empty, remove last char and call `refresh(alloc)`. Keep the existing key_input backspace branch unchanged.
- [x] 4.4 In `handleTextInput`, add a provider-picker **list-phase** branch: when `phase == .list`, append `txt` to `query` and call `refresh(alloc)`. Keep the existing key_input text branch unchanged.
- [x] 4.5 Confirm the Enter handler (`provider_picker.active and phase == .list`) guards `self.results.items.len > 0` before calling `selectedProvider()` / transitioning to `.key_input`, mirroring the `ModelPicker` guard. Keep key_input Enter (save) behavior unchanged.

## 5. Verification

- [x] 5.1 Run `zig build` and confirm the app compiles cleanly.
- [x] 5.2 Run `zig build test` and confirm both the library module (`src/root.zig`) and app module (`src/main.zig`) test executables pass.
- [ ] 5.3 Manually run `zig build run`, open `/provider`, and confirm: search filters by name, `❯` cursor + bold cyan selected row, scroll on overflow, Enter opens key entry, escape cancels from both phases, and a saved key persists.

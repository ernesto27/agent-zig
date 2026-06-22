# Plan: Folder Trust Prompt

- **Date:** 2026-06-22
- **Domain(s):** frontend (TUI) + config/persistence
- **Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com
- **Status:** Implemented 

## 1. Summary
Before the TUI becomes interactive, gate the session on folder trust. On startup we
canonicalize the current working directory and check it against a persisted whitelist
in `config.json` (`trustedFolders`). If the folder is already trusted, the TUI opens as
normal. If not, a blocking modal — styled like the existing provider/model pickers —
presents two options: **Yes - trust folder** (persist the folder and continue) or
**No - untrust folder** (exit the app without persisting). This is a one-time-per-folder
security gate analogous.

## 2. Scope
### In scope
- New top-level config field `trustedFolders: []const TrustedFolder`, where
  `TrustedFolder = struct { path: []const u8 = "" }` (mirrors the `SessionEntry` pattern;
  canonical absolute paths).
- A `ConfigStore.addTrustedFolder(path)` mutation that appends + persists (mirrors `createSession`).
- A pure helper `isTrusted(folders, cwd) bool` (exact-match semantics).
- A new `TrustDialog` modal struct (own file `src/trust_dialog.zig`), owned by `main()`,
  with `active`, a two-item selection, `render()`, and navigation state.
- Startup wiring in `main.zig`: canonicalize cwd, check whitelist, conditionally activate
  the dialog.
- Input routing in `input_handler.zig`: the dialog is checked **first** and captures
  ↑/↓/Enter while active; it has no Escape-to-dismiss; Enter on "Yes" persists+closes,
  Enter on "No" signals quit.
- Render wiring in `main.zig` so the dialog paints over the (empty) frame, like other pickers.

### Out of scope / non-goals
- Subfolder/descendant trust inheritance (explicitly decided: exact match only).
- Per-folder trust metadata / timestamps (explicitly decided: plain path array).
- Any change to plan/build mode behavior (the "No" path exits; it does not enter a
  restricted mode).
- Tests (decided: omitted per standing preference; see Risks).

## 3. Resolved decisions
| # | Question | Decision |
|---|----------|----------|
| 1 | What does "No - untrust folder" do? | **Exit the app** cleanly (exit code 0), folder NOT persisted. |
| 2 | Unit of trust / matching semantics? | **Exact folder only.** Subdirectories re-prompt. |
| 3 | How is the whitelist stored in config.json? | **Top-level `trustedFolders` array** of `TrustedFolder { path }` structs (mirrors `SessionEntry`), canonical absolute paths. |
| 4 | Tests for matching logic? | **No tests** — honor standing no-tests preference; noted in Risks. |
| 5 | Which folder is the unit of trust? | The **current working directory** (`getcwd`), canonicalized via realpath. |
| 6 | Where does the dialog live / render? | A modal inside the vaxis event loop (only place modals render), so even the "No → exit" path briefly enters the TUI to show the modal, then quits. |
| 7 | Can the dialog be dismissed without choosing? | **No.** No Escape path; Ctrl+C / Ctrl+Q still terminate the process (same as a "No"). |

## 4. Design

### Config (`src/config.zig`)
- Add a named struct (alongside `SessionEntry`):
  ```zig
  pub const TrustedFolder = struct {
      path: []const u8 = "",
  };
  ```
- Add to `Config`:
  ```zig
  trustedFolders: []const TrustedFolder = &.{},
  ```
  Placed alongside `sessions`. JSON shape:
  ```json
  { "providers": {…}, "sessions": […], "trustedFolders": [{ "path": "/home/me/proj" }] }
  ```
- Add `ConfigStore.addTrustedFolder(self, path: []const u8) !void`, modeled on
  `createSession`: allocate a new `[]const TrustedFolder` of `len + 1` in `self.arena`,
  copy existing entries, dupe the new canonical `path` into a `TrustedFolder`, write a
  temp `Config` snapshot, then commit `self.cfg.trustedFolders = folders`. Reuses the
  existing arena/`write` pattern so no allocator threading at the call site.
- Add a pure free function:
  ```zig
  pub fn isTrusted(folders: []const TrustedFolder, cwd: []const u8) bool {
      for (folders) |f| if (std.mem.eql(u8, f.path, cwd)) return true;
      return false;
  }
  ```
  (Exact match. `cwd` is expected pre-canonicalized by the caller so both sides are
  realpath-normalized.)

### Trust dialog (`src/trust_dialog.zig`)
Mirror `ProviderPicker`'s structure and palette (teal `0x9C,0xE3,0xEE` for selected,
grey for unselected, white bold title; centered `win.child` with `single_rounded`
border; full background fill).

```zig
pub const Choice = enum { yes, no };

pub const TrustDialog = struct {
    active: bool = false,
    selected: Choice = .yes,          // default highlight on "Yes"
    cwd: []const u8 = "",             // borrowed; canonical path to display

    pub fn open(self: *TrustDialog, cwd: []const u8) void { … }
    pub fn moveUp/moveDown(self: *TrustDialog) void { toggles selected }
    pub fn render(self: *const TrustDialog, win, screen_w, screen_h) void { … }
};
```
- Modal width `min(60, screen_w - 4)`, height 8 rows.
- Row 0: title ` Do you trust in this folder?`
- Row 2: the canonical `cwd` (truncated with `agent.utils.truncate` to modal width).
- Option rows 4 & 5: `Yes - trust folder`, `No  - untrust folder` (the "No" is padded
  with a second space so the `-` separators line up). Labels print at a **fixed**
  `col_offset = 4`; the `❯` marker is drawn independently at `col_offset = 2` only on the
  selected row, so the marker never shifts the label column (don't rely on the
  `printSegment` returned `col`, which differs between the marker glyph and a space).
- Footer row 7: `↑↓ select   Enter confirm`.
- No allocations needed inside the struct (no query/key input), so `deinit` is omitted.

### Startup wiring (`src/main.zig`)
After `config_store` is loaded and before/at the start of the event loop:
1. `var trust_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;`
   `const trust_cwd: ?[]const u8 = std.fs.realpath(".", &trust_cwd_buf) catch std.posix.getcwd(&trust_cwd_buf) catch null;`
   — the buffer is `main`-scoped so the borrowed slice outlives every `render` (vaxis
   deferred-text rule). On total failure `trust_cwd` is **`null`**, not `""`.
2. `var trust_dialog = trust_dialog_mod.TrustDialog.init();`
3. `if (trust_cwd) |cwd| { if (!agent.config.isTrusted(config_store.cfg.trustedFolders, cwd)) trust_dialog.open(cwd); }`
   — when the cwd can't be resolved the dialog is **not** opened and the TUI starts
   normally (fail-open); this also prevents a bogus `""` entry from being persisted or
   false-matched.
4. Pass `&trust_dialog` into `InputContext`.
5. In the render section, add (near the other picker render calls):
   ```zig
   if (trust_dialog.active) trust_dialog.render(win, vx.screen.width, vx.screen.height);
   ```

> **vaxis deferred-text note** ([[feedback_vaxis_deferred_text]]): the `cwd` slice passed
> to `render`/`printSegment` must outlive `vx.render(tty.writer())`. Keep the canonical
> cwd in a buffer/allocation owned by `main()` for the whole run, not a per-iteration temp.

### Input routing (`src/input_handler.zig`)
- Add `trust_dialog: *trust_dialog_mod.TrustDialog` to `InputContext`.
- At the very top of `handleKey`, before all other branches, add a guard:
  ```zig
  if (ctx.trust_dialog.active) return handleTrustDialogKey(ctx, key);
  ```
  `handleTrustDialogKey`:
  - ↑/↓ → `moveUp`/`moveDown`, set `needs_redraw`.
  - Enter → if `.yes`: `ctx.config.addTrustedFolder(cwd)` (log on error), then
    `ctx.trust_dialog.active = false`, `needs_redraw = true`, return `false`.
    If `.no`: return `true` (quit).
  - Ctrl+C / Ctrl+Q → return `true` (quit) — treated like "No".
  - Everything else → ignored (no text input, no Escape dismiss).
- Because this guard returns early, no other modal/input branch can run while the dialog
  is active, satisfying "block the TUI until answered" without touching the existing
  priority chain.

## 5. Interfaces & contracts
- `config.isTrusted(folders: []const TrustedFolder, cwd: []const u8) bool` — pure; true iff
  an exact string-equal `path` entry exists.
- `ConfigStore.addTrustedFolder(path: []const u8) !void` — appends a duped canonical
  `path` and persists config.json; errors propagate (caller logs, does not block startup
  fatally — a persist failure still lets the session continue this run).
- `TrustDialog.open(cwd: []const u8) void` / `render(win, w, h) void` /
  `moveUp/moveDown()` — UI-only, no I/O.
- Startup contract: dialog is shown **iff** the canonical cwd is not already an exact
  entry in `trustedFolders`.

## 6. Behavior & states
States: `active = false` (normal TUI) ↔ `active = true` (modal captures input).

Transitions:
- App start, cwd trusted → `active = false` → TUI interactive immediately.
- App start, cwd not trusted → `active = true`, `selected = .yes`.
- ↑/↓ → toggles `selected` between `.yes` and `.no`.
- Enter on `.yes` → persist (best-effort) → `active = false` → TUI interactive.
- Enter on `.no` → quit (running = false).
- Ctrl+C / Ctrl+Q while active → quit.
Edge cases:
- `realpath(".")` fails → fall back to `getcwd`; if **both** fail, `trust_cwd` is `null`
  and the dialog is **skipped** (fail-open, TUI starts normally). Chosen so a session is
  never blocked by an undeterminable cwd, and so no empty path is ever stored/matched.
- Trailing-slash / symlink differences are normalized by realpath, so matching is stable.
- Duplicate "Yes" cannot happen (folder is whitelisted, so the dialog won't reopen).
- `addTrustedFolder` persist failure → log error, still set `active = false` and continue
  (folder will re-prompt next launch — acceptable, fail-safe toward re-asking).

## 7. Implementation tasks
- [ ] **Task 1 — Config field + matcher.** Add `trustedFolders` to `Config` in
      `src/config.zig`; add the pure `isTrusted` free function.
- [ ] **Task 2 — Config mutation.** Add `ConfigStore.addTrustedFolder` (model on
      `createSession`: arena alloc, copy, dupe, snapshot-write, commit).
- [ ] **Task 3 — TrustDialog struct.** Create `src/trust_dialog.zig` with `Choice`,
      `active`/`selected`/`cwd`, `open`, `moveUp`/`moveDown`, `render` (palette and layout
      copied from `provider_picker.zig`).
- [ ] **Task 4 — Startup wiring.** In `src/main.zig`: canonicalize cwd into a long-lived
      buffer, construct `TrustDialog`, activate when not trusted, add the render call, pass
      it into `InputContext`.
- [ ] **Task 5 — Input routing.** In `src/input_handler.zig`: add the field to
      `InputContext`, add the early-return guard at the top of `handleKey`, implement
      `handleTrustDialogKey` (nav, Yes-persist, No/Ctrl-quit).
- [ ] **Task 6 — Verify.** `zig build` then `zig build run` in (a) a fresh folder → dialog
      appears; "Yes" persists and re-launch skips it; (b) a known-trusted folder → no
      dialog; (c) "No" → process exits.

## 8. Testing
- **Unit tests:** none. The pure `isTrusted` matcher is the natural unit-test target
  (exact match true, subfolder false, sibling false, empty list false), but tests are
  **deliberately omitted** per the user's standing no-tests-unless-asked preference
  ([[feedback_no_tests]]).
- **Integration tests:** none (same rationale; the TUI modal flow is verified manually
  in Task 6).
- Justification recorded in §10.

## 9. Acceptance criteria
1. Launching in a folder absent from `trustedFolders` shows the trust modal before any
   normal interaction is possible. — *verified manually (Task 6a).*
2. Selecting **Yes** writes the canonical cwd into `config.json` `trustedFolders` and
   opens the TUI; relaunching in the same folder shows no prompt. — *Task 6a.*
3. Selecting **No** exits the process without modifying `config.json`. — *Task 6c.*
4. Launching in an already-trusted folder opens the TUI directly with no prompt. — *Task 6b.*
5. Matching is exact: a subdirectory of a trusted folder still prompts. — *Task 6 (extra).*
6. The dialog cannot be dismissed without choosing (no Escape); ↑/↓ + Enter navigate it.
7. `zig build` and `zig build test` pass (existing suite unaffected).

## 10. Risks & open items
- **Matching logic untested.** `isTrusted` ships without an automated test, per standing
  preference. Low risk: the function is a trivial exact-string loop, exercised manually
  in Task 6.
- **"No → exit" still enters the alt-screen briefly** because modals only render inside
  the vaxis loop. Accepted as the only path that reuses the picker rendering; the user
  sees the modal, picks No, and the screen restores on exit (alt-screen is exited in the
  existing `defer`).
- **Persist-failure fallback re-prompts.** If `addTrustedFolder` fails to write, the
  folder isn't saved and re-prompts next launch. Chosen as fail-safe (re-ask) rather than
  fail-open (auto-trust).

# Fix: lag while selecting text in the TUI

## Context

Dragging the mouse to **select** text in the chat area is sluggish — the highlight
trails the cursor. The lag is during the drag itself, not when copying.

Root cause: on every mouse event during a drag, the chat is fully re-laid-out
**twice per event**:

1. `src/main.zig` mouse handler (`mouse.button == .left`, ~line 243) calls
   `chat_selection.buildRenderedLines(...)` over the *entire* conversation, only to
   read two fields per line (`display_cols`, `start_col`) for hit-testing — the
   expensive `.text`/`.entry` data it builds is never used during a drag.
2. The redraw block (~line 388) then calls `buildRenderedLines(...)` again for the
   actual frame.

`buildRenderedLines` (`src/chat_selection.zig:208`) iterates all messages and
**word-wraps every line** (`wrapStyledLine`/`wrapText` + `displayWidth`, which walk
graphemes). Markdown *parsing* is already cached per-message
(`src/messages.zig:15`, keyed on `content.len`), but the **wrapping is not** — it is
redone from scratch on every call. Mouse-move events fire many times per second, so
on a long conversation each drag pixel triggers two full re-wraps → visible lag.

Nothing about the chat content changes during a drag, so this work is pure waste.

## Approach: cache the wrapped chat lines, invalidate on real changes

Add a render cache that stores the output of `buildRenderedLines` and reuses it
whenever the inputs that affect it are unchanged (chat width, width method, the
"show thinking" setting, and a cheap per-frame signature over the messages). A drag
changes none of these, so every drag event becomes a cache hit and skips the
re-wrap entirely. This also speeds up all other redraws (streaming-adjacent frames,
status updates, etc.).

The cache owns a dedicated `ArenaAllocator` so invalidation is a single
`arena.reset(.retain_capacity)` — no per-field frees (the rendered lines hold many
allocated slices). The per-message markdown-parse cache (`styled_lines`) is
unaffected; it lives on `App.alloc` and keeps working as-is.

### Changes

**1. `src/chat_selection.zig` — add the cache type, signature, and wrapper**

- Define a cache struct (owned by `App`):
  ```zig
  pub const ChatRenderCache = struct {
      arena: std.heap.ArenaAllocator,
      lines: ?[]RenderedLine = null,
      width: u16 = 0,
      width_method: WidthMethod = undefined,
      show_thinking: bool = false,
      signature: u64 = 0,
      valid: bool = false,
  };
  ```
- Add `pub fn renderedLinesCached(app: *App, chat_width: u16, width_method: WidthMethod) ![]RenderedLine`:
  - compute `sig = chatSignature(app)` and read
    `app.config_store.cfg.settings.showThinkingBlock`;
  - if `valid` and all of {width, width_method, show_thinking, signature} match,
    return `cache.lines.?`;
  - otherwise `_ = cache.arena.reset(.retain_capacity);`, call the existing
    `buildRenderedLines(app, cache.arena.allocator(), chat_width, width_method)`,
    store results + key, set `valid = true`, return.
- Add `fn chatSignature(app: *App) u64`: fold over `app.messages.view()` mixing
  `messages.count()`, and per message `content.len`, `thinking.?.len` (0 if null),
  and `@intFromEnum(role)`. This mirrors the existing `content.len`-based cache key,
  so it inherits the same (already-accepted) invalidation guarantees: content only
  grows via streaming or is replaced wholesale (clear/resume/fork/compact change
  count or lengths). Cheap: O(num messages), no wrapping.

`buildRenderedLines` itself is unchanged (still the builder; the cache wraps it).

**2. `src/App.zig` — own the cache lifecycle**

- Add field to the `App` struct (near `messages`):
  `chat_render_cache: chat_selection.ChatRenderCache,`
  and `const chat_selection = @import("chat_selection.zig");` at the top. (Zig
  permits the mutual import — `chat_selection.zig` already imports `App.zig`.)
- In `App.init`, initialize it:
  `.chat_render_cache = .{ .arena = std.heap.ArenaAllocator.init(alloc) }`.
  Safe to return by value: the arena holds no allocations yet, and
  `arena.allocator()` is only obtained later (inside `renderedLinesCached`), once
  `app` is at its final address.
- In `App.deinit`, add `self.chat_render_cache.arena.deinit();`.

**3. `src/main.zig` — call the cached wrapper at both sites**

- Both sites pass `chat_win.width` (the **interior** width) as the cache key, not
  the full screen width. `vx.window().child(.{ .border = .{ .where = .all } })` insets
  by the border, so `chat_win.width == vx.screen.width - 2`; passing the full screen
  width would wrap 2 columns too wide and silently clip styled body lines (they
  render with `.wrap = .none`).
- Mouse handler: move the `chat_win` construction above the cache call (it only needs
  `vx` + the already-computed `layout`), then call
  `chat_selection.renderedLinesCached(&app, chat_win.width, vx.screen.width_method)`.
- Redraw block (~line 388): `chat_selection.renderedLinesCached(&app, chat_win.width, vx.screen.width_method)`.
  Both sites now pass the identical interior width, so they share one cache entry —
  and this also fixes a latent bug where the drag hit-test (previously full screen
  width) didn't match the displayed layout (interior width) near the right edge.

Both sites already run under `app.mutex`, and the cache is only touched on the main
thread, so no new locking is required. The `mouse_arena`/`frame_arena` are still
used for everything else; only the rendered-lines allocation moves into the cache
arena.

### Optional (smaller, same spirit) — not required for the fix

`buildInputLayout` (O(input.len)) and `layout_mod.compute` (O(1)) are also computed
in both the mouse handler and the redraw. These are far cheaper than the chat
re-wrap; leave them unless profiling shows they matter.

## Verification

- `zig build` then `zig build test` (both library and app test executables).
- `zig build run`, then with a **long** conversation loaded (e.g. `/resume` a big
  session or paste a long reply): click-drag across many lines of chat output and
  confirm the selection highlight now tracks the cursor smoothly with no lag.
- Confirm correctness is preserved:
  - selection highlight maps to the right characters; copy-on-release still yields
    the correct text;
  - streaming a new assistant reply still updates the chat live (signature changes
    as `content.len` grows → cache rebuilds);
  - resizing the terminal re-wraps correctly (width key changes);
  - toggling the thinking block reflows correctly (show_thinking key changes);
  - `/clear`, `/resume`, `/fork`, `/compact` all render the new conversation
    (count/lengths change).
- Sanity-check for leaks under the app test build (cache arena is freed in
  `App.deinit`).

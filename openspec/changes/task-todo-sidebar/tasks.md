## 1. Task store (data model)

- [x] 1.1 Create `src/tasks.zig` with a `Status` enum (`pending`, `in_progress`, `completed`) and a `Task` struct (`id`, `content`, `status`)
- [x] 1.2 Implement `TaskStore` owning an arena plus an ordered `ArrayList(Task)`; add `init`/`deinit`
- [x] 1.3 Implement `apply(items)` that resets the arena, dupes `id`/`content` into it, replaces the list, and enforces the single-`in_progress` invariant (keep only the last in_progress, coerce earlier ones to pending)
- [x] 1.4 Add a `snapshot(frame_allocator)` (or read-under-lock helper) that copies the list for rendering without holding the lock during render
- [x] 1.5 Add a `summary()` returning completed/total counts for the header line

## 2. task_write tool

- [x] 2.1 Add a `?*TaskStore` field to `tools.Context` (`src/tools.zig:16`) and a mutex handle for guarding it
- [x] 2.2 Add the `task_write` schema JSON (array `tasks` of `{id, content, status}`) and register a `ToolSpec` in `tool_specs` (`src/tools.zig:229`)
- [x] 2.3 Add the `task_write` branch to `execute` (`src/tools.zig:329`): validate input (missing `tasks`, missing `id`/`content`, bad `status` → error result, no mutation), then `apply` under the lock
- [x] 2.4 Return a confirmation string summarizing counts by status; return `is_error` on invalid input
- [x] 2.5 Allow `task_write` in plan mode in `isToolAllowed` (treat as side-effect-free, like read-only/skill tools)

## 3. App wiring

- [x] 3.1 Add a `TaskStore` field (and its mutex) to `App` (`src/App.zig`); `init`/`deinit` it
- [x] 3.2 Wire the store + mutex into `tools.Context` wherever the context is constructed
- [x] 3.3 Reset the task store on `/clear` alongside the existing conversation reset

## 4. Layout (horizontal split)

- [x] 4.1 Add `sidebar_w` to `Layout` and compute it in `layout.compute` (`src/layout.zig:21`): fixed width when visible-and-fits, else 0; add named consts for sidebar width and min chat width (no magic numbers)
- [x] 4.2 Define visibility as `list_non_empty AND user_pref_visible AND fits`; pass the needed inputs (task count, pref, screen width) into `compute`
- [x] 4.3 Reduce the chat window width by `sidebar_w` in the draw path and in the mouse-selection rectangle (`src/main.zig` near :328) so selection math uses the reduced chat width

## 5. Sidebar renderer

- [x] 5.1 Add a sidebar render function that draws a bordered child window at `x_off = screen_width - sidebar_w`, spanning the chat row height
- [x] 5.2 Render a header line with completed/total from `summary()`
- [x] 5.3 Render one row per task: status glyph (`○`/`◐`/`✔`) + content, truncated to column width without wrapping
- [x] 5.4 Guard against deferred-text lifetime: header allocated in the frame arena; task strings are stable under the App mutex held across `vx.render`
- [x] 5.5 Call the renderer from the main draw path only when `sidebar_w > 0`

## 6. Visibility (inferred, no command)

- [x] 6.1 Sidebar visibility is inferred solely from the task list being non-empty (plus the narrow-terminal fits check); no `/tasks` command and no persisted preference

## 7. Session lifetime (in-memory only)

- [x] 7.1 Task list is in-memory for the current session only — not written to the session log and not restored on resume/fork; `/clear` empties it (handled in group 3)

## 8. Verification

- [x] 8.1 Model guidance lives in the `task_write` tool description (send the full list, one in_progress, mark completed); system prompt files left untouched
- [ ] 8.2 `zig build` and `zig build run`; drive a multi-step request and confirm the sidebar shows tasks with correct glyphs, auto-shows/hides, and collapses on a narrow terminal
- [ ] 8.3 Verify `/clear` empties the list; confirm the list is in-memory only (not written to the session log)

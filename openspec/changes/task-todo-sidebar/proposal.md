## Why

On multi-step work the agent's plan is invisible: intermediate steps live only in the scrolling chat transcript, so the user cannot see at a glance what the agent intends to do, what it is doing now, and what remains. A structured task list the model maintains and the TUI renders in a persistent panel gives long agentic loops visible progress and keeps the model honest about scope. This is a self-contained, high-perceived-value feature that reuses the existing tool registry, `Context` plumbing, session persistence, and layout system.

## What Changes

- Add a built-in `task_write` tool that lets the model create and update a flat, ordered task list for the current session. It replaces/patches items by id and sets each item's status (`pending` / `in_progress` / `completed`). One tool that overwrites the whole list is simpler and race-free versus per-item mutation calls.
- Add a session-scoped, mutex-protected task store on `App`, populated by the tool on the worker thread and read by the render thread. Exactly one task may be `in_progress` at a time (the store enforces this).
- Render a task sidebar: a right-hand panel beside the chat window showing each task with a status glyph (`○` pending, `◐` in_progress, `✔` completed) and a summary counter. The panel auto-shows when the list is non-empty and hides when empty.
- Introduce the first horizontal split in the layout: reserve a sidebar column of the chat row and shrink the chat window width accordingly, with a minimum-width fallback that hides the sidebar on narrow terminals.
- Sidebar visibility is inferred entirely from the task list — it auto-shows when non-empty and auto-hides when empty. No manual toggle command and no persisted preference.
- The task list is in-memory for the current session only: it is not written to the session log and not restored on resume/fork. `/clear` empties it.
- The task tool passes through the existing tool-confirmation gate but is auto-safe (no filesystem/network effect), so it is allowed in plan mode as well as build mode.

## Capabilities

### New Capabilities
- `task-tracking`: the task data model (item shape, status lifecycle, single-`in_progress` invariant), the `task_write` tool contract, the mutex-protected `App` store, and its in-memory (current-session-only) lifetime.
- `task-sidebar`: the TUI panel that renders the task list beside chat, the horizontal-split layout math with narrow-terminal fallback, and the inferred (non-empty ⇒ visible) show/hide behavior.

### Modified Capabilities
<!-- No existing spec's requirements change. -->

## Impact

- **New code**: a task store module (`src/tasks.zig`), the sidebar renderer, and the `task_write` tool handler in `src/tools.zig`.
- **`src/tools.zig`**: new entry in `tool_specs` (`tools.zig:229`), new branch in `execute` (`tools.zig:329`), and a new field on `Context` (`tools.zig:16`) to reach the task store.
- **`src/App.zig`**: owns the task store and its mutex; wires the store into the tool `Context`; `/clear` resets it.
- **`src/layout.zig`**: `compute` (`layout.zig:21`) gains sidebar width/visibility and the chat window loses that width.
- **`src/main.zig`**: renders the sidebar child window in the draw path (near `main.zig:328`).
- No breaking changes; no new external dependencies.

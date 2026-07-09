## Context

The agent already has all the plumbing this feature needs: a compile-time tool registry with a `Context` struct that threads shared state into tool handlers (`src/tools.zig:16`), a mutex-guarded `App` that separates the LLM worker thread from the render thread, a vertical stack layout computed each frame (`src/layout.zig:21`), a JSONL session log with resume/fork (`src/sessions.zig`), and a config store (`src/config.zig`). What is missing is (a) a place for the model to record structured intent and (b) a persistent on-screen view of it.

The one genuinely new thing is the **first horizontal split** in the UI. Today `src/layout.zig` only stacks full-width bands vertically (header, chat, preview/queue/loading, input). The sidebar requires carving a column out of the chat row.

Mutex discipline in this codebase is convention-only, and shared `App` state is easy to touch from both threads without locking. This design treats the task store as shared mutable state from day one and routes every access through a mutex, so it does not add to that debt.

## Goals / Non-Goals

**Goals:**
- Give the model a single, race-free tool to declare and update an ordered task list for the session.
- Show that list in a persistent right-hand panel with clear per-item status, auto-showing on content and degrading gracefully on narrow terminals.
- Persist and restore the list with the session; reset it on `/clear`.
- Reuse existing patterns (tool registry, `Context`, layout math, session log, config) rather than inventing new subsystems.

**Non-Goals:**
- No nested/hierarchical tasks, dependencies, priorities, or due dates — a flat ordered list only.
- No user-driven editing of tasks from the TUI (no checkbox clicking); the model owns the list. `/tasks` only toggles visibility.
- No cross-session or global task board; scope is the current session.
- No automatic inference of tasks from the transcript; the model must call `task_write` explicitly.

## Decisions

### Decision: One overwrite tool (`task_write`) rather than granular add/update/complete tools

The tool takes the full desired `tasks` array and replaces the stored list wholesale. Rationale: a single overwrite is idempotent, trivially race-free (no read-modify-write across tool calls), and matches how frontier agents drive todo lists — the model resends the whole list with updated statuses each turn. Per-item mutation tools (`task_add`, `task_complete`, `task_remove`) would multiply the tool surface, require stable id bookkeeping across calls, and invite lost-update races between the model's mental state and the store.

*Alternative considered:* a diff/patch tool keyed by id. Rejected as more complex for the model to call correctly with no real benefit at this list size.

### Decision: Task store lives on `App`, reached by tools through `Context`

Add `src/tasks.zig` exposing a `TaskStore` (its own `ArrayList` of items plus an owning arena or per-item dupes) and an `apply(tasks)` method that enforces the single-`in_progress` invariant. `App` owns one `TaskStore` and its access is guarded by a dedicated mutex (or the existing `app.mutex` if lock ordering stays simple). `tools.Context` gains a `?*TaskStore` field, wired in `App` wherever the tool context is built. The `task_write` handler validates input, then calls `store.apply` under the lock.

*Alternative considered:* passing `*App` directly into `Context`. Rejected — `tools.zig` deliberately does not depend on `App`; keeping the dependency to a small `TaskStore` preserves that boundary and keeps the tool unit-testable.

### Decision: Ownership via a store-owned arena, reset on each overwrite

Because the list is fully replaced on every `task_write`, the store keeps an arena that is reset (or freed and recreated) on each `apply`, and dupes the incoming `id`/`content` strings into it. This sidesteps the class of mixed literal/heap ownership bugs seen elsewhere — the store never has to reason about which strings it owns because it owns all of them, and frees them all at once on the next overwrite and on `deinit`.

### Decision: Sidebar as a fixed-width column subtracted from chat width

`layout.compute` gains a `sidebar_w` output: `0` when the sidebar is hidden or when `screen_width - sidebar_w < min_chat_w`, else a fixed width (e.g. ~32 cols, clamped to a fraction of screen width). The chat window is drawn at `width = screen_width - sidebar_w` and the sidebar as a bordered child window at `x_off = screen_width - sidebar_w`, spanning the chat row height. Visibility is inferred: `list_non_empty AND fits` — no manual toggle and no persisted preference. This keeps all split arithmetic in one place and leaves the existing vertical bands (preview/queue/loading/input) full-width below.

*Alternative considered:* a floating overlay panel. Rejected — it would occlude chat content and complicate mouse selection, which is computed against the chat window rectangle in `src/main.zig`.

### Decision: In-memory only, no persistence

The task list lives only in the `App` store for the current session. It is deliberately NOT written to the session log and NOT restored on resume/fork — a resumed session starts fresh and the model re-declares its plan via `task_write` as it works. `/clear` empties it. There is no visibility setting either: the sidebar shows whenever the list is non-empty and fits, so nothing needs persisting.

### Decision: `task_write` is policy-safe in every mode

`task_write` touches no file or network, so `isToolAllowed` treats it like the read-only/skill tools and permits it in plan mode as well as build mode. It still passes through the normal confirmation gate machinery but should be treated as auto-approvable (no destructive effect) consistent with how other side-effect-free tools are handled.

## Risks / Trade-offs

- **[New concurrency surface]** → The store is shared between worker and render threads. Mitigation: every access goes through a mutex from the first commit; the render path takes a short-lived snapshot (copy of ids/contents/statuses into the frame arena) rather than holding the lock across rendering.
- **[First horizontal split may interact with mouse selection]** → Chat mouse selection in `src/main.zig` is computed against the chat window rectangle. Mitigation: shrink the chat window's `width` (not just visually) so selection math uses the reduced rectangle; the sidebar is non-interactive.
- **[Narrow terminals]** → A fixed sidebar width could crush chat on small screens. Mitigation: the `fits` guard suppresses the sidebar below a minimum chat width, matching the existing pattern where panels collapse when `screen_height` is tight.
- **[Model may not use the tool]** → Value depends on the model calling `task_write`. Mitigation: mention the tool in the system prompt's guidance for multi-step work; the feature degrades to a no-op empty sidebar when unused, costing nothing.
- **[Tasks lost on resume]** → Because the list is in-memory only, resuming a session drops any prior task list. Accepted trade-off: tasks reflect the live plan of an active turn, not durable history; the model rebuilds the list as it resumes work.

## Migration Plan

Additive only. No session-log format change and no config schema change — the task list is purely in-memory runtime state. No data migration or rollback concerns.

## Open Questions

- Exact sidebar width and minimum chat width thresholds — pick concrete constants during implementation and expose them as named consts (per repo no-magic-numbers convention).
- Whether the sidebar should also show a compact one-line summary in the header/status bar when suppressed on narrow terminals — deferred; can be a follow-up.

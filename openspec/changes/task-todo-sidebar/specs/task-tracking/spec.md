## ADDED Requirements

### Requirement: Task item data model

The system SHALL represent a session task list as a flat, ordered list of items. Each item SHALL have a stable string `id`, a human-readable `content` string, and a `status` that is exactly one of `pending`, `in_progress`, or `completed`. Order SHALL be preserved as supplied by the model.

#### Scenario: Item carries id, content, and status

- **WHEN** the task list contains an item
- **THEN** that item exposes a non-empty `id`, a `content` string, and a `status` of `pending`, `in_progress`, or `completed`

#### Scenario: List order is stable

- **WHEN** the model supplies items in a given order
- **THEN** the store preserves that order when read for rendering and persistence

### Requirement: Single in-progress invariant

The store SHALL guarantee that at most one item has status `in_progress` at any time. When a write would set more than one item to `in_progress`, the store SHALL keep only the last such item as `in_progress` and coerce the others to `pending`.

#### Scenario: Two items marked in_progress in one write

- **WHEN** a `task_write` sets items A and B both to `in_progress`
- **THEN** the resulting stored list has exactly one item as `in_progress` (the later one, B) and A is stored as `pending`

### Requirement: task_write tool contract

The system SHALL expose a built-in tool named `task_write` that accepts a `tasks` array where each element has `id`, `content`, and `status`. The tool SHALL replace the entire stored list with the supplied items (an overwrite, not a merge), and SHALL return a short textual confirmation summarizing counts by status. Invalid input (missing `tasks`, an item missing `id`/`content`, or an unrecognized `status`) SHALL return an error result without mutating the store.

#### Scenario: Overwrite replaces the whole list

- **WHEN** the store holds three items and `task_write` is called with two items
- **THEN** the store afterwards holds exactly those two items and the previous items are gone

#### Scenario: Confirmation summarizes status counts

- **WHEN** `task_write` succeeds with one completed and two pending items
- **THEN** the tool result text reports the counts (e.g. 1 completed, 2 pending) and is not an error

#### Scenario: Invalid status rejected

- **WHEN** `task_write` is called with an item whose `status` is not `pending`, `in_progress`, or `completed`
- **THEN** the tool returns an error result and the store is left unchanged

### Requirement: Thread-safe store access

The task store SHALL be safe for concurrent access between the LLM worker thread (which writes via `task_write`) and the render thread (which reads for the sidebar). All reads and writes SHALL be guarded by a mutex, and a read for rendering SHALL observe a consistent snapshot of the list.

#### Scenario: Write during render

- **WHEN** the worker thread applies a `task_write` while the render thread reads the list
- **THEN** the render thread observes either the full pre-write or the full post-write list, never a torn intermediate state

### Requirement: Task tool allowed in plan mode

Because `task_write` has no filesystem or network side effect, it SHALL be permitted in both build and plan modes.

#### Scenario: task_write in plan mode

- **WHEN** the agent is in plan mode and calls `task_write`
- **THEN** the tool policy allows the call rather than blocking it

### Requirement: In-memory session lifetime

The task list SHALL live in memory for the current session only; it is NOT persisted to the session log and NOT restored on resume or fork. Clearing the conversation SHALL empty the task list.

#### Scenario: Not restored on resume

- **WHEN** a session with a non-empty task list is resumed later
- **THEN** the restored session starts with an empty task list

#### Scenario: Clear empties tasks

- **WHEN** the user runs `/clear`
- **THEN** the task list becomes empty

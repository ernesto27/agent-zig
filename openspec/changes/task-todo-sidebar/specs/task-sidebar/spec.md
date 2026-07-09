## ADDED Requirements

### Requirement: Sidebar renders the task list

The TUI SHALL render a task sidebar to the right of the chat window. Each task SHALL be shown on its own row with a status glyph followed by its content: `○` for `pending`, `◐` for `in_progress`, `✔` for `completed`. The sidebar SHALL include a header line summarizing progress (completed count over total).

#### Scenario: Tasks shown with status glyphs

- **WHEN** the task list has one completed, one in_progress, and one pending item and the sidebar is visible
- **THEN** the sidebar shows three rows with glyphs `✔`, `◐`, `○` respectively, each next to its content, plus a header showing 1 of 3 complete

#### Scenario: Long content is truncated to column width

- **WHEN** a task's content is wider than the sidebar column
- **THEN** the row is truncated to fit the column width without wrapping into the chat area

### Requirement: Auto show and hide

Sidebar visibility SHALL be inferred entirely from the task list: the sidebar appears when the list has at least one task that is not yet completed, and disappears when the list is empty or when every task is completed. There is no manual toggle or persisted visibility preference.

#### Scenario: Appears when first task added

- **WHEN** the task list transitions from empty to having a non-completed task
- **THEN** the sidebar becomes visible on the next render

#### Scenario: Hides when list emptied

- **WHEN** the task list becomes empty
- **THEN** the sidebar is not rendered and the chat window reclaims its width

#### Scenario: Hides when all tasks completed

- **WHEN** the last non-completed task is marked completed so every task is completed
- **THEN** the sidebar is not rendered and the chat window reclaims its width

### Requirement: Horizontal split layout with narrow-terminal fallback

The layout SHALL reserve a fixed-width sidebar column within the chat row and reduce the chat window width by that amount. When the terminal is too narrow to show both the chat and a usable sidebar (chat width would drop below a minimum), the sidebar SHALL be suppressed and the chat SHALL use the full width.

#### Scenario: Split on a wide terminal

- **WHEN** the terminal is wide enough and the sidebar is visible
- **THEN** the chat window width equals the total width minus the sidebar column width, and both render side by side without overlap

#### Scenario: Suppressed on a narrow terminal

- **WHEN** the terminal width is below the threshold needed for chat plus sidebar
- **THEN** the sidebar is not rendered and the chat uses the full terminal width, even if the task list is non-empty

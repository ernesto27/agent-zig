# /skills Command Design

## Summary

Add a built-in `/skills` command that opens a searchable modal listing every loaded skill and lets the user toggle each skill between enabled and disabled for the current app session.

Disabled skills remain visible in `/skills` so they can be re-enabled, but they do not appear in the slash command picker skill entries and cannot be executed while disabled.

## Goals

- Add a discoverable `/skills` command to the built-in slash command list.
- Show all loaded skills in one modal.
- Support inline search/filtering by skill name.
- Allow toggling skill enablement without touching persisted config.
- Hide disabled skills from the normal slash command list.
- Block direct execution of disabled skills.

## Non-Goals

- Persisting skill enablement to `~/.config/agent-zig/config.json`.
- Changing how skills are discovered from `.agents/skills`.
- Adding new tests for this change.

## User Experience

### Entry

- Typing `/skills` in the input and confirming it opens a centered modal.
- `/skills` is a built-in slash command alongside `/mcp`, `/model`, `/sandbox`, and the existing commands.

### Modal Layout

The modal uses the existing shared modal list rendering style and shows:

- title: `Skills`
- a query line for filtering
- one row per loaded skill
- the skill name as the primary label
- the skill description as the secondary text
- a badge showing `enabled` or `disabled`

If no skills are loaded, the modal opens and shows an empty-state message instead of failing.

### Modal Interaction

- typing updates the filter query
- `Up` and `Down` move selection
- `Enter` toggles the selected skill
- `Esc` closes the modal

Filtering matches skill names. The modal always includes both enabled and disabled skills so disabled skills can be found and re-enabled.

## Runtime Behavior

### Enablement Model

- Add `enabled: bool = true` to `src/skills.zig`'s `Skill` struct.
- Every loaded skill starts enabled by default.
- Toggling from `/skills` only changes the in-memory `Skill.enabled` field for the current process.
- Restarting the app resets all skills back to enabled.

### Command Picker Rule

- Built-in slash commands always remain visible.
- Skill-backed entries in the command picker are only included when `skill.enabled == true`.
- Disabled skills are therefore absent from the normal slash command list.

### Execution Rule

If a disabled skill is somehow targeted outside the picker flow, execution is blocked and the app shows a short notice such as `Skill "<name>" is disabled`.

## Implementation Plan

### 1. Skill Data Model

Update `src/skills.zig`:

- extend `Skill` with `enabled: bool = true`
- keep enablement as runtime state only
- keep registry loading logic otherwise unchanged

No config or file parsing changes are needed because enablement is not persisted.

### 2. Slash Command Registration

Update `src/commands/command_picker.zig`:

- add a new `skills` item to the built-in `commands` array
- add a corresponding `skills` variant to `CommandAction`

### 3. Skills Picker Controller

Add a new picker module, for example `src/skills_picker.zig`, following the same app-level pattern used by other modal controllers.

Responsibilities:

- store `active`, `query`, filtered item list, and `selected`
- build rows from `app.skill_registry.skills.items`
- expose `open`, `refresh`, `moveUp`, `moveDown`, `toggleSelected`, `reset`, and `render`

The picker should render through `src/modal_list.zig` rather than creating a separate rendering style.

### 4. Input Handling Integration

Update `src/main.zig` and `src/input_handler.zig`:

- instantiate and deinit the new `SkillsPicker`
- thread it through `InputContext`
- open it from `runSlashCommand()` when `/skills` is chosen
- route text input, arrow keys, `Enter`, and `Esc` when the picker is active

`Enter` in the skills modal toggles the selected skill instead of sending a chat message.

### 5. Command Picker Filtering

Update `src/commands/command_picker.zig` refresh logic:

- when appending skill-backed command entries, skip any skill where `enabled == false`

This keeps disabled skills out of the slash command suggestions while leaving the built-in command list intact.

### 6. Direct Execution Guard

Update the skill execution path in `src/input_handler.zig`:

- before calling `ctx.app.skillCMD(bare_name)`, check that the registry entry exists and is enabled
- if it exists but is disabled, append a short notice and do not send the request

## Error Handling

- No loaded skills: show an empty modal state.
- Disabled skill selected through stale UI or nonstandard flow: show a short notice and block execution.
- Toggle operations are in-memory only, so there are no config write failures to handle.

## Verification

- Run `zig build` after implementation.
- No new tests will be added for this change.

## Files Expected To Change

- `src/skills.zig`
- `src/commands/command_picker.zig`
- `src/input_handler.zig`
- `src/main.zig`
- `src/App.zig` if needed for notice helpers or shared state access
- new picker module such as `src/skills_picker.zig`

## Open Decisions Already Resolved

- Disabled skills are hidden from the slash command list.
- Enablement is session-only, not persisted.
- Enablement state lives on each `Skill` struct via `enabled: bool`.
- No tests will be added for this change.

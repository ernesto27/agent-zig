# Plan: Skill Invocation Through Message Queue

- **Date:** 2026-07-04
- **Domain(s):** Backend (TUI app state machine)
- **Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com)
- **Status:** Implemented

## 1. Summary

When the LLM is busy processing a turn and the user invokes a skill via the command picker (`skills:name`), the invocation was **silently dropped**. This change routes skill invocations through the existing `message_queue` — same as plain-text follow-ups — so the skill loads on the next turn instead of being lost.

## 2. Scope

### In scope
- Skill invocations via command picker (`skills:name`) while `loading.active` → queue the generated prompt text (silently, no notice).
- Remove the dead `!skill.enabled` check from the command-picker skill path (disabled skills already filtered by `command_picker.zig` line 100).
- Extract the duplicated skill prompt format string into a single `App.buildSkillPrompt` helper.
- Fix `clearInput` ordering: clear after the fallible operation succeeds, not before it.
- Fix memory leak: `defer alloc.free(prompt)` after `enqueue` (which dupes internally).
- Fix command picker overlap: when "Steering:" queue messages are visible, render the picker above the queue.
- Rename `input_y` → `anchor_y` in `CommandPicker.render` to reflect the generalized contract.

### Out of scope / non-goals
- Other slash commands (compact, fork, init, etc.) — already return `.none` when loading and intentionally block.
- Queueing skills from raw text input (typing `skills:name` manually without the picker).
- Changing the message queue data structure (stays `[]const u8`).
- Changing `dequeueFollowUp` or the agent loop consumption logic.
- Showing a "queued" notice in chat — user opted for silent queuing.

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Scope — what besides text? | Skills only (command-picker `skills:name`). |
| 2 | User-visible feedback on queue? | **Silent.** No notice. The skill loads on the next turn with its normal "→ Skill \"X\"" notice when the tool executes. |
| 3 | Multiple queued items strategy? | One per turn (existing `dequeueFollowUp` unchanged). |
| 4 | Duplicated prompt format string? | Extract into `App.buildSkillPrompt` — single source of truth. |
| 5 | `clearInput` ordering? | Move after fallible operations: allocate/enqueue first, clear on success. |
| 6 | Command picker overlaying queue? | Anchor picker above `queue_y` when queue visible, else above `input_y`. |

## 4. Design

The message queue stays a plain `[]const u8` FIFO. `App.buildSkillPrompt` generates the prompt text; it's enqueued as a regular message. When `dequeueFollowUp` drains it after the LLM finishes, it flows: user message → LLM calls `skill` tool → `onToolResult` → `appendSkillNotice`.

```
User invokes skill while loading
        │
        ▼
App.buildSkillPrompt(name) ──► message_queue.enqueue()
        │
        ▼
command picker resets; no LLM spawn (already running)
        │
  ... LLM finishes current turn ...
        │
        ▼
dequeueFollowUp() → prompt text as user message
        │
        ▼
LLM calls `skill` tool → onToolResult → "→ Skill \"X\""
```

Command picker anchor selection:

```
No queue:                         Queue visible:

  chat area                        chat area
  ┌──────────────────┐             ┌──────────────────┐
  │ command picker   │ ← input_y  │ command picker   │ ← queue_y
  └──────────────────┘             └──────────────────┘
  input box                          Steering: ...
                                     Steering: ...
                                     input box
```

## 5. Interfaces & contracts

- **`App.buildSkillPrompt(alloc, skill_name) ![]const u8`** (new, namespace-level) — returns allocated prompt string. Caller owns memory.
- **`App.skillCMD`** — now delegates to `buildSkillPrompt`.
- **`CommandPicker.render(win, screen_w, anchor_y)`** — renamed from `input_y`; renders above whichever Y is passed.
- **`input_handler.zig`** queue path — calls `App.buildSkillPrompt` + `message_queue.enqueue`.

## 6. Behavior & states

| State | Before | After |
|-------|--------|-------|
| Skill invoked while `loading.active == false` | `skillCMD` → append → spawn LLM | Same, `clearInput` moved after `skillCMD` |
| Skill invoked while `loading.active == true` | Silently dropped | `buildSkillPrompt` → `enqueue` → `clearInput` |
| Queue drains after turn | Plain text → user message | Skill prompt → user message → LLM picks it up |
| Disabled skill in picker | Dead code (already filtered) | Removed |
| Picker + queue overlap | Picker renders over queue text | Picker renders above queue |

## 7. Implementation

### Files changed

| File | Change |
|------|--------|
| `src/App.zig` | Extract `buildSkillPrompt` helper; `skillCMD` delegates to it |
| `src/input_handler.zig` | Add `else` for queuing; remove dead `!skill.enabled`; fix `clearInput` ordering; use `App.buildSkillPrompt`; add `defer alloc.free(prompt)` |
| `src/commands/command_picker.zig` | Rename `input_y` → `anchor_y` in `render` |
| `src/main.zig` | Picker anchor: `queue_y` when queue visible, else `input_y` |

### Final code

`src/App.zig:228-237`:

```zig
    pub fn buildSkillPrompt(alloc: std.mem.Allocator, skill_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            alloc,
            "Use the `skill` tool to load and apply the `{s}` skill for this conversation.",
            .{skill_name},
        );
    }

    pub fn skillCMD(self: *Self, skill_name: []const u8) !void {
        const prompt = try buildSkillPrompt(self.alloc, skill_name);
        errdefer self.alloc.free(prompt);
        try self.messages.append(self.alloc, .{ .role = .user, .content = prompt });
    }
```

`src/input_handler.zig:537-549`:

```zig
                if (ctx.app.skill_registry.find(bare_name)) |_| {
                    if (!ctx.app.loading.active) {
                        try ctx.app.skillCMD(bare_name);
                        clearInput(ctx);
                        result = .send;
                    } else {
                        // LLM is busy — queue the skill invocation so it runs on the next turn.
                        const prompt = try App.buildSkillPrompt(alloc, bare_name);
                        defer alloc.free(prompt);
                        try ctx.app.message_queue.enqueue(alloc, prompt);
                        clearInput(ctx);
                    }
                }
```

`src/main.zig:509-512`:

```zig
        if (command_picker.active and command_picker.results.items.len > 0) {
            const picker_anchor = if (layout.queue_h > 0) layout.queue_y else layout.input_y;
            command_picker.render(win, vx.screen.width, picker_anchor);
        }
```

`src/commands/command_picker.zig:117`:

```zig
    pub fn render(self: *CommandPicker, win: vaxis.Window, screen_w: u16, anchor_y: u16) void {
```

## 8. Testing

- **Unit tests:** Existing `message_queue` tests cover enqueue/dequeue. No new logic to unit-test.
- **Integration tests:** Manual:
  1. Start a long-running LLM request.
  2. While the spinner is active, select a skill from the command picker and press Enter.
  3. Verify no crash, no duplicate messages, picker closes cleanly.
  4. Wait for the LLM to finish. Verify the skill prompt sends as the next user message and the skill loads.

## 9. Acceptance criteria

1. Invoking a skill via command picker while LLM is loading silently queues it.
2. The queued skill prompt is sent to the LLM on the next turn.
3. Normal (non-loading) skill invocation behavior is unchanged.
4. Plain text queuing during loading is unchanged.
5. Command picker does not visually overlap queued "Steering:" messages.

## 10. Risks & open items

- None. All changes are small, targeted edits within existing patterns. Build and tests pass.

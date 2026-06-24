# Command Picker Counter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a `(current/total)` position counter on the command picker's bottom border, e.g. `(1/37)`, where the first number is the highlighted item (1-indexed) and the second is the total number of matched results.

**Architecture:** The counter is drawn entirely inside `CommandPicker.render` in `src/commands/command_picker.zig`. After the existing bordered child window is created (which draws the rounded border into the screen), the counter text is overlaid onto the bottom-border row by printing onto the parent `win` at the same absolute cells. Because libvaxis `printSegment` keeps the text slice by reference until `vx.render()` runs, the formatted string is stored in a `buf` field on the `CommandPicker` struct (mirroring `src/context_usage.zig`), which requires `render` to take a mutable `*CommandPicker`.

**Tech Stack:** Zig 0.15.2+, libvaxis 0.5.1 (TUI).

## Global Constraints

- Zig files: zero comments — no module-level docstrings, no section dividers, no inline explanatory comments.
- No magic numbers: extract literals into named `const` declarations.
- No automated tests for this change — the user has a standing preference to skip tests unless explicitly requested. Verification is via `zig build` and a manual visual check with `zig build run`.
- Counter is always shown while the picker is open (the render function is only called when `results.items.len > 0`, so total is always ≥ 1).
- First number = `selected + 1` (changes as the user presses up/down). Second number = `results.items.len` (built-in commands plus dynamically loaded skills that matched the query).
- Counter placement: embedded in the bottom border, left side, after the corner glyph — rendered as `╰ (N/M) ────╯`.

---

## Files

- Modify: `src/commands/command_picker.zig`
  - Add a `counter_buf` field to the `CommandPicker` struct.
  - Change `render` to take `*CommandPicker` (mutable) instead of `*const CommandPicker`.
  - Add a private helper `renderCounter` that formats and overlays the counter onto the bottom border.
- Modify: `src/main.zig:426` — no signature change needed at the call site (auto-ref of the existing `var command_picker`), but verify it still compiles.

---

### Task 1: Render the position counter on the picker's bottom border

**Files:**
- Modify: `src/commands/command_picker.zig:30-39` (struct fields), `:109` (`render` signature), end of `render` body (`:159`), and add helper after `maxNameWidth` (`:171`).
- Verify: `src/main.zig:426` (call site).

**Interfaces:**
- Consumes: existing `CommandPicker` fields `selected: usize` and `results: std.ArrayList(Command)`; `render`'s existing locals `picker_y: u16` and `picker_h: u16` computed at `command_picker.zig:112-113`.
- Produces: `render(self: *CommandPicker, win: vaxis.Window, screen_w: u16, input_y: u16) void` — same parameters as before, only the receiver becomes mutable. Adds private `fn renderCounter(self: *CommandPicker, win: vaxis.Window, picker_y: u16, picker_h: u16) void`.

- [ ] **Step 1: Add the counter buffer field and color/layout constants**

In `src/commands/command_picker.zig`, add two file-scope constants just below the existing `pub const MAX_RESULTS = 10;` / `pub const SKILL_PREFIX = "skills:";` block (around line 6):

```zig
const COUNTER_BUF_LEN = 32;
const COUNTER_FG = vaxis.Color{ .rgb = .{ 0x88, 0x88, 0x88 } };
```

Then add the buffer field to the `CommandPicker` struct (after `skill_registry`, around line 35):

```zig
    skill_registry: ?*const agent.skills.Registry = null,
    counter_buf: [COUNTER_BUF_LEN]u8 = undefined,
```

- [ ] **Step 2: Change `render` to a mutable receiver**

Change the `render` signature at `command_picker.zig:109` from:

```zig
    pub fn render(self: *const CommandPicker, win: vaxis.Window, screen_w: u16, input_y: u16) void {
```

to:

```zig
    pub fn render(self: *CommandPicker, win: vaxis.Window, screen_w: u16, input_y: u16) void {
```

Leave `maxNameWidth` as `*const CommandPicker` — calling a const method through a mutable pointer is allowed.

- [ ] **Step 3: Call the counter helper at the end of `render`**

At the very end of the `render` function body (immediately after the `while (row < n)` loop closes, around line 159, before the function's closing brace), add:

```zig
        self.renderCounter(win, picker_y, picker_h);
```

Note: `picker_y` and `picker_h` are already in scope (declared at `command_picker.zig:112-113`).

- [ ] **Step 4: Implement the `renderCounter` helper**

Add this method to the `CommandPicker` struct, directly after the `maxNameWidth` function (after line 171):

```zig
    fn renderCounter(self: *CommandPicker, win: vaxis.Window, picker_y: u16, picker_h: u16) void {
        const text = std.fmt.bufPrint(&self.counter_buf, " ({d}/{d}) ", .{ self.selected + 1, self.results.items.len }) catch return;
        _ = win.printSegment(
            .{ .text = text, .style = .{ .fg = COUNTER_FG } },
            .{ .row_offset = picker_y + picker_h -| 1, .col_offset = 1 },
        );
    }
```

This overlays the counter onto the bottom border row (`picker_y + picker_h - 1`), starting at column 1 so the `╰` corner glyph at column 0 stays intact. The leading and trailing spaces in the format string produce the `╰ (N/M) ─` gap seen in the design. Drawing onto `win` after the bordered child was created in `render` means these cells overwrite the border horizontals at exactly those columns; cells past the text keep their `─` glyphs.

- [ ] **Step 5: Build and verify it compiles**

Run: `zig build`
Expected: builds with no errors. (A `*const`→`*` receiver change plus a new method should not affect the `command_picker.render(...)` call at `main.zig:426`, because `command_picker` is declared `var` at `main.zig:123` and the method auto-references.)

- [ ] **Step 6: Run the test step to confirm nothing regressed**

Run: `zig build test`
Expected: both the library and app test executables pass (no new tests added; this confirms the signature change didn't break existing compilation/tests).

- [ ] **Step 7: Manual visual verification**

Run: `zig build run`
Then type `/` to open the command picker.
Expected:
- The bottom border reads `╰ (1/<total>) ────…────╯`, where `<total>` is the count of all matched commands plus loaded skills.
- Pressing the down arrow (or Ctrl+N) increases the first number; pressing up decreases it. The first number never goes below 1 or above `<total>`.
- Typing a query that filters results (e.g. `/mo`) updates `<total>` to the filtered count and resets the first number to 1.
- The `╰` and `╯` corners remain intact; the counter does not overflow the border.

Press `Esc` to close the picker.

- [ ] **Step 8: Commit**

```bash
git add src/commands/command_picker.zig
git commit -m "command picker: show (current/total) counter on bottom border"
```

(Single-line commit subject, no body, no Co-Authored-By trailer — per repo/user conventions.)

---

## Self-Review

- **Spec coverage:** Counter placement (bottom border, left, after corner) ✓ Step 4. Always visible while picker open ✓ (render is only invoked when results > 0; counter unconditional). First number = `selected + 1`, updates on navigation ✓ Step 4 + Step 7 verification. Second number = total matched (commands + skills) ✓ uses `results.items.len`, which includes appended skill entries from `refresh`.
- **Placeholder scan:** No TBD/TODO; every code step shows complete code.
- **Type consistency:** `renderCounter` is referenced in Step 3 and defined in Step 4 with matching signature `(self: *CommandPicker, win: vaxis.Window, picker_y: u16, picker_h: u16)`. `COUNTER_BUF_LEN`, `COUNTER_FG`, `counter_buf` are introduced in Step 1 and used in Steps 1/4. `picker_y`/`picker_h` are existing `u16` locals (`command_picker.zig:112-113`).
- **vaxis lifetime gotcha:** counter text stored in `self.counter_buf` (struct-owned, outlives the deferred `vx.render()`), matching the `src/context_usage.zig` pattern — not a stack-local buffer.

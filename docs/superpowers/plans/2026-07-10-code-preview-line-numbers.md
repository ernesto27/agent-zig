# Code Preview Line Numbers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a left-hand line-number gutter to the `write_file` / `edit_file` tool-confirmation preview modal (`src/code_modal.zig`), showing real file line numbers.

**Architecture:** The preview modal renders `write_file` content (green) or an `edit_file` diff (red `- ` old lines, then green `+ ` new lines). We add a dim, right-aligned line-number gutter to the left of each rendered line. For `write_file` the gutter is `1..N`. For `edit_file` both the old block and the new block are numbered starting from the line where `old_string` occurs in the file on disk; that start line is computed once when the confirmation is created (reusing the sandbox-aware file-read backend the edit tools already use) and stored in `ToolConfirmation`.

**Tech Stack:** Zig 0.15.2, libvaxis TUI. No new dependencies.

**Status (2026-07-11):** Implemented in the working tree — all code steps applied across `src/App.zig`, `src/tools.zig`, `src/code_modal.zig`, and `zig build` + `zig build test` both pass. Not yet committed (changes remain unstaged); the manual TUI visual check (Task 2, Step 7) has not been performed in this session.

## Global Constraints

- Zig version: 0.15.2 (verified). Format strings below use the runtime-width form `"{[n]d: >[w]}"`, confirmed to compile and right-align on this version.
- Follow repo conventions in `CLAUDE.md`: commit only when explicitly asked, work on `master`, single-line commit subjects, no `Co-Authored-By` trailer.
- Per project memory, **do not add new test files** for this work; verification is `zig build` + `zig build test` (existing tests must still pass) plus a manual visual check in the running TUI.
- Zig files default to **zero comments**; match the terseness of surrounding code. The one `///` doc line on the new public `matchStartLine` mirrors the existing `editTool` doc style in the same file.
- All strings drawn by `code_modal.render` are allocated from the caller's per-frame arena (`frame_arena` in `src/main.zig:617`), which outlives `vx.render` (`src/main.zig:620`). New `allocPrint` gutter strings use that same `alloc` and are therefore safe under the libvaxis deferred-text rule.

---

## File Structure

- **Modify** `src/App.zig`
  - `ToolConfirmation` struct (`src/App.zig:25-34`): add `start_line: usize = 1`.
  - `confirmTool` (`src/App.zig:525-593`): compute the start line for `edit_file` before taking the mutex, and store it while locked.
- **Modify** `src/tools.zig`
  - Add public helper `matchStartLine` (near `editTool`, currently ending at `src/tools.zig:575`) that reads a file through the existing `Exec` backend and returns the 1-based line of the first `old_string` match.
- **Modify** `src/code_modal.zig`
  - Add `maxLineNo` and `gutterWidth` helpers.
  - Widen the modal by the gutter width in `contentCols` (`src/code_modal.zig:50-63`).
  - Render the gutter in both branches of `render` (`src/code_modal.zig:147-191`).

No files are created. No public interface outside these files changes.

---

### Task 1: Line-number state and computation

Adds the `start_line` field and the logic that fills it. After this task the value is computed and stored on every confirmation but is not yet displayed; the build and existing tests still pass.

**Files:**
- Modify: `src/App.zig:25-34` (struct), `src/App.zig:562-582` (confirmTool)
- Modify: `src/tools.zig` (new `matchStartLine` after `editTool`, i.e. after current line 575)

**Interfaces:**
- Consumes: `agent.tools.Context` (`src/tools.zig`, fields include `sandbox: ?*sandbox_mod.Sandbox`), the private `Exec` union and its `readFile` method (`src/tools.zig:469-485`), and `App.sandbox` (`src/App.zig:108`, type `agent.sandbox.Sandbox`).
- Produces:
  - `App.ToolConfirmation.start_line: usize` — 1-based file line the preview's first line maps to; `1` when unknown or for `write_file`.
  - `pub fn matchStartLine(arena: std.mem.Allocator, ctx: Context, file_path: []const u8, needle: []const u8) ?usize` in `src/tools.zig`.

- [x] **Step 1: Add the `start_line` field to `ToolConfirmation`**

In `src/App.zig`, change the struct (currently lines 25-34):
old_string: []const u8 = "",
new_string: []const u8 = "",
cursor: ConfirmationAction = .approve,
};

    const new_s = if (is_mcp) "" else (agent.tools.getStringField(input, "new_string") orelse "");

    self.mutex.lock();
    self.loading.pause();
    self.tool_confirmation.pending = true;
    self.tool_confirmation.old_string = old_s;
    self.tool_confirmation.new_string = new_s;
    self.tool_confirmation.cursor = .approve;
    self.preview_scroll = 0;
    self.tool_status = name;
```zig
pub const ToolConfirmation = struct {
    pending: bool = false,
    tool_name: []const u8 = "",
    file_path: []const u8 = "",
    cond: std.Thread.Condition = .{},
    content: []const u8 = "",
    old_string: []const u8 = "",
    new_string: []const u8 = "",
    start_line: usize = 1,
    cursor: ConfirmationAction = .approve,
};
```

- [x] **Step 2: Add the `matchStartLine` helper to `src/tools.zig`**

Insert this function immediately after `editTool` (after its closing brace at current line 575, before `fn globTool`). It reuses the exact backend-selection expression from `execute` (`src/tools.zig:373-376`) so it is correct under an active sandbox:

```zig
/// First 1-based line where `needle` occurs in `file_path`, read through the
/// same host/sandbox backend the edit tools use. Null if unreadable or absent.
/// Expects an arena allocator; the transient read buffer is not freed here.
pub fn matchStartLine(arena: std.mem.Allocator, ctx: Context, file_path: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    const exec: Exec = if (ctx.sandbox) |sb|
        (if (sb.active) Exec{ .sandbox = sb } else .host)
    else
        .host;
    const read = exec.readFile(arena, file_path);
    if (read.is_error) return null;
    const idx = std.mem.indexOf(u8, read.content, needle) orelse return null;
    return std.mem.count(u8, read.content[0..idx], "\n") + 1;
}
```

- [x] **Step 3: Compute the start line in `confirmTool` before taking the mutex**

In `src/App.zig`, the block that assigns the fragment strings is currently:

```zig
        const cnt = if (is_mcp) mcp_body else (agent.tools.getStringField(input, "content") orelse "");
        const old_s = if (is_mcp) "" else (agent.tools.getStringField(input, "old_string") orelse "");
        const new_s = if (is_mcp) "" else (agent.tools.getStringField(input, "new_string") orelse "");

        self.mutex.lock();
```

Insert the start-line computation between the `new_s` line and `self.mutex.lock();` (file I/O must happen **before** the mutex so it never blocks the render thread):

```zig
        const cnt = if (is_mcp) mcp_body else (agent.tools.getStringField(input, "content") orelse "");
        const old_s = if (is_mcp) "" else (agent.tools.getStringField(input, "old_string") orelse "");
        const new_s = if (is_mcp) "" else (agent.tools.getStringField(input, "new_string") orelse "");
        old_string: []const u8 = "",
        new_string: []const u8 = "",
        cursor: ConfirmationAction = .approve,
    };
    
            const new_s = if (is_mcp) "" else (agent.tools.getStringField(input, "new_string") orelse "");
    
            self.mutex.lock();
            self.loading.pause();
            self.tool_confirmation.pending = true;
            self.tool_confirmation.old_string = old_s;
            self.tool_confirmation.new_string = new_s;
            self.tool_confirmation.cursor = .approve;
            self.preview_scroll = 0;
            self.tool_status = name;
        var start_line: usize = 1;
        if (std.mem.eql(u8, name, "edit_file")) {
            const line_ctx = agent.tools.Context{ .sandbox = &self.sandbox };
            if (agent.tools.matchStartLine(arena_alloc, line_ctx, fp, old_s)) |ln| start_line = ln;
        }

        self.mutex.lock();
```

- [x] **Step 4: Store the start line while holding the mutex**

Still in `confirmTool`, the assignment block is currently:

```zig
        self.tool_confirmation.old_string = old_s;
        self.tool_confirmation.new_string = new_s;
        self.tool_confirmation.cursor = .approve;
```

Add the `start_line` assignment (unconditional, so `write_file` and MCP resets it to `1`):

```zig
        self.tool_confirmation.old_string = old_s;
        self.tool_confirmation.new_string = new_s;
        self.tool_confirmation.start_line = start_line;
        self.tool_confirmation.cursor = .approve;
```

- [x] **Step 5: Build and run existing tests**

Run: `zig build && zig build test`
Expected: both compile and all existing tests pass (no output errors; the `test` step runs the `root.zig` and `main.zig` test executables). `matchStartLine` is now referenced by `App.zig`, so a signature mismatch would fail the build here.

- [ ] **Step 6: Commit (only if the user has asked you to commit)**

```bash
git add src/App.zig src/tools.zig
git commit -m "compute file start line for code preview confirmation"
```

---

### Task 2: Render the line-number gutter

Draws the dim gutter to the left of each preview line and widens the modal to fit it. After this task the feature is visible and complete.

**Files:**
- Modify: `src/code_modal.zig:50-63` (`contentCols`), add helpers, `src/code_modal.zig:147-191` (`render` body)

**Interfaces:**
- Consumes: `App.ToolConfirmation.start_line` (from Task 1), existing `isWrite`, `geometry`, `agent.utils.truncate(text, max_w, reserve)` (`src/utils.zig:23`), palette color `fg_muted` (already `= palette.dim`, `src/code_modal.zig:10`).
- Produces: `fn maxLineNo(app) usize` and `fn gutterWidth(app) u16` (file-private helpers).

- [x] **Step 1: Add `maxLineNo` and `gutterWidth` helpers**

In `src/code_modal.zig`, insert these two functions immediately after `contentCols` (after its closing brace at current line 63, before `fn geometry`):

```zig
fn maxLineNo(app: *const App) usize {
    const tc = app.tool_confirmation;
    if (isWrite(app)) return std.mem.count(u8, tc.content, "\n") + 1;
    const old_count = std.mem.count(u8, tc.old_string, "\n") + 1;
    const new_count = std.mem.count(u8, tc.new_string, "\n") + 1;
    return tc.start_line + @max(old_count, new_count) - 1;
}

fn gutterWidth(app: *const App) u16 {
    var digits: u16 = 1;
    var v = maxLineNo(app);
    while (v >= 10) : (v /= 10) digits += 1;
    return digits + 1;
}
```

- [x] **Step 2: Widen the modal by the gutter width**

In `src/code_modal.zig`, `contentCols` currently ends with `return max_len;` (line 62). Change that line to:

```zig
    return max_len + gutterWidth(app);
}
```

(Forward reference to `gutterWidth` is fine — Zig top-level declarations are order-independent.)

- [x] **Step 3: Declare gutter width once inside `render`, before the branch**

In `src/code_modal.zig`, the render body currently begins the content section at line 147 with `if (isWrite(app)) {`. Insert two lines just before it so both branches share them:

```zig
    const gw = gutterWidth(app);
    const digits: usize = gw - 1;
    if (isWrite(app)) {
```

- [x] **Step 4: Replace the `write_file` render branch**

Replace the current write branch (lines 147-161, from `if (isWrite(app)) {` through its closing `}` before the `} else {`). With Step 3 applied, the branch header is already `if (isWrite(app)) {`; replace its body so it reads exactly:

```zig
    if (isWrite(app)) {
        var it = std.mem.splitScalar(u8, tc.content, '\n');
        var idx: usize = 0;
        var prow: u16 = geo.body_start;
        while (it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                const g = std.fmt.allocPrint(alloc, "{[n]d: >[w]} ", .{ .n = idx + 1, .w = digits }) catch "";
                _ = modal.printSegment(.{
                    .text = g,
                    .style = .{ .fg = fg_muted },
                }, .{ .row_offset = prow, .col_offset = 1 });
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(line, inner_w -| gw, 1),
                    .style = .{ .fg = fg_write },
                }, .{ .row_offset = prow, .col_offset = 1 + gw });
                prow += 1;
            }
            idx += 1;
        }
    } else {
```

- [x] **Step 5: Replace the `edit_file` (diff) render branch**

Replace the current else branch body (lines 162-191, everything between `} else {` and the closing `}` that precedes the `const options` declaration). The `oln`/`nln` counters increment every iteration (independent of `scroll`) so numbers stay correct after scrolling. It should read exactly:

```zig
    } else {
        var prow: u16 = geo.body_start;
        var idx: usize = 0;
        var oln: usize = tc.start_line;
        var old_it = std.mem.splitScalar(u8, tc.old_string, '\n');
        while (old_it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                const g = std.fmt.allocPrint(alloc, "{[n]d: >[w]} ", .{ .n = oln, .w = digits }) catch "";
                _ = modal.printSegment(.{
                    .text = g,
                    .style = .{ .fg = fg_muted },
                }, .{ .row_offset = prow, .col_offset = 1 });
                const dl = std.fmt.allocPrint(alloc, "- {s}", .{line}) catch line;
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(dl, inner_w -| gw, 1),
                    .style = .{ .fg = fg_old },
                }, .{ .row_offset = prow, .col_offset = 1 + gw });
                prow += 1;
            }
            idx += 1;
            oln += 1;
        }
        var nln: usize = tc.start_line;
        var new_it = std.mem.splitScalar(u8, tc.new_string, '\n');
        while (new_it.next()) |line| {
            if (prow >= geo.body_end) break;
            if (idx >= scroll) {
                const g = std.fmt.allocPrint(alloc, "{[n]d: >[w]} ", .{ .n = nln, .w = digits }) catch "";
                _ = modal.printSegment(.{
                    .text = g,
                    .style = .{ .fg = fg_muted },
                }, .{ .row_offset = prow, .col_offset = 1 });
                const dl = std.fmt.allocPrint(alloc, "+ {s}", .{line}) catch line;
                _ = modal.printSegment(.{
                    .text = agent.utils.truncate(dl, inner_w -| gw, 1),
                    .style = .{ .fg = fg_new },
                }, .{ .row_offset = prow, .col_offset = 1 + gw });
                prow += 1;
            }
            idx += 1;
            nln += 1;
        }
    }
```

- [x] **Step 6: Build and run existing tests**

Run: `zig build && zig build test`
Expected: compiles cleanly, all existing tests pass. A `col_offset`/type error in the gutter math would surface here.

- [ ] **Step 7: Manual visual check in the TUI**

Run: `zig build run`
Then drive the agent to trigger a confirmation modal (ask it to create a new file, and to edit an existing file). Verify:
- New-file (`write_file`) preview shows a dim right-aligned gutter numbering `1, 2, 3, …`, with content aligned after it.
- Edit (`edit_file`) preview shows the old (`-`, red) block and the new (`+`, green) block both numbered from the true file line where the edit lands (e.g. an edit at line 42 shows `42` on the first `-` and first `+` line).
- Numbers stay correct and the gutter width stays stable while scrolling with `PgUp`/`PgDn`.
- Long lines are still truncated to fit (no wrap past the right border).

If you cannot reach an LLM to drive tool calls, note this and rely on Steps 6 as the automated gate; do not claim the visual behavior was confirmed if it was not observed.

- [ ] **Step 8: Commit (only if the user has asked you to commit)**

```bash
git add src/code_modal.zig
git commit -m "show line-number gutter in code preview modal"
```

---

## Self-Review

**1. Spec coverage.** The request — "add number lines on preview code edit or add modal view" — maps to: write/add mode gutter (Task 2, Step 4), edit/diff mode gutter with real file line numbers per the chosen design (Task 1 computes `start_line`; Task 2 Step 5 renders it). Covered.

**2. Placeholder scan.** Every code step contains complete, compilable Zig. Error handling matches the file's existing idiom (`allocPrint(...) catch ""` / `catch line`, matching current lines 137/169/182). No "TBD"/"handle edge cases"/"similar to" placeholders.

**3. Type consistency.**
- `matchStartLine` is defined once (Task 1 Step 2) and called with the same argument order in `confirmTool` (Task 1 Step 3): `(arena_alloc, line_ctx, fp, old_s)` → `(arena, ctx, file_path, needle)`. Returns `?usize`, unwrapped via `if (...) |ln|`.
- `start_line` is `usize` in the struct and read as `usize` in `maxLineNo`/render. `gutterWidth` returns `u16`; `gw` is `u16`; `digits` is `usize` (from `gw - 1`) as the format width expects an integer; `col_offset`/`row_offset` arithmetic (`1 + gw`, `inner_w -| gw`) stays in `u16`.
- `fg_muted` already exists (`src/code_modal.zig:10`); no new color constant is introduced.
- `agent.tools.Context` and `agent.sandbox.Sandbox` are the same types already used at `src/App.zig:850-853` and `src/App.zig:108`.

**Notes on correctness carried from exploration:**
- `matchStartLine` receives an arena (`arena_alloc` in `confirmTool`, freed on return after the dialog resolves), so it deliberately does not free `read.content` — on the `is_error` path `hostReadFile` may return a static string literal, which must not be freed with a general allocator; the arena makes this safe.
- Reading the file at confirmation time reads the **pre-edit** on-disk content, so `old_string` is present and `indexOf` finds it; if it is absent or the file is unreadable, `start_line` falls back to `1`.
- Under an active sandbox, the read routes through `sb.runArgv(... "cat" ...)` exactly as `editTool` reads, so line numbers reflect the worktree the edit will touch, not the host checkout.

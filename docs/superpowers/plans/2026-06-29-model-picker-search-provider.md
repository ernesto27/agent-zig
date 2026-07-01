# Model Picker: Search by Provider Name Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the model picker modal match the search query against the owning provider's `name` (case-insensitive), in addition to the existing `display` and `id` matches.

**Architecture:** A single `or` clause is added to the `matches` expression in `ModelPicker.refresh()` (`src/model_picker.zig`). The provider loop variable `prov` is already in scope, so no structural changes are needed. A TDD test is added to `src/model_picker.zig` covering the new behavior.

**Tech Stack:** Zig 0.15.2+, libvaxis TUI, existing `std.ascii.indexOfIgnoreCase` helper.

## Global Constraints

- Target Zig 0.15.2+ (repo standard).
- No new dependencies.
- Follow existing patterns: case-insensitive matching via `std.ascii.indexOfIgnoreCase`, no allocations in the match path.
- Commit messages are a single-line subject only, no body, no `Co-Authored-By` trailer.
- Do not commit automatically; leave changes unstaged unless asked.

---

### Task 1: Add provider-name search to the model picker

**Files:**
- Modify: `src/model_picker.zig` (the `refresh()` method, around the `matches` expression)
- Test: `src/model_picker.zig` (new `test` block at end of file)

**Interfaces:**
- Consumes: `p.providers` (`[]const Provider`), `Provider.name: []const u8`, `Model.display`/`Model.id` — all already in scope inside the existing `for (&p.providers) |*prov|` loop.
- Produces: unchanged public API of `ModelPicker.refresh`; behavior extension only (query now also matches provider name).

**Context for the test — why query `"anthropic"` is a clean TDD signal:**
- Before the fix, `refresh()` matches only `m.display` and `m.id`. Query `"anthropic"` matches exactly 2 models: the OpenRouter entries whose ids contain `"anthropic"` (`anthropic/claude-opus-4.7`, `anthropic/claude-opus-4.8`). The 3 Anthropic-provider models have ids like `claude-opus-4-6` and displays like `Claude Opus 4.6`, neither of which contains `"anthropic"`.
- After the fix, the Anthropic provider's `name` (`"Anthropic"`) also matches, adding its 3 models. Total becomes 5.
- This gives a clean before=2 / after=5 assertion.

- [ ] **Step 1: Write the failing test**

Append to `src/model_picker.zig` (after the `ModelPicker` struct's closing `};`):

```zig
const testing = std.testing;

test "model picker search matches provider name" {
    var picker = ModelPicker{};
    defer picker.deinit(testing.allocator);
    try picker.query.appendSlice(testing.allocator, "anthropic");
    try picker.refresh(testing.allocator);

    // 3 Anthropic-provider models (matched via provider name) +
    // 2 OpenRouter models whose ids contain "anthropic".
    try testing.expectEqual(@as(usize, 5), picker.results.items.len);

    // The Anthropic provider's own models must be present.
    var saw_haiku = false;
    for (picker.results.items) |m| {
        if (std.mem.eql(u8, m.id, "claude-haiku-4-5-20251001")) saw_haiku = true;
    }
    try testing.expect(saw_haiku);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — the test executable for the app module reports `model picker search matches provider name` failed because `picker.results.items.len` is `2`, not `5`. (Compilation must succeed; only the assertion fails.)

- [ ] **Step 3: Write minimal implementation**

In `src/model_picker.zig`, in `ModelPicker.refresh()`, change the `matches` expression from:

```zig
                const matches = q.len == 0 or
                    std.ascii.indexOfIgnoreCase(m.display, q) != null or
                    std.ascii.indexOfIgnoreCase(m.id, q) != null;
```

to:

```zig
                const matches = q.len == 0 or
                    std.ascii.indexOfIgnoreCase(m.display, q) != null or
                    std.ascii.indexOfIgnoreCase(m.id, q) != null or
                    std.ascii.indexOfIgnoreCase(prov.name, q) != null;
```

`prov` is the existing outer loop variable (`for (&p.providers) |*prov|`), so no other change is required.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both test executables (library `src/root.zig` and app `src/main.zig`) succeed; the new test reports 5 results and confirms `claude-haiku-4-5-20251001` is among them.

- [ ] **Step 5: Manual smoke check (optional but recommended)**

Run: `zig build run`
In the TUI, open the model picker (e.g. via the `/model` flow), type `anthropic`, and confirm all 3 Anthropic models plus the 2 OpenRouter `anthropic/...` models appear. Type `gemini` and confirm Gemini models appear. Clear the query and confirm all models are listed (unchanged empty-query behavior).

- [ ] **Step 6: Leave changes unstaged**

Per repo convention, do not commit automatically. Leave the working-tree changes unstaged for the user to review and commit. Suggested commit subject (only if/when asked):

```bash
git add src/model_picker.zig
git commit -m "match provider name in model picker search"
```

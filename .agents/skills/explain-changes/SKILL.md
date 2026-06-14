---
name: explain-changes
description: Concise walkthrough of code changes with ASCII diagrams that render in a terminal. Use when the user wants to understand a diff, PR, commit, or recent edits — "explain these changes", "walk me through this diff", "what changed and why", "explain this PR", "/explain-changes".
---

# Explain Code Changes

Explain a set of changes so a teammate can follow them without reading the diff.
Explanation only — never emit code edits. Output renders in a terminal, so
diagrams are **ASCII**, not Mermaid.

## Pick the target

Unless the user names one: explicit ref → `git diff HEAD` if non-empty → `git show HEAD`.

```bash
git diff --stat HEAD && git diff HEAD && git log --oneline -5
# PR: gh pr view <n> --json title,body,files && gh pr diff <n>
```

Read the surrounding code, not just the `+`/`-` lines. Know *why* it changed and
what breaks without it.

## Output (in this order, skip empty sections)

1. **TL;DR** — one sentence: what changed + visible effect.
2. **Why** — the problem solved. Don't invent a rationale the code/commits don't show.
3. **Change map** — table: file | what changed | why it matters.
4. **Diagram** — one ASCII diagram (see below).
5. **Walkthrough** — changes in dependency order (foundational first). Per change:
   one line on what it does, the key `file_path:line`, and any subtlety (ownership,
   error paths, ordering, lifetimes).
6. **Risks** — behavior changes, unhandled edges, TODOs, decisions left to callers.

Be terse. A one-line fix gets TL;DR + Why + a sentence. Reserve the full structure
for multi-file changes.

## ASCII diagrams

Plain text in a fenced block. Boxes with `[ ]`, flow with `-->` / `│ ▼`, mark
new/changed nodes with `*`. Keep it ≤8 nodes and name real identifiers.

Flow (function extracted, `*` = new):

```
  callerA() ─┐
             ├─> *sharedHelper() ──> externalCall()
  callerB() ─┘
```

Before/after (refactor):

```
  before:  caller() ──> [inline work]
  after:   caller()  ──┐
                       ├─> sharedHelper()   *extracted
           otherCaller()─┘
```

Module/layout (boxes):

```
  ┌─ container ──────────────┐
  │  newComponent() *         │  slot 0
  │  existingComponent()      │  slot 1+
  └───────────────────────────┘
```

Pick flow for logic/data paths, before/after for refactors, boxes for
layout/module/ownership shifts.

## Rules

- `file_path:line` for locations (clickable). Quote only lines that carry the point.
- Tables for file lists and before/after values.
- Explain a load-bearing term (arena, lifetime, comptime) in half a sentence.

## Anti-patterns

- ❌ Restating the diff line by line.
- ❌ Mermaid or any diagram that won't render in a terminal.
- ❌ A diagram that just lists files (that's the table's job).
- ❌ Inventing rationale; emitting code edits.

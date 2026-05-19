---
name: update-todo
description: Inspect current git changes (staged + unstaged) and flip matching `[]` items in TODO.md to `[x]`. Use when the user says "update todo", "mark done in todo", "/update-todo", or after finishing work that likely closed out items in the project's TODO.md.
---

# Update TODO from Git

Read the current git diff and mark off any TODO.md items that the diff actually completes. Do not add new items, do not reword, do not reorder. Only flip `[]` → `[x]`.

## Steps

1. **Locate `TODO.md`** at the repo root (`git rev-parse --show-toplevel`). If missing, stop and tell the user.

2. **Collect the change set** in this order (each adds context, none replace the others):
   - `git status --short` — which files moved
   - `git diff --stat HEAD` — size/scope of changes
   - `git diff HEAD` — actual content of staged + unstaged changes
   - If `HEAD` doesn't exist (fresh repo) fall back to `git diff --cached` and `git diff`.

3. **Read `TODO.md`** and extract every line matching `^\[\] ?- ` (unchecked items). Ignore anything already `[x]`, prose paragraphs, and the architecture/phases sections below the checklist.

4. **Match items to the diff.** For each unchecked item, decide *only* from the diff evidence whether it is now done. Require concrete proof — a new file, a function added, a config key wired up, a test passing. If the item is vague ("polish UI") and the diff is ambiguous, leave it unchecked.

   When uncertain, leave it. False positives are worse than misses — the user can always re-run.

5. **Show the user the proposed mark-offs** before writing: list each item you plan to flip and the one-line diff evidence. Ask for confirmation unless the user already said "just do it".

6. **Apply edits** with the Edit tool, one item at a time, replacing `[] - <text>` with `[x] - <text>`. Preserve exact whitespace and surrounding lines.

7. **Report**: count of items flipped, and any items you considered but rejected (one-line reason each).

## Rules

- Never add, remove, reorder, or reword TODO items.
- Never touch items below line ~65 (the architecture/phases scaffold uses `[ ]` with a space, not `[]` — different syntax, leave alone unless the user explicitly says so).
- If the diff is empty, say so and stop. Don't invent completions from commit history.
- If the user passes an argument (e.g. `/update-todo unstaged-only`), honor it: scope the diff accordingly.

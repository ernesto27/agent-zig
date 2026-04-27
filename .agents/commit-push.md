---
description: Stage all changes, commit, and push to the current branch
disable-model-invocation: true
allowed-tools: Bash(git add *) Bash(git commit *) Bash(git push *) Bash(git status *) Bash(git diff *) Bash(git log *)
argument-hint: "[commit message]"
---

Stage all changes and push to the current branch.

1. Run `git status` to see what changed.
2. Run `git add -A` to stage all changes.
3. Run `git diff --cached --stat` to review what will be committed.
4. Write the commit message:
   - If `$ARGUMENTS` is provided, use it verbatim.
   - Otherwise inspect `git diff --cached` and write a short imperative-mood summary (50 chars max subject line).
5. Commit: `git commit -m "<message>"`
6. Push: `git push`
7. Confirm with `git log --oneline -1`.

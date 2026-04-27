---
description: Commit staged changes and push to the current branch
disable-model-invocation: true
allowed-tools: Bash(git commit *) Bash(git push *) Bash(git status *) Bash(git diff *) Bash(git log *)
argument-hint: "[commit message]"
---

Commit already-staged changes and push to the current branch.

1. Run `git diff --cached --stat` to review what will be committed.
2. Write the commit message:
   - If `$ARGUMENTS` is provided, use it verbatim.
   - Otherwise inspect `git diff --cached` and write a short imperative-mood summary (50 chars max subject line).
3. Commit: `git commit -m "<message>"` — no Co-Authored-By line
4. Push: `git push`
5. Confirm with `git log --oneline -1`.

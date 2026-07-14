# Plan: Sandbox auto-commit on task completion

- **Date:** 2026-07-14
- **Domain(s):** backend (Zig TUI runtime — sandbox / agent-loop / tools subsystems)
- **Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com)
- **Status:** Implemented (with code-review fixes applied); one open item (`max_iterations`)

## 1. Summary

Today the `/sandbox` flow does all agent work inside a Docker container bound to a
throwaway git worktree on a `sandbox-<ts>` branch, but when the sandbox stops the
worktree is kept with **uncommitted** working-tree changes. This change makes the
sandbox **commit its worktree changes onto the branch when the model's task list
becomes all-completed**, so results land as a real commit instead of loose
working-tree edits. To make the trigger reliable, we also add a strong
task-tracking instruction to the system prompt so the model always maintains and
completes a `task_write` list. Finally, while a sandbox is active, file/bash tool
calls are auto-approved so the agent can work autonomously.

> **Note (2026-07-14):** during implementation `src/sandbox.zig` was refactored so
> `Sandbox.active` (and `App.sandbox_busy`) became `std.atomic.Value(bool)`. All
> code below uses `.load(.acquire)` / `.store(.release)` accordingly.

## 2. Scope

### In scope
- A host-side `Sandbox.commit(...)` that stages and commits the worktree on the
  sandbox branch (chown-first, since container writes are root-owned).
- An `onFinished` hook in `App` that fires the commit exactly once each time the
  task list transitions to all-completed, gated on `sandbox.active`.
- A commit message built from the completed task `content` strings.
- A system-prompt block instructing the model to always maintain and complete a
  `task_write` task list.
- **Auto-approve `write_file`/`edit_file`/`bash` while the sandbox is active** (no
  accept/deny prompt) — these run only inside the isolated container worktree.
- **An in-flight guard**: refuse `/sandbox` start/stop while a request is running,
  which also closes the commit-vs-teardown thread race.
- Manual verification checklist.

### Out of scope / non-goals
- Committing the real (non-sandbox) working tree — never auto-commit `master`.
- Pushing, merging, or rebasing the sandbox branch.
- Per-turn commits, or commits triggered by sandbox teardown (`stop`).
- Auto-approving **MCP** tools in sandbox mode (they can reach outside the
  container, so they still confirm).
- Fixing the pre-existing thread-spawn error-swallowing (that was fixed separately
  in the current tree).
- Git identity overrides — commits inherit the repo's existing git config.
- Unit tests (per project preference; manual verification instead).

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | When does "the task finish" fire the commit? | When the model's task list is all-completed (`TaskStore.allCompleted()`), detected in `App.onFinished`. |
| 2 | Commit granularity across a session? | Once per completion transition; re-arms when the list is no longer all-complete, so multiple plan cycles each produce a commit. |
| 3 | Commit message content? | `sandbox: <task1 content>; <task2 content>; …` (all task contents joined by `; `). |
| 4 | Git author identity? | Inherit the repo's existing git config (no `-c user.email`/`user.name` override). |
| 5 | Where does git run — host or container? | Host, against `worktree_path` (default image `ubuntu:24.04` has no git; worktree is a real host git worktree). |
| 6 | Root-owned container writes? | `chown -R <uid:gid> /workspace` via `docker exec` before git, mirroring `Sandbox.stop`. |
| 7 | Nothing to commit? | Skip cleanly (no empty commit, no notice), detected via `git diff --cached --quiet`. |
| 8 | Reliable trigger? | Strong always-on task-tracking block added to `src/prompts/system.txt` (option 3a). |
| 9 | Non-sandbox behavior? | No commit unless `sandbox.active` — the real repo is never touched. |
| 10 | Tests? | Manual verification checklist only; no unit tests. |
| 11 | Error handling in new code? | Every `catch` logs via the `.sandbox`/`.app` logger; no silent swallow. |
| 12 | Auto-approve which tools in sandbox mode? | `write_file`, `edit_file`, **and `bash`** (all run in the container). MCP tools still confirm. |
| 13 | When is the commit latch set? | Only **after `commit()` returns `true`** — a failed commit or null message retries next turn. |
| 14 | Commit-vs-teardown thread race? | Closed by refusing `/sandbox` toggle while a request is in flight and holding `loading.active` true through the commit. |
| 15 | Message-buffer cleanup on the `null` paths? | `defer buf.deinit()` (not `errdefer`, which never fires for a `?T` return). |

## 4. Design

### Trigger mechanics (already-present primitives)
- `agent_loop.run` calls `host.onFinished(outcome)` after every turn
  (`agent_loop.zig:51`), on the agent worker thread.
- `TaskStore.allCompleted()` returns true iff the list is non-empty and every task
  is `completed`.
- `self.tasks` is guarded by `self.mutex` (wired as `task_mutex` in the tool
  context). We read `allCompleted()`/task contents under that lock, then release it
  before shelling out to git.

### Control flow (final)
```
onFinished(outcome):
  lock(mutex)
    tool_status=null; clear grep/glob/web status; cancel_requested=false; needs_redraw=true
    commit_msg = null
    if sandbox.active.load(.acquire):
      if tasks.allCompleted():
        if !tasks_committed: commit_msg = buildSandboxCommitMessage()   // does NOT latch here
      else:
        tasks_committed = false                                         // re-arm for next cycle
  unlock(mutex)

  // loading.active is still true here → toggleSandbox refuses to stop the sandbox,
  // so name/branch/worktree_path can't be freed under us during the commit.
  if commit_msg != null:
    if sandbox.commit(alloc, commit_msg):        // git shells out; unlocked
      lock(mutex); tasks_committed = true; unlock(mutex)   // latch only on success
      appendNotice("🐳 committed on <branch>: <msg>")
    free(commit_msg)

  lock(mutex); loading.stop(); needs_redraw=true; unlock(mutex)   // clear AFTER commit
  wakeLoop(active_loop)
```

### Concurrency guard (races #3 and #5 from review)
- `toggleSandbox` refuses to start/stop the sandbox while `loading.active` is true
  (read under `self.mutex`).
- `onFinished` keeps `loading.active` true until **after** the commit completes.
- Result: `stopSandboxWork` → `Sandbox.stop()` cannot free `name`/`branch`/
  `worktree_path` while the commit is using them (**#3**), and an auto-approved
  tool cannot be routed to the host because `sb.active` can't flip between
  `confirmTool` and `execFor` during a turn (**#5**). Both run on the agent thread
  sequentially within one loop iteration.

### New state
- `App.tasks_committed: bool = false` — the "already committed this completion"
  latch, guarded by `self.mutex`. Self-healing: whenever the list is not
  all-complete (including empty after `clear()`), the `else` branch resets it.

### Auto-approve (feature + race #5 boundary)
- In `confirmTool`, when `sandbox.active` is true, `write_file`/`edit_file`/`bash`
  return `.approve` immediately. MCP tools and all host-mode tools are unaffected.

### git command sequence (host, in `Sandbox.commit`)
1. `docker exec <name> chown -R <uid:gid> /workspace` (best-effort; log on failure).
2. `git -C <worktree_path> add -A`.
3. `git -C <worktree_path> diff --cached --quiet` → exit 0 → nothing staged → `false`.
4. `git -C <worktree_path> commit -m "<message>"` (identity from repo config).

## 5. Interfaces & contracts

### `Sandbox.commit(alloc, message) bool`
- **Input:** `message` — a single-line commit subject (one argv arg to
  `git commit -m`, no shell escaping).
- **Output:** `true` iff a commit was created; `false` if inactive, nothing to
  commit, or a git step failed (failures are logged).
- **Side effects:** chowns `/workspace` back to the host user; stages and commits
  the worktree on the current sandbox branch.

### `App.buildSandboxCommitMessage() ?[]const u8`
- **Precondition:** called with `self.mutex` held and `tasks.allCompleted()` true.
- **Output:** heap slice owned by the caller, `"sandbox: a; b; c"`; `null` on OOM
  (logged). Uses `defer buf.deinit()` so `null` paths don't leak.

## 6. Behavior & states

- **Latch state machine** (`tasks_committed`):
  - `false` + list all-complete + sandbox active → build message, run `commit()`;
    set `true` **only if `commit()` returned `true`**.
  - `true` + list still all-complete → no-op (no duplicate commits).
  - any state + list not all-complete → reset to `false` (re-arm).
- **Idempotency:** the `git diff --cached --quiet` guard prevents empty commits;
  the latch prevents repeat commits for the same completion.
- **Retry:** a failed `commit()` (transient git error) or a `null` message leaves
  the latch `false`, so the next turn retries.
- **Edge cases:**
  - Sandbox off → never commits (real repo untouched).
  - Empty task list → `allCompleted()` is `false` → no commit, latch stays reset.
  - Tasks completed with no file edits → `add -A` stages nothing →
    `diff --cached --quiet` exits 0 → skipped (re-checked harmlessly on later
    turns, one info log each).
  - New plan cycle in the same session (add tasks → complete them) → latch reset
    when the new pending tasks appeared → commits again.

## 7. Implementation tasks

> All tasks are **applied** in the working tree. Snippets below reflect the final
> code (atomic `active`, `defer` cleanup, latch-on-success).

### Task 1 — `Sandbox.commit` + `indexClean` (`src/sandbox.zig`)
- **Why:** encapsulate git/docker commit mechanics in the sandbox module.
- **Applied:** new `pub fn commit(self: *const Self, alloc, message) bool` after
  `stop`, plus file-scoped `fn indexClean(alloc, wt) bool` next to `runQuiet`.
  Uses `self.active.load(.acquire)`, `checked(...) catch |err| log.err(...)`, and
  skips when `indexClean` is true.

### Task 2 — `tasks_committed` latch field (`src/App.zig`)
- **Why:** track whether the current all-completed state already committed.
- **Applied:** `tasks_committed: bool = false` next to the sandbox fields, guarded
  by `mutex` (comment notes the guard).

### Task 3 — `buildSandboxCommitMessage` (`src/App.zig`)
- **Why:** decision 3 — the commit subject lists what was done.
- **Applied:** joins `self.tasks.items.items[*].content` as `sandbox: a; b; c`.
  Uses `defer buf.deinit(self.alloc)` (fix for review #4: `errdefer` never fires on
  a `?T` return). Returns `null` on OOM (logged).

### Task 4 — Fire the commit from `onFinished` (`src/App.zig`)
- **Why:** trigger point (option C); also holds the concurrency guard.
- **Applied:** snapshot `commit_msg` under the lock (no latch there); run
  `sandbox.commit` unlocked; **latch only on success** under the lock; move
  `loading.stop()` to **after** the commit so `loading.active` covers the whole
  commit window.

### Task 5 — Reset the latch on `tasks.clear()` (`src/App.zig`)
- **Applied:** `self.tasks_committed = false;` after both `self.tasks.clear();`
  sites (replace-all).

### Task 6 — Always-on task-tracking guidance (`src/prompts/system.txt`)
- **Applied:** new "Task tracking:" section before "Communication:" instructing the
  model to maintain a `task_write` list and mark every task completed before
  finishing.

### Task 7 — Auto-approve file/bash tools in sandbox mode (`src/App.zig`)
- **Why:** the user wants the agent to run autonomously in the sandbox without
  accept/deny prompts; this is also the security boundary re-checked by the
  in-flight guard (review #5).
- **Applied:** in `confirmTool`, after `tool` is resolved:
  ```zig
  if (self.sandbox.active.load(.acquire) and
      (tool == .write_file or tool == .edit_file or tool == .bash))
      return .approve;
  ```
  MCP tools still confirm.

### Task 8 — In-flight toggle guard (`src/App.zig`)
- **Why:** close the commit-vs-teardown race (#3) and the auto-approve/teardown
  race (#5).
- **Applied:** at the top of `toggleSandbox` (after the `sandbox_busy` check),
  refuse when a request is in flight:
  ```zig
  self.mutex.lock();
  const request_in_flight = self.loading.active;
  self.mutex.unlock();
  if (request_in_flight) {
      self.appendNotice("🐳 finish or cancel (Esc) the current request before toggling the sandbox");
      return;
  }
  ```

## 8. Testing

No unit tests (per project preference). **Manual verification** — user runs each
step and inspects output/logs:

1. **Happy path — commit fires.** `zig build run` → `/sandbox` → ask for a small
   multi-step change so the model uses `task_write` and completes all tasks. Expect
   `🐳 committed on sandbox-…: sandbox: …`; verify with
   `git -C ~/.config/agent-zig/worktrees/<repo>/sandbox-<ts> log --oneline -1`.
2. **No duplicate commit.** Another prompt with no new tasks → no new commit.
3. **Second cycle re-arms.** Another multi-step change → a second commit lands.
4. **Nothing to commit.** Tasks completed without file edits → no commit; `agent.log`
   shows "nothing to commit".
5. **Sandbox off → real repo untouched.** Drive a task on the host (no `/sandbox`) →
   no commit on `master`.
6. **Identity.** New commit author matches `git config user.name`/`user.email`.
7. **Auto-approve.** In sandbox mode, a file edit and a `bash` call apply with **no**
   accept/deny prompt; without sandbox, both still prompt. MCP still prompts.
8. **In-flight toggle guard.** While a request is running, `/sandbox` on/off prints
   "finish or cancel (Esc) the current request…" and does nothing; after the turn
   (or after Esc), toggling works.
9. **Logs.** `agent.log` shows `.sandbox`/`.app` info/err lines, no silent failures.

## 9. Acceptance criteria

- Completing the task list in a sandbox produces exactly one commit on
  `sandbox-<ts>` with subject `sandbox: <task contents joined by "; ">` — step 1.
- Repeated turns without new tasks add no commits — step 2; a fresh cycle commits
  again — step 3; no-file-change completions create no commit — step 4.
- The real (non-sandbox) tree is never auto-committed — step 5.
- Commits use the repo's git identity — step 6.
- Sandbox file/bash tools auto-approve; MCP/host tools still confirm — step 7.
- The sandbox cannot be toggled mid-request — step 8.
- No new `catch` swallows errors — step 9.

## 10. Risks & open items

- **OPEN — `max_iterations` cap too low.** The agent loop stops after
  `Options.max_iterations` turns (`agent_loop.zig:17`, default **10**); the app
  calls `agent_loop.run(..., .{})` at `App.zig` so it uses the default. Multi-step
  sandbox plans exceed 10 turns and stop mid-task before the task list completes
  (so no commit fires). **Decision pending:** bump the default in `agent_loop.zig`
  vs. override at the call site, and the value (recommendation: 50). Config-field
  approach was rejected.
- **RESOLVED — thread race on `self.sandbox` during commit (review #3) and
  auto-approve/teardown race (#5).** Closed by the in-flight toggle guard (Task 8)
  plus holding `loading.active` through the commit and the atomic `active` field.
- **RESOLVED — latch set before commit outcome (review #4).** Latch now set only
  after `commit()` returns `true`.
- **RESOLVED — buffer leak on `null` paths (review, `buildSandboxCommitMessage`).**
  `errdefer` → `defer`.
- **Model must actually use `task_write`.** The trigger depends on the model
  maintaining and completing the list. Task 6 strengthens this via the system
  prompt, but a model that ignores task tracking will not auto-commit; the worktree
  is still kept for manual review.
- **Sandbox image lacks a toolchain.** The default image `ubuntu:24.04` has no
  `zig`/`git`; a model "build & verify" step inside the sandbox will fail. If in-
  container builds are desired, set `dockerImage` to an image with the toolchain
  (and build in `/workspace`). The commit itself runs on the host, so it is
  unaffected.
- **Tests:** no unit tests by decision; correctness rests on the §8 checklist.

# Plan: Headless Print Mode (`-p` / `--print`)

- **Date:** 2026-06-24
- **Domain(s):** backend / CLI
- **Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com)
- **Status:** Draft

## 1. Summary

Add a non-interactive, one-shot query mode to `agent-zig`. Invoking
`agent-zig -p "<prompt>"` (or `--print`, or `zig build run -- -p "<prompt>"`)
runs the full agentic think→tool→loop against the configured provider/model
**without ever starting the TUI**, prints the final assistant answer to stdout,
and exits. This makes the agent scriptable and pipe-friendly for quick Q&A and
automation, reusing the existing LLM client, tool registry, system prompt, and
skills — but bypassing all the TUI/vaxis machinery, the interactive
tool-confirmation handshake, MCP loading, sessions, and the folder-trust gate.

## 2. Scope

### In scope
- A `-p` / `--print` flag handled in `main.zig` **before** any TUI/logger-of-record
  setup, dispatching into a new self-contained runner.
- A new `src/cli/print.zig` containing the headless entrypoint + a tiny headless
  `Host`.
- **Extracting the agentic loop into a shared, UI-agnostic engine**
  (`src/agent_loop.zig`) that both the TUI (`App.fetchAiResponse`) and the
  headless path drive via a `Host` interface — so the loop logic lives in exactly
  one place.
- Full built-in tool set available and **auto-approved** (no confirmation),
  including `write_file` / `edit_file` / `bash`, in build mode, on the real cwd
  (sandbox inactive).
- Buffered output: accumulate, then print only the final assistant turn's text
  to stdout once, followed by a trailing newline.
- Clean error handling with non-zero exit codes for missing prompt, unconfigured
  provider/API key, and LLM/network failure.

### Out of scope / non-goals
- **No stdin fallback** (`echo … | agent-zig -p`) — flag-with-arg only this round.
- **No streaming/live output**, **no JSON output** — buffered plain text only.
- **No MCP** servers loaded.
- **No session persistence** — ephemeral; nothing written under `sessions/`.
- **No folder-trust enforcement** — the shell invocation is the consent.
- **No `-m`/model-override or provider-override flag** — uses the config's
  selected model as-is.
- **No automated tests** (see §8 and §10) — manual verification only.
- No change to the existing bare-positional behavior (still opens the TUI
  prefilled, per commit `7b14fa0`).
- **No behavior change to the TUI.** `App.fetchAiResponse` is rewritten to
  *delegate* to the shared engine, but its observable behavior (streaming,
  confirmation, status, queue, sessions, error bubbles) must be byte-for-byte
  preserved.

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Invocation syntax | `-p` / `--print` flag followed by the prompt arg. Bare positional still opens the TUI prefilled. |
| 2 | Prompt source | The single CLI arg after the flag. No stdin support in this round. |
| 3 | Missing/empty prompt | Print a one-line usage error to stderr; exit 1. |
| 4 | Tool policy | Full tool set, **all auto-approved**, no confirmation (build mode). |
| 5 | Sandbox | Inactive — filesystem tools and `bash` run directly on the real cwd. |
| 6 | Output format | Buffered; print only the final assistant turn's text, once, then exit. |
| 7 | Diagnostics destination | Tool/loop diagnostics go to `~/.config/agent-zig/agent.log` as usual; **never** stderr. Only hard errors print to stderr. |
| 8 | MCP servers | Skipped — not loaded in headless mode. |
| 9 | Folder trust | Bypassed; running the command is itself the consent. |
| 10 | Sessions | Ephemeral — no session file written, no `/resume` registration. |
| 11 | Skills | Loaded (cheap local file reads) so the `skill` tool works. |
| 12 | Mode | Build mode (matches "all tools auto-approved"). |
| 13 | Provider/model | Reuse config's `providers.selected` + matching provider creds/effort, exactly as `main.zig:94-109`. |
| 14 | Cancellation | `should_cancel` always returns `false`; Ctrl+C kills the process. |
| 15 | Max iterations | Reuse the same cap as the TUI (10), via `Options.max_iterations`. |
| 16 | Exit codes | 0 on success; 1 on missing prompt, config/provider error, or LLM failure. |
| 17 | Testing | None — matches the standing "no tests unless asked" preference. Justified in §10. |
| 18 | Dispatch location | Special-cased in `main.zig` (not via `cli.dispatch`, whose `fn(Allocator)` signature can't take the prompt arg). |
| 19 | Code reuse | **Full shared loop engine.** Extract the agentic loop into `src/agent_loop.zig`; both `App.fetchAiResponse` and headless `print.run` drive it via a comptime-generic `Host` interface (required methods + `@hasDecl` optional hooks). No copy-pasted loop. |

## 4. Design

### Module layout
- **`src/cli/print.zig`** (new) — owns the headless runner. Public entry:
  ```zig
  pub fn run(allocator: std.mem.Allocator, prompt: []const u8) !void
  ```
  Internally it:
  1. Initializes the file logger (`log_mod.Logger.init`) so diagnostics land in
     `agent.log`, mirroring `main.zig:64`.
  2. Loads config via `agent.config.ConfigStore.init`; on failure prints a
     descriptive error to stderr and returns an error.
  3. Builds `agent.llm.Config` and `agent.llm.Client` using the exact wiring from
     `main.zig:94-109` (selected model → provider → base_url/api_key/effort).
     If no provider/model resolves or creds are empty, error out to stderr.
  4. Loads the system prompt (`agent.system_prompt.SystemPrompt.readContent`) and
     skills (`agent.skills.Registry.init` + `.load`).
  5. Builds tool defs + a build-mode system prompt and seeds a small headless
     `Host` (reused `messages.Messages` + inert `Sessions{}`) with the user message.
  6. Calls `agent_loop.run(...)` and prints the `Host`'s captured final answer.

- **`src/main.zig`** — gains a small branch in the existing arg handling
  (around lines 56-62): if `args[1]` equals `-p` or `--print`, treat `args[2]`
  as the prompt, call `print.run(alloc, prompt)`, and `return` (never entering
  TUI setup). Missing `args[2]` → usage error to stderr + exit 1.

### Shared loop engine — `src/agent_loop.zig`
The agentic think→tool→loop is extracted **once** into a UI-agnostic engine.
Both the TUI and the headless path provide a `Host` and call:

```zig
pub fn run(
    comptime Host: type,
    host: *Host,
    alloc: std.mem.Allocator,
    client: *agent.llm.Client,
    tool_ctx: agent.tools.Context,
    tool_defs: []const agent.llm.message.ToolDefinition,
    system: ?[]const u8,
    opts: Options,
) Outcome
```

The engine owns the **algorithm** (send → split response → terminal-vs-tool
branch → deep-copy assistant blocks → execute tools → push results → repeat) and
the two pure helpers (`splitResponse`, `dupeAssistantBlocks`). It owns **none of
the side-effects** — those are delegated to `Host`. History is accessed only
through `host.historyItems()` / `host.pushHistory()`, so the engine never
imports `messages.zig` and never touches a mutex.

**Why comptime-generic `Host` (not a runtime vtable):** both call sites are known
at compile time; a `comptime Host: type` is the idiom the project's Zig guidance
prefers over `anytype`/`*anyopaque` tables, gives zero-cost dispatch and clear
errors, and lets the engine skip TUI-only hooks the headless Host doesn't define
via `@hasDecl`. The streaming callbacks (which the client demands as
`*const fn(*anyopaque, …)`) are bridged with tiny trampolines that cast the ctx
back to `*Host` and call the method.

**Locking lives in the Host, not the engine.** The engine reads
`host.historyItems()` only from the calling thread (the sole writer of
`llm_history`), and every write goes through `host.pushHistory()`, which self-
locks if needed. So the engine has *no* `lock`/`unlock` in its interface — this
is what keeps the TUI's mutex discipline intact without leaking into the engine.

#### `Host` interface
Required (both Hosts implement):
- `fn historyItems(*Host) []const agent.llm.message.Message`
- `fn pushHistory(*Host, agent.llm.message.Message) void` — append to history (+ persist/UI-mirror/lock as the Host sees fit)
- `fn onChunk(*Host, []const u8) void` / `fn onThinkingChunk(*Host, []const u8) void`
- `fn shouldCancel(*Host) bool`
- `fn isToolAllowed(*Host, []const u8, std.json.Value) mode.ToolPolicy`
- `fn confirmTool(*Host, []const u8, std.json.Value) Decision` (`.approve` | `.deny`)

Optional (engine calls only `if (@hasDecl(Host, …))`; the headless `Host`
implements just `onRequestError`, omits the rest):
- `onUsage(agent.llm.message.Usage)` — context-usage telemetry
- `onToolActivity([]const u8, std.json.Value)` — grep/glob/web/spinner status
- `onToolResult([]const u8, std.json.Value, agent.tools.ToolResult)` — skill notices
- `onToolsComplete()` — clear `tool_status` between iterations
- `dequeueFollowUp() ?[]u8` — pull a queued user message to continue the loop
- `onRequestError(anyerror)` — render/print the LLM-failure case
- `onFinished(Outcome)` — stop spinner, clear status, wake loop

`Outcome = enum { completed, cancelled, denied, max_iterations, request_failed }`.

### How each side maps onto the engine
- **TUI (`App` is the `Host`):** the existing private methods become the hook
  bodies — `onChunk`/`onThinkingChunk`/`shouldCancel` (today's `StreamCtx`
  callbacks), `confirmTool` (the `tool_confirmation` + `Condition.wait` block,
  incl. the sticky `accept_all`), `onToolActivity` (`setGrepStatus`/`setGlobStatus`/
  `setWebStatus`), `onToolResult` (skill notices), `dequeueFollowUp`
  (`message_queue`), `onUsage` (`context_usage`), `onRequestError` (error bubble),
  `onFinished` (`loading.stop` + clears + `wakeLoop`). `App` gains an
  `active_loop: ?*EventLoop` field so the hooks can `wakeLoop` without threading
  `loop` through the engine. `fetchAiResponse` keeps its TUI-only **pre-loop**
  (building the user message from attachments) and then calls `agent_loop.run`.
- **Headless (`print.zig`'s tiny `Host`):** implements the 6 required methods +
  `onRequestError` — `historyItems`/`pushHistory` delegate to a reused
  `messages.Messages` + inert `sessions.Sessions{}`; `onChunk`/`onThinkingChunk`
  are no-ops; `shouldCancel` returns `false`; `isToolAllowed` returns
  `.{ .ok = true }` (build mode); `confirmTool` returns `.approve`;
  `onRequestError` prints `error: LLM request failed: …` to stderr. It captures
  the final answer by recording the last assistant `.text` it sees in
  `pushHistory`.

### Memory management
- Headless reuses `messages.Messages` for history, so it inherits the TUI's exact
  ownership/free model (`Messages.deinit(alloc)`) instead of a parallel one —
  history blocks are `alloc`-owned (gpa), freed on deinit.
- A short-lived arena holds `tool_defs` + per-turn scratch (as in
  `fetchAiResponse:621`); the engine deep-copies assistant blocks into the
  caller's `alloc` (via `pushHistory`) **before** `resp.deinit()` frees the
  response arena — preserving the ordering at `App.zig:763-783`.

### Output
- Use the std stdout pattern from `root.zig:bufferedPrint`
  (`std.fs.File.stdout().writer(&buf)` → `.interface` → `.print` → `.flush()`).
- Print the text of the **terminal** assistant turn (the response whose
  `stop_reason != "tool_use"`), then a trailing `\n`, then flush.
- Errors use `std.debug.print` (→ stderr), consistent with `cli/update.zig`
  and `cli/remove.zig`.

## 5. Interfaces & contracts

### CLI
| Invocation | Behavior |
|---|---|
| `agent-zig -p "<prompt>"` | Headless run; final answer to stdout; exit 0. |
| `agent-zig --print "<prompt>"` | Same as `-p`. |
| `zig build run -- -p "<prompt>"` | Same (args forwarded after `--`). |
| `agent-zig -p` (no prompt) | `error: -p/--print requires a prompt argument` to stderr; exit 1. |
| `agent-zig -p ""` (empty) | Same usage error; exit 1. |
| `agent-zig "<prompt>"` (no flag) | Unchanged: opens TUI prefilled with the prompt. |

### Public function
```zig
// src/cli/print.zig
pub fn run(allocator: std.mem.Allocator, prompt: []const u8) !void;
```
- Returns `void` on success (after printing + flushing stdout).
- Returns an error after printing a stderr diagnostic for: config load failure,
  unresolved/unconfigured provider or empty API key, and LLM/network failure.
- `main.zig` maps any returned error to `std.process.exit(1)` (mirroring how
  `cli.dispatch` exits non-zero on command failure).

### stdout / stderr contract
- **stdout**: exactly the final answer text + one trailing newline. Nothing else.
- **stderr**: only hard-error messages.
- **agent.log**: full request/response/tool diagnostics (unchanged logging).

## 6. Behavior & states

The loop lives in `agent_loop.run` (max iterations from `Options`, default 10).
Per iteration:

1. Read `host.historyItems()` and call `client.sendMessageStreaming(...)`, bridging
   `host.onChunk`/`onThinkingChunk`/`shouldCancel` through trampolines.
2. `if (@hasDecl) host.onUsage(response.usage)`. Split the response into
   accumulated text + `tool_use` list (`splitResponse`).
3. Inspect `response.stop_reason`:
   - **Not `tool_use`** (or no tool_use blocks): push the assistant text via
     `host.pushHistory` (if non-empty); then `if (@hasDecl) host.dequeueFollowUp()`
     — if it returns a queued message, push it as a user turn and continue;
     otherwise finish with `Outcome.completed`.
   - **`tool_use`**: deep-copy the assistant content blocks
     (`dupeAssistantBlocks`) and push them; for each tool, check
     `host.isToolAllowed` then `host.confirmTool`; `if (@hasDecl)
     host.onToolActivity`; `tools.execute`; `if (@hasDecl) host.onToolResult`;
     collect a `tool_result_blocks` user message and push it. If any tool was
     denied → finish with `Outcome.denied`. Else `if (@hasDecl)
     host.onToolsComplete()` and loop.
4. On `sendMessageStreaming` failure: `error.RequestCancelled` →
   `Outcome.cancelled`; otherwise `if (@hasDecl) host.onRequestError(err)` →
   `Outcome.request_failed`. Loop exhaustion → `Outcome.max_iterations`.
5. Before returning, `if (@hasDecl) host.onFinished(outcome)`.

**Headless specifics on top of the shared loop:** the final answer is the last
assistant `.text` recorded by the headless `Host` during `pushHistory`. After
`run` returns: `request_failed` → already printed to stderr, exit 1;
`completed`/`max_iterations` with text → print it (+ newline) and exit 0; no text
→ stderr note, exit 1.

Edge cases:
- **Tool execution error**: not fatal — fed back to the model as a
  `tool_result` with `is_error = true` (same as the TUI), loop continues.
- **No text in final turn** (e.g., model ended on tools only): print nothing to
  stdout, emit a stderr note, exit 1.
- **Network/LLM error** from `sendMessageStreaming`: print
  `error: LLM request failed: <name>` to stderr, exit 1 (no "try later" UI
  bubble — that's TUI-only).
- **Idempotency**: N/A — one-shot, stateless across runs (ephemeral).

## 7. Implementation tasks

Ordered so the risky refactor is proven against the *existing* TUI before the new
feature rides on it:

- [ ] **Task 1 — Create `src/agent_loop.zig`.** Define `Outcome`, `Decision`,
  `Options`, the comptime-generic `run(Host, …)`, the streaming trampolines, and
  the pure helpers `splitResponse` / `dupeAssistantBlocks` (moved out of
  `App.zig`). No call sites yet — it compiles standalone.
- [ ] **Task 2 — Make `App` a `Host` and delegate.** Add `active_loop:
  ?*EventLoop` to `App`. Turn the `StreamCtx` callbacks into `App.onChunk`/
  `onThinkingChunk`/`shouldCancel` methods; add `historyItems`, `pushHistory`
  (the locked `messages.pushHistory` + `needs_redraw`), `isToolAllowed`,
  `confirmTool` (the existing confirmation block), `onToolActivity`,
  `onToolResult`, `dequeueFollowUp`, `onUsage`, `onRequestError`, `onFinished`.
  Rewrite `fetchAiResponse` to keep its pre-loop (attachment → user message) then
  call `agent_loop.run(App, self, …)`. **Verify the TUI is unchanged** (`zig
  build run`, exercise streaming/tools/confirm/queue/sessions).
- [ ] **Task 3 — `src/cli/print.zig` setup + headless `Host`.** `pub fn
  run(allocator, prompt)`: init logger, load `ConfigStore`, build
  `llm.Config`/`llm.Client` (port `main.zig:94-109`), load system prompt +
  skills, validate provider/creds (stderr + error on failure). Define the small
  headless `Host` (reused `messages.Messages` + inert `sessions.Sessions{}`;
  no-op stream sinks; `confirmTool`→approve; `isToolAllowed`→ok; `onRequestError`
  prints; captures final `.text`).
- [ ] **Task 4 — Drive the engine + output.** Seed the user message, build
  `tool_ctx`/`tool_defs`/`system` (build mode), call `agent_loop.run`, then map
  `Outcome` to stdout/stderr/exit per §6 (buffered final answer + trailing
  newline via the `root.zig` stdout pattern).
- [ ] **Task 5 — Wire dispatch in `main.zig`.** Add the `-p`/`--print` branch in
  the `args.len > 1` block before `cli.dispatch`: extract `args[2]`, handle
  missing prompt, call `print.run`, map errors to `exit(1)`, `return`. Add
  `const print = @import("cli/print.zig");`.
- [ ] **Task 6 — Memory + build hygiene.** `defer`/`errdefer` for
  `Client`/`ConfigStore`/registries/`Messages` on all paths; confirm `zig build`
  and `zig build test` are clean.
- [ ] **Task 7 — Docs touch-up.** Update `CLAUDE.md` (UI Commands / behavior
  notes) for `-p`/`--print`. Keep `src/prompts/system.txt` unchanged.

## 8. Testing

**No automated tests** are added, per the standing "no tests unless asked"
preference (recorded in §10 as the justification for omitting the otherwise-
mandatory unit + integration tasks).

**Manual verification** (the acceptance gate instead):
- `zig build` compiles clean; `zig build test` still passes (no regressions).
- **TUI unchanged** after the refactor: `zig build run` and exercise streaming, a
  tool confirmation (incl. "accept all"), grep/web status, a queued follow-up
  message, `/resume` sessions, and a forced LLM error (error bubble shows).
- `zig build run -- -p "how compile go code works"` prints a coherent answer to
  stdout and exits 0; nothing extraneous on stdout.
- `zig build run -- --print "list the files in src and summarize main.zig"`
  exercises read-only tools and returns a summary.
- A prompt that triggers a write/bash tool confirms tools run **without** a
  confirmation prompt (auto-approved) and on the real cwd.
- `zig build run -- -p` (no prompt) prints the usage error to stderr and exits 1.
- With an unconfigured/empty provider key, the run prints a config error to
  stderr and exits 1.
- `agent-zig "hello"` (no flag) still opens the TUI prefilled — unchanged.
- Confirm diagnostics appear in `~/.config/agent-zig/agent.log`, not on stderr.

## 9. Acceptance criteria

1. `agent-zig -p "<prompt>"` and `--print` run headlessly, print the final
   answer to stdout, and exit 0 — verified manually.
2. The TUI never initializes on the `-p` path (no alt-screen flicker; works when
   stdout is a pipe/redirect).
3. Tools execute without any confirmation prompt; build-mode full tool set is
   available; sandbox is inactive (real cwd).
4. MCP servers are not loaded; no session file is created; the trust gate does
   not fire.
5. Missing prompt, config/provider error, and LLM failure each exit non-zero
   with a stderr message; success exits 0.
6. stdout contains only the answer (+ trailing newline); diagnostics are in
   `agent.log`.
7. Existing bare-positional TUI prefill behavior is unchanged, and the TUI's
   streaming/confirmation/status/queue/session behavior is preserved.

## 10. Risks & open items

- **Tests omitted by user preference.** Per the standing "no tests unless asked"
  rule, no unit or integration tests are added, despite the plan-from-spec
  default of mandating both. Mitigation: the manual verification checklist in §8
  is the acceptance gate. If desired later, the natural additions are: pure unit
  tests for `splitResponse` / `dupeAssistantBlocks` (now isolated in
  `agent_loop.zig`), arg-parsing tests, and an integration test driving the
  headless `Host` through `agent_loop.run` against the local mock-server pattern
  (`localhost:9999`) used in `src/llm/client.zig` tests.
- **TUI regression risk from the `fetchAiResponse` rewrite.** Sharing the loop
  means rewriting the app's hottest, concurrency-sensitive function to delegate
  to `agent_loop.run`. Mitigations: locking stays *inside* `App.pushHistory`/
  `onChunk` (the engine adds no locking and holds no lock across the network
  call, preserving today's discipline); Task 2 lands and is verified against the
  live TUI **before** the headless feature is built on top (streaming,
  confirmation incl. sticky `accept_all`, grep/glob/web status, queued
  follow-ups, sessions, and the error-bubble path all re-checked); and the engine
  is behavior-preserving by construction — it calls the same hooks in the same
  order as the current inline code.
- **Wide `Host` interface.** 6 required + 7 optional methods is broad, but each
  maps 1:1 to a real seam in `fetchAiResponse`; the optional hooks use `@hasDecl`
  so the headless `Host` stays small. Accepted as the cost of single-sourcing the
  loop.
- **Auto-approved destructive tools.** `bash`/`write_file`/`edit_file` run with
  no confirmation and no sandbox on the real cwd. This is the explicitly chosen
  behavior (invocation = consent); documented in `CLAUDE.md` so the safety
  trade-off is discoverable.

## 11. Proposed code changes

> Proposed only — not yet applied to the source tree. Identifiers checked against
> the current code: `tools.Context` fields are optional/default-`null` (so the
> headless tool ctx means *no MCP* + *host execution*); `tools.getDefinitions`/
> `execute`, `llm.Client.sendMessageStreaming`, `llm.providers.findModel`,
> `config.ConfigStore`, `system_prompt.SystemPrompt`, `skills.Registry`,
> `messages.Messages` (`historyItems`/`pushHistory`/`deinit`), `sessions.Sessions`
> (inert by default — `appendMessage` returns when `file`/`pending_path` are
> null), `mode.Mode.buildSystemPrompt`/`ToolPolicy`, and `log.Logger` all match.
> No `build.zig` change is needed (`run` forwards args after `--`,
> `build.zig:128-130`).

### 11.1 New file — `src/agent_loop.zig` (the shared engine)

```zig
const std = @import("std");
const agent = @import("agent");

const log = std.log.scoped(.agent_loop);

pub const Decision = enum { approve, deny };

pub const Outcome = enum {
    completed,
    cancelled,
    denied,
    max_iterations,
    request_failed,
};

pub const Options = struct {
    max_iterations: usize = 10,
};

const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value, // borrows the response arena; valid until resp.deinit()
};

const Turn = struct {
    text: []u8,
    tool_uses: []ToolUse,

    fn deinit(self: *Turn, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        for (self.tool_uses) |tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
        }
        alloc.free(self.tool_uses);
    }
};

/// Run the agentic think→tool→loop. `Host` supplies every side-effect (see the
/// plan's §4 for the contract); the engine owns only the control flow. The
/// `onFinished` hook (if present) always fires exactly once with the Outcome.
pub fn run(
    comptime Host: type,
    host: *Host,
    alloc: std.mem.Allocator,
    client: *agent.llm.Client,
    tool_ctx: agent.tools.Context,
    tool_defs: []const agent.llm.message.ToolDefinition,
    system: ?[]const u8,
    opts: Options,
) Outcome {
    const outcome = drive(Host, host, alloc, client, tool_ctx, tool_defs, system, opts);
    if (comptime @hasDecl(Host, "onFinished")) host.onFinished(outcome);
    return outcome;
}

fn drive(
    comptime Host: type,
    host: *Host,
    alloc: std.mem.Allocator,
    client: *agent.llm.Client,
    tool_ctx: agent.tools.Context,
    tool_defs: []const agent.llm.message.ToolDefinition,
    system: ?[]const u8,
    opts: Options,
) Outcome {
    const Tramp = Trampolines(Host);

    var iteration: usize = 0;
    while (iteration < opts.max_iterations) : (iteration += 1) {
        log.info("loop iteration {d}", .{iteration});

        const resp = client.sendMessageStreaming(
            alloc,
            host.historyItems(),
            tool_defs,
            system,
            host, // *Host coerces to *anyopaque ctx
            Tramp.onChunk,
            Tramp.onThinkingChunk,
            Tramp.shouldCancel,
        ) catch |err| {
            if (err == error.RequestCancelled) return .cancelled;
            log.err("sendMessageStreaming failed: {}", .{err});
            if (comptime @hasDecl(Host, "onRequestError")) host.onRequestError(err);
            return .request_failed;
        };
        defer resp.deinit();
        const response = resp.value;

        if (comptime @hasDecl(Host, "onUsage")) host.onUsage(response.usage);

        var turn = splitResponse(alloc, response) catch return .request_failed;
        defer turn.deinit(alloc);

        const is_tool_use = if (response.stop_reason) |sr|
            std.mem.eql(u8, sr, "tool_use")
        else
            false;

        if (!is_tool_use or turn.tool_uses.len == 0) {
            if (turn.text.len > 0) {
                const owned = alloc.dupe(u8, turn.text) catch return .completed;
                host.pushHistory(.{ .role = .assistant, .content = .{ .text = owned } });
            }
            if (comptime @hasDecl(Host, "dequeueFollowUp")) {
                if (host.dequeueFollowUp()) |queued| {
                    // Ownership of `queued` moves into history.
                    host.pushHistory(.{ .role = .user, .content = .{ .text = queued } });
                    continue;
                }
            }
            return .completed;
        }

        // Assistant requested tools: record its blocks (deep-copied so they
        // outlive resp.deinit()), then execute.
        const blocks = dupeAssistantBlocks(alloc, response.content) catch return .request_failed;
        host.pushHistory(.{ .role = .assistant, .content = .{ .content_blocks = blocks } });

        const results = alloc.alloc(agent.llm.message.ToolResultBlock, turn.tool_uses.len) catch return .request_failed;
        var any_denied = false;
        for (turn.tool_uses, 0..) |tu, i| {
            const policy = host.isToolAllowed(tu.name, tu.input);
            if (!policy.ok) {
                results[i] = deniedBlock(alloc, tu.id, policy.reason);
                any_denied = true;
                continue;
            }
            if (host.confirmTool(tu.name, tu.input) == .deny) {
                results[i] = deniedBlock(alloc, tu.id, "User denied permission");
                any_denied = true;
                continue;
            }
            if (comptime @hasDecl(Host, "onToolActivity")) host.onToolActivity(tu.name, tu.input);
            const r = agent.tools.execute(alloc, tool_ctx, tu.name, tu.input);
            if (comptime @hasDecl(Host, "onToolResult")) host.onToolResult(tu.name, tu.input, r);
            results[i] = .{
                .tool_use_id = alloc.dupe(u8, tu.id) catch tu.id,
                .content = r.content,
                .is_error = r.is_error,
            };
        }
        host.pushHistory(.{ .role = .user, .content = .{ .tool_result_blocks = results } });

        if (any_denied) return .denied;
        if (comptime @hasDecl(Host, "onToolsComplete")) host.onToolsComplete();
    }
    return .max_iterations;
}

fn deniedBlock(alloc: std.mem.Allocator, id: []const u8, reason: []const u8) agent.llm.message.ToolResultBlock {
    return .{
        .tool_use_id = alloc.dupe(u8, id) catch id,
        .content = reason,
        .is_error = true,
    };
}

/// Bridges the client's `*anyopaque`-style streaming callbacks to `Host` methods.
fn Trampolines(comptime Host: type) type {
    return struct {
        fn onChunk(ctx: *anyopaque, chunk: []const u8) void {
            self(ctx).onChunk(chunk);
        }
        fn onThinkingChunk(ctx: *anyopaque, chunk: []const u8) void {
            self(ctx).onThinkingChunk(chunk);
        }
        fn shouldCancel(ctx: *anyopaque) bool {
            return self(ctx).shouldCancel();
        }
        inline fn self(ctx: *anyopaque) *Host {
            return @ptrCast(@alignCast(ctx));
        }
    };
}

/// Accumulate text + collect tool_use blocks from one response. Returned slices
/// are owned by `alloc`; each `ToolUse.input` borrows the response arena.
fn splitResponse(alloc: std.mem.Allocator, response: agent.llm.message.MessagesResponse) !Turn {
    var text_buf: std.ArrayList(u8) = .{};
    errdefer text_buf.deinit(alloc);
    var tool_uses: std.ArrayList(ToolUse) = .{};
    errdefer {
        for (tool_uses.items) |tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
        }
        tool_uses.deinit(alloc);
    }

    for (response.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |t| try text_buf.appendSlice(alloc, t);
        } else if (std.mem.eql(u8, block.type, "tool_use")) {
            try tool_uses.append(alloc, .{
                .id = try alloc.dupe(u8, block.id orelse ""),
                .name = try alloc.dupe(u8, block.name orelse ""),
                .input = block.input,
            });
        }
    }
    return .{
        .text = try text_buf.toOwnedSlice(alloc),
        .tool_uses = try tool_uses.toOwnedSlice(alloc),
    };
}

/// Deep-copy assistant content blocks so they survive the response arena being
/// freed (was inline at App.zig:763-783). Caller/Host owns the result.
fn dupeAssistantBlocks(
    alloc: std.mem.Allocator,
    blocks: []const agent.llm.message.ContentBlock,
) ![]agent.llm.message.ContentBlock {
    const out = try alloc.alloc(agent.llm.message.ContentBlock, blocks.len);
    for (blocks, 0..) |block, i| {
        const input_copy: std.json.Value = if (block.input != .null) blk: {
            const json_str = std.json.Stringify.valueAlloc(alloc, block.input, .{}) catch break :blk .null;
            defer alloc.free(json_str);
            break :blk std.json.parseFromSliceLeaky(std.json.Value, alloc, json_str, .{}) catch .null;
        } else .null;
        out[i] = .{
            .type = try alloc.dupe(u8, block.type),
            .text = if (block.text) |t| try alloc.dupe(u8, t) else null,
            .thinking = if (block.thinking) |t| try alloc.dupe(u8, t) else null,
            .signature = if (block.signature) |s| try alloc.dupe(u8, s) else null,
            .id = if (block.id) |id| try alloc.dupe(u8, id) else null,
            .name = if (block.name) |n| try alloc.dupe(u8, n) else null,
            .input = input_copy,
        };
    }
    return out;
}
```

### 11.2 New file — `src/cli/print.zig` (thin entrypoint + headless Host)

```zig
const std = @import("std");
const agent = @import("agent");
const log_mod = @import("../log.zig");
const mode = @import("../mode.zig");
const messages = @import("../messages.zig");
const sessions = @import("../sessions.zig");
const agent_loop = @import("../agent_loop.zig");

const log = std.log.scoped(.print);

/// Minimal Host for one-shot, non-interactive runs. History delegates to a
/// reused `messages.Messages`; the inert `Sessions{}` persists nothing. Streaming
/// is dropped (buffered output); all tools are auto-approved (build mode). The
/// final answer is whatever the last assistant `.text` message was.
const Host = struct {
    alloc: std.mem.Allocator,
    convo: messages.Messages = .{},
    sink: sessions.Sessions = .{}, // inert: appendMessage no-ops (file & pending_path null)
    final_text: ?[]const u8 = null,

    fn deinit(self: *Host) void {
        self.convo.deinit(self.alloc);
    }

    // --- required ---
    fn historyItems(self: *Host) []const agent.llm.message.Message {
        return self.convo.historyItems();
    }
    fn pushHistory(self: *Host, msg: agent.llm.message.Message) void {
        self.convo.pushHistory(self.alloc, &self.sink, msg);
        if (msg.role == .assistant and msg.content == .text) {
            self.final_text = msg.content.text; // owned by convo's llm_history
        }
    }
    fn onChunk(_: *Host, _: []const u8) void {}
    fn onThinkingChunk(_: *Host, _: []const u8) void {}
    fn shouldCancel(_: *Host) bool {
        return false;
    }
    fn isToolAllowed(_: *Host, _: []const u8, _: std.json.Value) mode.ToolPolicy {
        return .{ .ok = true, .reason = "" };
    }
    fn confirmTool(_: *Host, _: []const u8, _: std.json.Value) agent_loop.Decision {
        return .approve;
    }
    // --- optional ---
    fn onRequestError(_: *Host, err: anyerror) void {
        std.debug.print("error: LLM request failed: {s}\n", .{@errorName(err)});
    }
};

/// Headless one-shot query: runs the agentic loop without the TUI and prints the
/// final answer to stdout. Diagnostics go to agent.log; hard errors to stderr.
pub fn run(allocator: std.mem.Allocator, prompt: []const u8) !void {
    if (prompt.len == 0) {
        std.debug.print("error: -p/--print requires a non-empty prompt\n", .{});
        return error.EmptyPrompt;
    }

    try log_mod.Logger.init(allocator);
    defer log_mod.Logger.deinit();

    var config_store = agent.config.ConfigStore.init(allocator) catch {
        std.debug.print("error: failed to load config (~/.config/agent-zig/config.json)\n", .{});
        return error.ConfigLoadFailed;
    };
    defer config_store.deinit();

    // Provider/model wiring — mirrors main.zig:94-109.
    var client_cfg = agent.llm.Config{
        .base_url = "",
        .api_key = "",
        .model = config_store.cfg.providers.selected,
        .provider_name = "",
    };
    const found = agent.llm.providers.findModel(config_store.cfg.providers.selected) orelse {
        std.debug.print("error: no model selected — run the TUI once to pick a provider/model\n", .{});
        return error.NoModelSelected;
    };
    client_cfg.provider_name = found.provider.name;
    if (config_store.cfg.providers.forProvider(found.provider.name)) |pc| {
        client_cfg.base_url = pc.baseUrl;
        client_cfg.api_key = pc.apiKey;
        client_cfg.effort = config_store.thinkEffort(found.provider.name);
    }
    if (client_cfg.api_key.len == 0) {
        std.debug.print("error: no API key configured for {s}\n", .{found.provider.name});
        return error.MissingApiKey;
    }

    var client = agent.llm.Client.init(allocator, client_cfg);
    defer client.deinit();

    var sp = agent.system_prompt.SystemPrompt{};
    sp.readContent(allocator) catch |err| log.err("failed to load system prompt: {}", .{err});
    defer sp.deinit(allocator);

    var skill_registry = agent.skills.Registry.init();
    skill_registry.load(allocator) catch |err| log.err("failed to load skills: {}", .{err});
    defer skill_registry.deinit(allocator);

    // Arena for tool defs only (no MCP, no sandbox → built-in tools on host cwd).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tool_ctx = agent.tools.Context{ .skill_registry = &skill_registry };
    const tool_defs = agent.tools.getDefinitions(arena.allocator(), tool_ctx) catch &.{};

    const build_mode: mode.Mode = .{ .build = .{} };
    const system = build_mode.buildSystemPrompt(allocator, sp.content);
    defer if (system) |s| allocator.free(s);

    var host = Host{ .alloc = allocator };
    defer host.deinit();
    host.pushHistory(.{ .role = .user, .content = .{ .text = try allocator.dupe(u8, prompt) } });

    const outcome = agent_loop.run(Host, &host, allocator, &client, tool_ctx, tool_defs, system, .{});
    if (outcome == .request_failed) return error.LlmRequestFailed; // already printed by onRequestError

    const answer = host.final_text orelse {
        std.debug.print("error: model returned no text answer\n", .{});
        return error.NoAnswer;
    };
    if (outcome == .max_iterations) log.warn("iteration cap reached before a final answer", .{});

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{answer});
    try stdout.flush();
}
```

### 11.3 Change — `src/App.zig` (App becomes the TUI `Host`)

Add the import and field:
```zig
const agent_loop = @import("agent_loop.zig");
// ... in pub const App = struct { ... }
active_loop: ?*EventLoop = null,   // set by fetchAiResponse so hooks can wakeLoop
```

`fetchAiResponse` shrinks to its pre-loop + an engine call:
```zig
pub fn fetchAiResponse(self: *Self, loop: *EventLoop) void {
    self.active_loop = loop;
    const alloc = self.alloc;

    // --- pre-loop (TUI-only, UNCHANGED): build the user message from the latest
    //     UI message + pending attachments and pushHistory it. (App.zig:526-618) ---
    // ... existing user_text / image-block logic, ending in self.messages.pushHistory(...) ...

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tool_ctx = agent.tools.Context{
        .skill_registry = &self.skill_registry,
        .mcp_registry = &self.mcp_registry,
        .sandbox = &self.sandbox,
    };
    const tool_defs = agent.tools.getDefinitions(arena.allocator(), tool_ctx) catch &.{};

    const system = self.mode.buildSystemPrompt(alloc, self.system_prompt.content);
    defer if (system) |s| alloc.free(s);

    _ = agent_loop.run(Self, self, alloc, self.llm_client, tool_ctx, tool_defs, system, .{});
}
```

The old `StreamCtx`/`onChunk`/`onThinkingChunk`/`shouldCancel` (App.zig:407-458)
become `App` methods (no more `*anyopaque` ctx), and new hook methods absorb the
side-effects that used to be inline in the loop. Simple ones in full:
```zig
fn historyItems(self: *Self) []const agent.llm.message.Message {
    return self.messages.historyItems();
}

fn pushHistory(self: *Self, msg: agent.llm.message.Message) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.messages.pushHistory(self.alloc, &self.sessions, msg);
    self.needs_redraw = true;
}

fn onChunk(self: *Self, chunk: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const last = self.messages.lastAssistant() orelse return;
    const new_content = std.mem.concat(self.alloc, u8, &.{ last.content, chunk }) catch return;
    self.alloc.free(last.content);
    last.content = new_content;
    self.needs_redraw = true;
    if (self.active_loop) |l| wakeLoop(l);
}
// onThinkingChunk: same shape, grows `last.thinking` (App.zig:430-449).

fn shouldCancel(self: *Self) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.cancel_requested;
}

fn isToolAllowed(self: *Self, name: []const u8, input: std.json.Value) mode_mod.ToolPolicy {
    return self.mode.isToolAllowed(name, input);
}

fn onUsage(self: *Self, usage: agent.llm.message.Usage) void {
    self.context_usage.tokensCount = @intCast(usage.input_tokens + usage.output_tokens);
    if (agent.llm.providers.findModel(self.llm_client.config.model)) |found| {
        self.context_usage.tokensPercentage = self.context_usage.tokensCount * 100 / found.model.max_context;
    }
}

fn onRequestError(self: *Self, err: anyerror) void {
    _ = err;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.messages.last()) |last| {
        self.alloc.free(last.content);
        last.content = self.alloc.dupe(u8, "Service is not working, try later") catch "";
        last.is_error = true;
    }
}

fn onFinished(self: *Self, _: agent_loop.Outcome) void {
    self.mutex.lock();
    self.loading.stop();
    self.tool_status = null;
    self.clearGrepStatus();
    self.clearGlobStatus();
    self.clearWebStatus();
    self.cancel_requested = false;
    self.needs_redraw = true;
    self.mutex.unlock();
    if (self.active_loop) |l| wakeLoop(l);
}
```

The three heavier hooks are the **existing inline blocks lifted verbatim** into
methods (no logic change), so they aren't re-listed here:
- `confirmTool(self, name, input) agent_loop.Decision` ← the confirmation block at
  `App.zig:802-877` (synthesized MCP header, `loading.pause`, `tool_confirmation`
  setup, `wakeLoop`, `cond.wait`, sticky `accept_all`); returns `.deny`/`.approve`.
- `onToolActivity(self, name, input)` ← the grep/glob/web/`tool_status` updates at
  `App.zig:879-927`.
- `onToolResult(self, name, input, result)` ← the skill/skill_script notices at
  `App.zig:931-944`.
- `dequeueFollowUp(self) ?[]u8` ← the queued-message block at `App.zig:736-756`
  (adds the UI user bubble + assistant placeholder, returns the owned queued text
  for the engine to push to history).

### 11.4 Change — `src/main.zig`

Add the import alongside the other `cli/` imports (near line 19):
```zig
const cli = @import("cli/common.zig");
const update = @import("cli/update.zig");
const print = @import("cli/print.zig"); // NEW
```

Intercept `-p` / `--print` in the existing arg block (lines 56-62), **before**
`cli.dispatch` and any TUI setup:
```diff
     var first_message: ?[]const u8 = null;
     if (args.len > 1) {
         const cmd = args[1];
+
+        if (std.mem.eql(u8, cmd, "-p") or std.mem.eql(u8, cmd, "--print")) {
+            const prompt = if (args.len > 2) args[2] else "";
+            print.run(alloc, prompt) catch std.process.exit(1);
+            return;
+        }
+
         if (cli.dispatch(alloc, cmd)) return;

         first_message = cmd;
     }
```
/

### 11.6 Why these specific choices (cross-checks)

- **Single source of truth for the loop.** `agent_loop.drive` is the only
  think→tool→loop; the prior copy-paste is gone. `splitResponse` /
  `dupeAssistantBlocks` are extracted from `App.zig:700-718` / `763-783` and now
  live once, in the engine.
- **`comptime Host` + `@hasDecl` optional hooks.** Zero-cost dispatch, explicit
  types (the project's Zig guidance prefers `comptime T: type` over
  `anytype`/vtables), and the headless `Host` only writes the hooks it needs —
  the engine `if (@hasDecl(Host, …))`-guards every optional call.
- **Locking stays in the Host.** The engine never locks; it holds no lock across
  `sendMessageStreaming` (so the TUI can't freeze), and `App.pushHistory`/
  `onChunk` self-lock exactly as the inline code did. The headless `Host` does no
  locking (single-threaded).
- **History reuse, not reinvention.** Both Hosts store history in
  `messages.Messages`; headless adds an inert `Sessions{}` (`appendMessage`
  no-ops by default), so it gets the TUI's exact ownership/free model and "no
  persistence" for free.
- **`tools.Context{ .skill_registry = … }` only.** Null `mcp_registry`/`sandbox`
  ⇒ `getDefinitions` skips MCP and `execute` selects `Exec.host` — decisions #5,
  #8, #11 in one literal.
- **Final-answer capture.** The headless `Host` records the last assistant
  `.text` in `pushHistory`; buffered output (decision #6) then prints it once
  after `run` returns. `neverCancel`/no-op sinks encode decisions #14 and #6.

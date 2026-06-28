## Context

`src/system_prompt.zig::SystemPrompt.readContent` currently:

1. Opens `src/prompts/system.txt` (cwd-relative, build-embedded source file).
2. If `AGENTS.md` exists in cwd, appends `"\n\n" + agents_content` to the base.
3. Sets `agents_md_exists = true` when AGENTS.md was loaded.

The assembled `content` is then passed to `mode.buildSystemPrompt(alloc, content)` (`src/App.zig:846`), which prepends the mode prompt (plan/build). The result becomes the `system_prompt` argument to every LLM client call (`anthropic.zig`, `openai.zig`, `gemini.zig`).

There is no override mechanism. The base prompt is fixed per build.

## Goals / Non-Goals

**Goals:**
- Allow a project to fully replace the base system prompt (`src/prompts/system.txt`) by placing a `SYSTEM.md` file in the cwd root.
- Keep the change minimal and isolated to `src/system_prompt.zig`.
- Preserve existing post-base assembly: `AGENTS.md` append and mode-prompt prepend behave identically regardless of override.

**Non-Goals:**
- No global override (`~/.config/agent-zig/SYSTEM.md`).
- No append-only override file (`APPEND_SYSTEM.md`).
- No parent-directory walk for `SYSTEM.md` or `AGENTS.md`.
- No CLI flag (`--system-prompt`), no config.json field.
- No UI surface (no banner indicator, no `/` command).
- No SDK/hook override hook.

## Decisions

### D1: Override file path is `./SYSTEM.md` (cwd root)

**Choice:** Resolve `SYSTEM.md` relative to cwd, same lookup style as the existing `AGENTS.md` open.

**Rationale:** Matches the existing `AGENTS.md` convention already in `readContent`, so resolution is uniform and predictable. A root-level file is the simplest contract for users.

**Alternatives considered:**
- `.agents/SYSTEM.md`: would namespace under the existing `.agents/` project-resources dir. Rejected for this change to match the `AGENTS.md` precedent and keep the diff minimal. Could be revisited if a future change introduces additional project-local prompt files.
- `.pi/SYSTEM.md`: rejected — `.pi/` is pi-the-harness's own convention; this repo is `agent-zig`, not pi.

### D2: Replace semantics, not append

**Choice:** When `SYSTEM.md` exists, its content **replaces** `src/prompts/system.txt` entirely as the base. It is not concatenated with the built-in prompt.

**Rationale:** Matches the user's stated intent ("replace system default text") and mirrors pi's `SYSTEM.md` semantics. An override that silently appended the built-in prompt would be surprising.

**Alternatives considered:**
- Append semantics (`APPEND_SYSTEM.md`): explicitly a non-goal here; could be added later as a separate file/concept without conflicting with this decision.

### D3: AGENTS.md is appended after the override, unchanged

**Choice:** The `AGENTS.md` append step runs regardless of whether the base came from `SYSTEM.md` or `system.txt`.

**Rationale:** `AGENTS.md` is the project-instructions/context layer and is conceptually separate from the base persona. Keeping it independent of the override source preserves existing behavior and lets a project override the persona while still layering its conventions.

### D4: Mode prompt is prepended after assembly, unchanged

**Choice:** `mode.buildSystemPrompt(alloc, base_content)` is called with the post-override, post-AGENTS `content`. The mode prompt (plan-mode "don't write files", build-mode framing) is prepended as today.

**Rationale:** Mode prompts carry functional guardrails (plan mode blocks writes at the tool-policy layer too, but the prompt framing is still load-bearing for model behavior). Letting a `SYSTEM.md` override silently strip mode guardrails would be a footgun. If a user wants full control including modes, that is a separate future change (e.g. an opt-out flag).

### D5: Lookup is cwd-only, no parent walk

**Choice:** `SYSTEM.md` is opened from cwd only. A missing file falls back to the built-in prompt. No directory walk.

**Rationale:** Matches the user's stated scope ("only check in root folder"). The existing `AGENTS.md` lookup is also cwd-only, so this keeps the two consistent. Parent-walk can be added later as an additive change.

### D6: Read errors on SYSTEM.md fall back, not fatal

**Choice:** If `SYSTEM.md` exists but cannot be read (permissions, I/O), the error is logged via `std.log.scoped(.app)` and the built-in prompt is used. This mirrors the existing `AGENTS.md` open pattern (`catch return`).

**Rationale:** A malformed override should not prevent the agent from starting. Degraded behavior (silently using the default) is preferable to a hard crash on startup, and matches the existing tolerance for `AGENTS.md` read failures.

## Risks / Trade-offs

- **[Override silently changes agent behavior]** → Mitigation: documented as replace semantics; `AGENTS.md` and mode prompts still apply on top, so guardrails remain.
- **[Cwd-relative path surprises users running from a subdirectory]** → Accepted: matches existing `AGENTS.md` and `src/prompts/system.txt` cwd-relative behavior. Out of scope for this change.
- **[No UI indicator that an override is active]** → Accepted non-goal. Users who placed `SYSTEM.md` know it is active. A future change could surface a `system_md_exists` flag in the welcome banner if desired.
- **[Empty `SYSTEM.md` produces an empty base prompt]** → Accepted: an empty file is a valid (if unusual) override. The mode prompt and any `AGENTS.md` still apply, so the agent is not promptless in practice.

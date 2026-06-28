## Why

The agent's base system prompt is hardcoded to `src/prompts/system.txt` and embedded at build time. There is no way to override it per project without editing source. Users who want a different persona or different framing for a given repo (e.g. a focused code-review bot, or a rebranded assistant for a specific codebase) have no project-local mechanism to do so.

Pi solves this with a `SYSTEM.md` file in the project root that replaces the default prompt. We adopt the same convention here, scoped minimally to project-local replacement only.

## What Changes

- Add a project-local system prompt override: if a `SYSTEM.md` file exists in the current working directory, its contents replace `src/prompts/system.txt` entirely as the base system prompt.
- `AGENTS.md` (if present) continues to be appended after the base prompt, unchanged.
- Mode prompts (plan/build) continue to be prepended after the base+AGENTS assembly, unchanged.
- Resolution is cwd-only — no parent-directory walk, no global (`~/.config/agent-zig/`) override location in this change.
- `agents_md_exists` flag on `SystemPrompt` is unchanged; no new "system override exists" flag is surfaced to the UI in this change.

## Capabilities

### New Capabilities
- `system-prompt`: Loading and assembly of the base system prompt sent to the LLM, including the new project-local override file resolution.

### Modified Capabilities
<!-- None. No existing specs cover system prompt behavior. -->

## Impact

- `src/system_prompt.zig`: `readContent` gains a `SYSTEM.md` check before falling back to `src/prompts/system.txt`. New boolean field `system_md_exists` (optional; only if needed for tests/UI — see design).
- `src/system_prompt.zig` tests: add cases for override-present and override-absent.
- No config schema changes (`config.json` untouched).
- No CLI flag changes.
- No UI changes.
- Release binaries: behavior unchanged when `SYSTEM.md` is absent; override works for any binary run from a directory containing `SYSTEM.md`.

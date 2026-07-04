# AGENTS.md

## Source Of Truth

- `src/system_prompt.zig` loads `src/prompts/system.txt` and then the first repo instruction file it finds. Keep this file short and repo-specific because it is injected into app prompts.
- Trust `build.zig` and current `src/` wiring over prose docs. Some repo docs are stale relative to the implementation.

## Build And Verify

- Use `zig build` to compile the app.
- Use `zig build run` to launch the TUI.
- Use `zig build test` for verification. `build.zig` defines two test executables and the `test` step runs both the library module (`src/root.zig`) and the app module (`src/main.zig`).
- There is no repo-local lint/format/typecheck script beyond Zig build/test steps.
- Release CI builds a Linux musl binary with `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast --prefix dist/linux`.

## Runtime Config

- Config auto-creates at `~/.config/agent-zig/config.json` on first run.
- Real persisted state lives under `~/.config/agent-zig/`: `config.json`, `agent.log`, `crash.log`, `sessions/`, and sandbox worktrees under `worktrees/`.
- Tavily-backed `web_search` / `web_extract` only work if built with `-Dtavily-api-key="..."`; otherwise they fail at runtime.
- MCP servers are configured in `config.json` under `mcpServers`; the app loads them asynchronously at startup.

## Code Map

- `src/main.zig` is the TUI entrypoint and event loop.
- `src/root.zig` is the reusable `agent` module exported to the app and tests.
- `src/App.zig` owns most runtime state: messages, sessions, skills, MCP registry, sandbox, tool confirmation, and LLM request lifecycle.
- `src/input_handler.zig` wires most user-visible behavior: slash commands, mode switching, shell mode, provider/model pickers, and session actions.
- `src/tools.zig` is the built-in tool registry/executor; when sandbox is active, filesystem tools and bash are routed through Docker there.
- `src/config.zig` is the source of truth for config shape and persisted defaults.

## Behavior That Is Easy To Miss

- Modes are not just UI labels. `Shift+Tab` toggles `build <-> plan`; typing a leading `!` switches to shell mode and removes the `!` from input; `Esc` exits shell mode back to build mode.
- Plan mode is effectively read-only. In `src/modes/plan.zig`, `write_file` and `edit_file` are blocked, and `bash` is also blocked in practice because `isSafeBash()` currently always returns `false`.
- `/sandbox` does not mutate the main checkout. It creates a fresh git worktree and branch under `~/.config/agent-zig/worktrees/<repo>/sandbox-<timestamp>`, starts Docker against that worktree, and keeps the worktree/branch after the container stops.
- Logs never go to stderr; inspect `~/.config/agent-zig/agent.log` and `crash.log` when debugging startup, TUI, or panic issues.
- Session history is file-backed under `~/.config/agent-zig/sessions/*.log`; `/resume`, `/fork`, and rename behavior are backed by `src/sessions.zig` plus entries persisted in `config.json`.

## Git And Commit Conventions

- Do not commit automatically. After making changes, leave them in the working tree (unstaged) and commit only when explicitly asked.
- Work directly on `master`. Do not create feature branches for changes, even when running plan/execution workflows that default to branching.
- Commit messages are a single-line subject only: no body, no bullet description.
- Never add a `Co-Authored-By` trailer to commits.
- When an email is needed (plan authorship, docs attribution), use `ernestoponce27@gmail.com`, not the Claude Code account email.

## UI Commands

- Slash commands currently include `/provider`, `/model`, `/clear`, `/compact`, `/fork`, `/resume`, `/init`, `/mcp`, `/rename`, `/sandbox`, and `/exit` (`src/commands/command_picker.zig`).

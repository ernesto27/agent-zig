# Zigent

Terminal-based AI coding agent written in Zig, built on [libvaxis](https://github.com/rockorager/libvaxis).

Requires Zig `0.15.2`+.

## Features

- **Multi-provider LLM** — pick any configured/authenticated model from the picker:
  - **Anthropic**: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`
  - **OpenAI**: `gpt-5.5`, `gpt-5.4`, `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5`, `gpt-5-mini`
  - **DeepSeek**: `deepseek-v4-flash`, `deepseek-v4-pro` (via the Anthropic-compatible endpoint)
  - **Gemini**: `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`
  - **OpenRouter**: tool-capable models fetched dynamically at startup
- **Streaming responses** — SSE streaming with real-time token display across all wire protocols (Anthropic, OpenAI, Gemini)
- **Extended thinking** — visible reasoning for thinking-capable models; per-provider effort (`off`/`low`/`medium`/`high`/`max`), toggle display with `/settings`
- **Tool system** with approve/deny/accept-all confirmation UI:
  - `read_file`, `write_file`, `edit_file`, `bash`, `glob`, `grep`
  - `web_search`, `web_extract` (Tavily — requires build-time API key)
  - `skill`, `skill_resource`, `skill_script`
  - `task_write` — maintains the session task list rendered in the task sidebar
- **Modes** — `build` (all tools), `plan` (read-only), and `shell`:
  - **Shift+Tab** toggles build ↔ plan
  - Type a leading `!` to run a line directly as a shell command; **Esc** exits shell mode
- **Docker sandbox** (`/sandbox`) — runs tool actions inside a throwaway container against a fresh git worktree/branch, so the main checkout is never mutated (see below)
- **MCP support** — stdio and Streamable HTTP transports; multi-server; tools exposed as `mcp__<server>__<tool>` behind the same confirmation gate (see below)
- **Skills** — load custom agent skills from `.agents/skills/` (project) and `~/.agents/skills/` (home); enable/disable with `/skills`; invoke directly from the command picker; queued when the LLM is busy; preload specific skills at launch with `-skills-load <name> [<name>...]`
- **Task sidebar** — the agent tracks multi-step work via the `task_write` tool; pending/in-progress/completed tasks render live in a sidebar
- **Slash commands** — `/provider`, `/model`, `/clear`, `/compact`, `/fork`, `/resume`, `/init`, `/mcp`, `/skills`, `/rename`, `/sandbox`, `/export`, `/settings`, `/logout`, `/exit`
- **@ file picker** — fuzzy-pick files to attach inline to a message
- **Image attachments** — attach images; persisted with the session
- **Message steering** — type while the LLM is working; messages queue and are picked up on the next turn
- **Session management** — save, `/resume`, `/fork`, and `/rename` past conversations; resume from the shell with `--session <file>`
- **Headless mode** — `agent-zig -p "<prompt>"` runs non-interactively and prints the result
- **Markdown rendering** — themed headings, code blocks, quotes, and inline styles
- **Context usage** — live token count and percentage of the model's context window
- **Cancellation** — Esc cancels in-flight requests; Ctrl+C with exit confirmation
- **Trust dialog** — per-folder trust prompt on first use
- **Logging** — file-based logger (not stderr, avoids TUI pollution); crash handler writes `crash.log`


Provider API keys are set via `/provider`. The DeepSeek key can also come from the `DEEPSEEK_API_KEY` environment variable.


## Docker sandbox

`/sandbox` toggles an isolated execution environment. It does **not** mutate the main checkout:

- Creates a git worktree on a new branch `sandbox-<timestamp>` under `~/.config/agent-zig/worktrees/<repo>`.
- Starts a detached, auto-removing container (default image `ubuntu:24.04`, configurable via `dockerImage`) that bind-mounts only the throwaway worktree at `/workspace`.
- The agent loop stays on the host; only filesystem and `bash` tool actions are shipped into the container via `docker exec`.
- On stop, files are `chown`ed back to the host user and the container is removed; the worktree and branch are kept for review/merge.

## MCP servers

Spawn third-party MCP (Model Context Protocol) servers and use their tools alongside the built-ins.

- **Transports**: stdio (subprocess) and Streamable HTTP (hosted servers, static auth headers)
- **Capability**: `tools` (`tools/list` + `tools/call`)
- Multi-server; each tool exposed as `mcp__<server>__<tool>`
- Per-server background loading — the TUI never blocks on cold starts, and each server reports `loading`/`connected`/`failed`
- `/mcp` slash command to browse servers and their tool lists
- Per-call approve/deny/accept-all confirmation modal (same gate as `bash`)

Example `~/.config/agent-zig/config.json`:

```json
"mcpServers": {
  "fs":       { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/project"] },
  "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
  "git":      { "command": "uvx", "args": ["mcp-server-git", "--repository", "/home/me/project"] },
  "remote":   { "type": "http", "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ..." } }
}
```


## Project context

- `SYSTEM.md` in the project root replaces the built-in system prompt.
- `AGENTS.md` is read as project context; `/init` can generate or update it.

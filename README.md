# Zigent

Terminal-based AI coding agent written in Zig.

## Features

- **Multi-provider LLM**: Anthropic (Claude Opus/Sonnet/Haiku), OpenAI (GPT-5 family), and DeepSeek (V4 Flash/Pro)
- **Streaming responses**: SSE streaming with real-time token display
- **Extended thinking**: Visible reasoning for thinking-capable models
- **Tool system** with approve/deny/accept-all confirmation UI:
  - `read_file`, `write_file`, `edit_file`, `bash`, `glob`, `grep`
  - `web_search`, `web_extract` (Tavily — requires API key)
- **MCP support** (stdio, tools-only): spawn third-party Model Context Protocol servers (filesystem, git, context7, …); their tools appear to the LLM as `mcp__<server>__<tool>` and route through the same confirmation gate as `bash`
- **Skills**: Load custom agent skills from `.agents/skills/`
- **Modes**: `build` and `plan` modes with tailored system prompts
- **Slash commands**: `/provider`, `/model`, `/mcp`, `/clear`, `/resume`, `/init`, `/exit` + loaded skills
- **@ file picker**: Attach files inline to messages
- **Session management**: Save and resume past conversations
- **Markdown rendering**: Styled output in the chat area
- **Context usage**: Token count display
- **Cancellation**: Esc cancels in-flight requests; Ctrl+C with exit confirmation
- **Logging**: File-based logger (not stderr, avoids TUI pollution)

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## Test

```bash
zig build test
```

## Tavily API key

`web_search` and `web_extract` read the Tavily API key from a build flag.

Build with key:

```bash
zig build -Dtavily-api-key="tvly-..."
```

Run with key:

```bash
zig build run -Dtavily-api-key="tvly-..."
```

Test with key:

```bash
zig build test -Dtavily-api-key="tvly-..."
```

If the flag is omitted, Tavily-backed tools return a missing API key error at runtime.

## MCP servers

Spawn third-party MCP (Model Context Protocol) servers and use their tools alongside built-ins.

- stdio transport, `tools` capability
- multi-server (`fs`, `git`, `context7`, …) — each tool exposed as `mcp__<server>__<tool>`
- `/mcp` slash command to browse servers and their tool lists
- per-call approve/deny/accept-all confirmation modal (same gate as `bash`)
- background loading (TUI never blocks during `npx` cold starts)

Example `~/.config/agent-zig/config.json`:

```json
"mcpServers": {
  "fs":       { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/project"] },
  "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
  "git":      { "command": "uvx", "args": ["mcp-server-git", "--repository", "/home/me/project"] }
}
```

Limits: no HTTP transport, no resources/prompts, no per-call timeout, no `env` override yet.

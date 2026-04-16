# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Always ask for approval before applying code changes in real-time, unless explicitly told otherwise.

## Project Overview

Zigent is a terminal-based AI coding agent (inspired by [OpenCode](https://github.com/sst/opencode)) written in Zig. It provides a TUI chat interface that talks to LLMs and can execute coding tools (file read/write, shell commands, etc.).

## Build & Run

```bash
zig build              # Build the executable (output: zig-out/bin/agent)
zig build run          # Build and run the TUI app
zig build test         # Run all tests (both library and executable modules)
```

Requires **Zig 0.15.2+**. Dependencies (libvaxis) are fetched automatically by the build system.

### Mock LLM Server

A Node.js mock server mimics the Anthropic Messages API for local development:

```bash
cd mock-server && node server.js    # Runs on http://localhost:9999
```

Endpoints: `POST /v1/messages` (streaming + non-streaming), `GET /health`.

## Architecture

The project has two Zig modules defined in `build.zig`:

- **`agent` module** (`src/root.zig`) — Library module for reusable business logic. Exposes `llm`, `markdown`, and utility helpers via `@import("agent")`.
- **Executable root** (`src/main.zig`) — The TUI application. Imports `agent`, `vaxis`, and all UI modules. Contains the event loop, input handling, and slash command dispatch.

The TUI uses [libvaxis](https://github.com/rockorager/libvaxis) 0.5.1 for terminal rendering and event handling.

## Source Files

```
src/
├── main.zig              # Entry point, event loop, keybindings
├── App.zig               # App state: messages, LLM client, tool confirmation, spinner
├── root.zig              # agent module root (re-exports llm, markdown, etc.)
├── config.zig            # Config: reads ~/.config/agent-zig/config.json (apiKey, baseUrl, model)
├── layout.zig            # TUI layout helpers
├── ui.zig                # Chat rendering, message display
├── markdown.zig          # Markdown → styled terminal lines renderer
├── tools.zig             # Tool registry and executor (read_file, write_file, edit_file, bash, glob, grep)
├── at_picker.zig         # @ file picker widget
├── command_picker.zig    # / slash command picker widget (/provider, /model)
├── model_picker.zig      # Model picker widget
├── provider_picker.zig   # Provider picker widget
├── chat_selection.zig    # Chat history selection
└── llm/
    ├── client.zig        # HTTP LLM client (streaming SSE, tool calls, thinking, cancellation)
    ├── message.zig       # Message types: role, content blocks, tool definitions, effort
    └── providers.zig     # Provider/model registry (Anthropic, OpenAI)
```

## Current Features

- **LLM connectivity**: Streaming responses via SSE from Anthropic and OpenAI APIs
- **Multi-provider support**: Anthropic (Claude Opus/Sonnet/Haiku) and OpenAI (GPT-4o, o3, o4-mini)
- **Thinking support**: Extended thinking display for supported models
- **Tool system**: `read_file`, `write_file`, `edit_file`, `bash`, `glob`, `grep` — with approve/deny/accept_all confirmation UI for mutating tools and preview panels for search tools
- **Markdown rendering**: Styled output in the chat area
- **Spinner**: Loading indicator during LLM generation
- **Cancellation**: Esc cancels in-flight LLM requests
- **Slash commands**: `/provider`, `/model` to switch providers and models at runtime
- **@ file picker**: Attach files to messages
- **Logging**: File-based logger (written to disk, not terminal)

## Configuration

Config is read from `~/.config/agent-zig/config.json`:

```json
{
  "apiKey": "sk-...",
  "baseUrl": "https://api.anthropic.com",
  "model": "claude-sonnet-4-6"
}
```

## Key Conventions

- **Allocator**: Uses `GeneralPurposeAllocator` at the top level. All heap-allocating functions receive an allocator parameter (standard Zig pattern).
- **ArrayList pattern**: Uses `std.ArrayList(T){}` with explicit allocator passed to each method call (not stored in the struct), per Vaxis conventions.
- **Target**: Single static binary with zero runtime dependencies.
- **Logging**: Use `std.log.scoped(.scope_name)` — logs go to a file, not stderr, to avoid polluting the TUI.

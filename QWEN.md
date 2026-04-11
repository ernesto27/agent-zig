# QWEN.md — Zigent Project Context

## Project Overview

**Zigent** is a terminal-based AI coding agent written in Zig, inspired by [OpenCode](https://github.com/sst/opencode). It provides a TUI (Text User Interface) chat interface that communicates with LLMs (Anthropic Claude, OpenAI GPT) and can execute coding tools like file read/write/edit and shell commands.

**Current version:** 0.0.2

### Key Characteristics
- **Language:** Zig 0.15.2+
- **TUI library:** libvaxis 0.5.1
- **Target:** Single static binary with zero runtime dependencies
- **Architecture:** Two-module design — a library module (`agent`) for business logic and an executable (`main.zig`) for the TUI application

## Building and Running

```bash
zig build              # Build the executable (output: zig-out/bin/agent-zig)
zig build run          # Build and run the TUI app
zig build test         # Run all tests (both library and executable modules)
```

### Mock LLM Server (for local development)

A Node.js mock server mimics the Anthropic Messages API:

```bash
cd mock-server && node server.js    # Runs on http://localhost:9999
```

Endpoints: `POST /v1/messages` (streaming + non-streaming), `GET /health`.

## Configuration

Config is read from `~/.config/agent-zig/config.json`:

```json
{
  "apiKey": "sk-...",
  "baseUrl": "https://api.anthropic.com",
  "model": "claude-sonnet-4-6"
}
```

The config supports multiple providers (Anthropic, OpenAI) with per-provider settings for `apiKey`, `baseUrl`, and `model`.

## Architecture

### Module Structure

The `build.zig` defines two Zig modules:

| Module | Root File | Purpose |
|--------|-----------|---------|
| `agent` (library) | `src/root.zig` | Reusable business logic — exports `llm`, `markdown`, `config`, `tools`, `system_prompt` |
| Executable | `src/main.zig` | TUI application — event loop, input handling, slash command dispatch |

### Source File Map

```
src/
├── main.zig              # Entry point, event loop, keybindings, TUI rendering
├── App.zig               # App state: messages, LLM client, tool confirmation, spinner
├── root.zig              # Agent library module root (re-exports submodules)
├── config.zig            # Config loader/saver (~/.config/agent-zig/config.json)
├── layout.zig            # TUI layout computation helpers
├── ui.zig                # Chat rendering, message display, spinner widget
├── markdown.zig          # Markdown → styled terminal lines renderer
├── tools.zig             # Tool registry and executor (read_file, write_file, edit_file, bash)
├── system_prompt.zig     # System prompt construction
├── at_picker.zig         # @ file picker widget
├── command_picker.zig    # / slash command picker widget
├── model_picker.zig      # Model picker widget
├── provider_picker.zig   # Provider picker widget
├── chat_selection.zig    # Chat history selection / mouse text selection
├── llm.zig               # LLM submodule root
│   └── llm/
│       ├── client.zig    # HTTP LLM client (streaming SSE, tool calls, thinking, cancellation)
│       ├── message.zig   # Message types: role, content blocks, tool definitions, effort
│       └── providers.zig # Provider/model registry (Anthropic, OpenAI)
```

## Current Features

- **LLM connectivity:** Streaming responses via SSE (Anthropic + OpenAI)
- **Multi-provider support:** Anthropic (Claude Opus/Sonnet/Haiku) and OpenAI (GPT-4o, o3, o4-mini)
- **Thinking support:** Extended thinking display for supported models
- **Tool system:** `read_file`, `write_file`, `edit_file`, `bash` — with approve/deny/accept_all confirmation UI
- **Markdown rendering:** Styled output in the chat area
- **Spinner:** Loading indicator during LLM generation
- **Cancellation:** `Esc` cancels in-flight LLM requests
- **Slash commands:** `/provider`, `/model`, `/clear`
- **@ file picker:** Attach files to messages
- **Mouse text selection:** Click-and-drag to copy text from chat
- **Logging:** File-based logger (`agent.log`, not terminal)

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+C` / `Ctrl+Q` | Quit |
| `Ctrl+T` | Toggle thinking effort (if model supports it) |
| `Ctrl+A` | Move cursor to "Approve" in tool confirmation |
| `Esc` | Cancel request / close picker / deny tool |
| `Up/Down` | Navigate pickers, history, or tool options |
| `Left/Right` | Move cursor in input |
| `Enter` | Submit message / confirm selection |
| `Backspace` | Delete character / close picker |
| Mouse wheel | Scroll chat / tool preview |
| Mouse drag | Select text to copy |

## Development Conventions

### Memory Management
- Uses `GeneralPurposeAllocator` at the top level
- All heap-allocating functions receive an allocator parameter (standard Zig pattern)
- Per-frame rendering uses `ArenaAllocator` for short-lived allocations

### ArrayList Pattern
- Uses `std.ArrayList(T){}` with explicit allocator passed to each method call (not stored in the struct), per Vaxis conventions
- Example: `list.append(alloc, value)` not `self.list.append(value)`

### Logging
- Use `std.log.scoped(.scope_name)` for scoped logging
- Logs are written to `agent.log` file via a custom `logFn`, **not** to stderr (to avoid polluting the TUI)

### Mutex / Threading
- `App` uses a mutex for thread-safe access to shared state (LLM response comes from a background thread)
- Background threads are spawned for LLM fetch and spinner, then detached

### Testing
- Both library (`mod`) and executable (`exe`) modules have test targets
- Run with `zig build test`

## Dependencies

| Dependency | Source | Version |
|------------|--------|---------|
| libvaxis | `github.com/rockorager/libvaxis` | 0.5.1 |

Only dependency, fetched automatically by Zig's build system.

## Planned Work (from TODO.md)

Key upcoming items:
- **Built-in tools:** glob, grep, list directory, improved file operations
- **TUI enhancements:** Tool call display in chat, diff view for edits, clickable file paths
- **Agentic loop:** Tool call chaining, max iterations, error detection/retry
- **Conversation management:** `/undo`, `/redo`, command history, multi-line input
- **Project context:** Read AGENTS.md/CLAUDE.md, token counting, session persistence
- **Git integration:** Status display, `/commit`, `/diff`
- **Multi-provider refinements:** Full provider abstraction layer refactoring

## Useful Commands

```bash
zig build                  # Build
zig build run              # Run
zig build test             # Test
zig build --help           # Show all build options
zig fetch --save-all       # Fetch/update dependencies
```

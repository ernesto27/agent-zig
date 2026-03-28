# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zigent is a terminal-based AI coding agent (inspired by [OpenCode](https://github.com/sst/opencode)) written in Zig. It aims to provide a TUI chat interface that talks to LLMs and can execute coding tools (file read/write, shell commands, etc.). The project is in early Phase 1 — basic TUI layout exists but no LLM connectivity yet.

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

- **`agent` module** (`src/root.zig`) — Library module intended for reusable business logic. Currently minimal (placeholder `add` function and `bufferedPrint`). This is what gets exposed to consumers via `@import("agent")`.
- **Executable root** (`src/main.zig`) — The TUI application. Imports both the `agent` module and `vaxis`. Contains the event loop, chat rendering, input handling, and scrollable message display.

The TUI uses [libvaxis](https://github.com/rockorager/libvaxis) 0.5.1 for terminal rendering and event handling. The main loop follows a vaxis pattern: `EventLoop` dispatches events (key presses, window resizes), and the app redraws on each event using vaxis window/child primitives.

### Current State

- TUI layout works: header bar, scrollable chat area with border, text input field, status bar, scrollbar
- Messages are hardcoded test data with a placeholder AI response on Enter
- No HTTP client, no LLM API calls, no tool system yet

### Planned Architecture (from TODO.md)

The intended module structure separates concerns into `tui/`, `llm/`, `tools/`, `agent/`, and `util/` subdirectories under `src/`. See `TODO.md` for the full 7-phase roadmap.

## Key Conventions

- **Allocator**: Uses `GeneralPurposeAllocator` at the top level. All heap-allocating functions receive an allocator parameter (standard Zig pattern).
- **ArrayList pattern**: Uses `std.ArrayList(T){}` with explicit allocator passed to each method call (not stored in the struct), perVaxis conventions.
- **Target**: Single static binary with zero runtime dependencies.

# Gemini Instructions - Zigent

This file provides the primary context for Gemini when working on the Zigent project.

## Core Instructions

For all project overview details, build/run commands, architectural patterns, and coding conventions (such as allocator usage and ArrayList patterns), **strictly follow the guidelines in [CLAUDE.md](CLAUDE.md)**.

## Project Context

- **Roadmap:** Refer to [TODO.md](TODO.md) for the detailed 7-phase implementation plan and current progress.
- **Current Phase:** Phase 1 (Minimal Chat Loop).
- **Mock Server:** For testing without API keys, use the Node.js server in `mock-server/`.

## Key Files
- `src/main.zig`: TUI Entry point and event loop.
- `src/root.zig`: Library root (the `agent` module).
- `src/llm/`: LLM client and message definitions.
- `build.zig`: Project build configuration.

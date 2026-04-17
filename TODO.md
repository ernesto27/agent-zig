
[x] - basic read tool file/
[x] - show thinking
[x] - show code before accept- deny
[] - tool for search internet
[] - show read file using
[x] - clear conversation 
[x] - agent.log must be save in .config folder
[x] - refactor render 
[] - fix model descriptcion space ,  
[] - do not show this err.httprequestfailes, show a nice error message
[x] - command show,  is overlap with content text
[] - init command
[] - paset larget text crash
[] - drag stop working
[] - somethimes code preview does not show 
[] - refactor providers llms services
[] - when think or executing show time counter
[] - save conversations to resume
[] - add arena options to have two models or more doint same task in paraller

// read file claude.md or agents.md



Create or update `AGENTS.md` for this repository.
The goal is a compact instruction file that helps future OpenCode sessions avoid mistakes and ramp up quickly. Every line should answer: "Would an agent likely miss this without help?" If not, leave it out.
User-provided focus or constraints (honor these):
## How to investigate
Read the highest-value sources first:
- `README*`, root manifests, workspace config, lockfiles
- build, test, lint, formatter, typecheck, and codegen config
- CI workflows and pre-commit / task runner config
- existing instruction files (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, `.cursorrules`, `.github/copilot-instructions.md`)
- repo-local OpenCode config such as `opencode.json`
If architecture is still unclear after reading config and docs, inspect a small number of representative code files to find the real entrypoints, package boundaries, and execution flow. Prefer reading the files that explain how the system is wired together over random leaf files.
Prefer executable sources of truth over prose. If docs conflict with config or scripts, trust the executable source and only keep what you can verify.
## What to extract
Look for the highest-signal facts for an agent working in this repo:
- exact developer commands, especially non-obvious ones
- how to run a single test, a single package, or a focused verification step
- required command order when it matters, such as `lint -> typecheck -> test`
- monorepo or multi-package boundaries, ownership of major directories, and the real app/library entrypoints
- framework or toolchain quirks: generated code, migrations, codegen, build artifacts, special env loading, dev servers, infra deploy flow
- repo-specific style or workflow conventions that differ from defaults
- testing quirks: fixtures, integration test prerequisites, snapshot workflows, required services, flaky or expensive suites
- important constraints from existing instruction files worth preserving
Good `AGENTS.md` content is usually hard-earned context that took reading multiple files to infer.
## Questions
Only ask the user questions if the repo cannot answer something important. Use the `question` tool for one short batch at most.
Good questions:
- undocumented team conventions
- branch / PR / release expectations
- missing setup or test prerequisites that are known but not written down
Do not ask about anything the repo already makes clear.
## Writing rules
Include only high-signal, repo-specific guidance such as:
- exact commands and shortcuts the agent would otherwise guess wrong
- architecture notes that are not obvious from filenames
- conventions that differ from language or framework defaults
- setup requirements, environment quirks, and operational gotchas
- references to existing instruction sources that matter
Exclude:
- generic software advice
- long tutorials or exhaustive file trees
- obvious language conventions
- speculative claims or anything you could not verify
- content better stored in another file referenced via `opencode.json` `instructions`
When in doubt, omit.
Prefer short sections and bullets. If the repo is simple, keep the file simple. If the repo is large, summarize the few structural facts that actually change how an agent should work.
If `AGENTS.md` already exists at `/home/eponce/code/agent-zig`, improve it in place rather than rewriting blindly. Preserve verified useful guidance, delete fluff or stale claims, and reconcile it with the current codebase.



  [ ] Built-in tools — File operations
      - read:  Read file contents (with line range support)
      - write: Create/overwrite filesbash -c "$(curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh)" -s --source qwenchat
      - edit:  String replacement in files (old_string → new_string)
      - glob:  Find files by pattern (use std.fs.Dir.walk)
      - grep:  Search file contents with pattern matching
      - list:  Directory listing


  [ ] TUI enhancements
      - Display tool calls in chat (collapsible sections)
      - Show file paths as clickable/highlighted
      - Diff view for file edits (before/after)

  DELIVERABLE: The agent can autonomously read your codebase, suggest edits,
  and apply them with your approval.


  [ ] Agentic loop
      - Allow LLM to chain multiple tool calls
      - Max iterations limit (default: 25 steps)
      - Automatic error detection and retry logic
      - Stop conditions: task complete, max steps, user interrupt

  [ ] Conversation management
      - /clear command to reset conversation
      - /undo to revert last file change
      - /redo to re-apply reverted change
      - Command history (up/down arrows)

  [ ] Improved input
      - Multi-line input (Shift+Enter for newline)
      - Paste support (bracketed paste mode via vaxis)
      - Input history navigation

  DELIVERABLE: The agent can run tests, see failures, fix code, and re-run
  tests — all in a loop with minimal human intervention.

================================================================================
  PHASE 4 — Project Context & Intelligence
  Goal: Make the agent understand your project deeply
================================================================================

  [ ] Project context file
      - Read AGENTS.md / CLAUDE.md from project root
      - Auto-generate project summary on /init
      - Include in system prompt

  [ ] Smart context management
      - Token counting (estimate from message sizes)
      - Conversation compaction (summarize old messages when near limit)
      - File content caching (avoid re-reading unchanged files)

  [ ] Session persistence
      - SQLite database for conversations (use Zig SQLite binding or file-based)
      - Resume previous sessions
      - List sessions (/sessions command)
      - Session titles (auto-generated by LLM)

  [ ] Git integration
      - Detect git repo (read .git/)
      - Show git status in status bar
      - /commit command
      - /diff command
      - Branch awareness

  DELIVERABLE: The agent remembers your conversations, understands your
  project structure, and integrates with your git workflow.

================================================================================
  PHASE 5 — Multi-Provider & Multi-Agent
  Goal: Support multiple LLM providers and agent modes
================================================================================

  [ ] Provider abstraction
      - Provider interface: sendMessage(), streamMessage()
      - Anthropic (Claude) — already implemented
      - OpenAI (GPT-4o, o3)
      - Google (Gemini)
      - Ollama (local models — fully offline)
      - Provider selection in config + /model command

  [ ] Agent modes
      - "build" agent: full tool access (default)
      - "plan" agent: read-only, suggests but doesn't modify
      - Switch between agents with Tab key
      - Subagent support (@explore, @general)

  [ ] Custom agents
      - Define agents via markdown files in .agent/agents/
      - Custom system prompts, tool permissions, model overrides

  [ ] Task management
      - /todo command for task lists within sessions
      - Task status tracking (pending, in-progress, done)
      - Display task list in TUI sidebar

  DELIVERABLE: Use any LLM provider, switch between planning and building
  modes, and manage tasks within the agent.

================================================================================
  PHASE 6 — Advanced Features
  Goal: Reach feature parity with OpenCode
================================================================================

  [ ] MCP (Model Context Protocol) support
      - Launch local MCP servers (subprocess with stdio transport)
      - Connect to remote MCP servers (HTTP + OAuth)
      - Discover and expose MCP tools to the LLM

  [ ] LSP integration
      - Start language servers based on detected file types
      - Feed diagnostics to the agent (compile errors, warnings)
      - Go-to-definition, find-references for smarter code navigation

  [ ] Web tools
      - webfetch: Fetch and extract text from URLs
      - websearch: Search the web (via API)

  [ ] Image support
      - Accept image paths/drag-drop as input
      - Send images to vision-capable models
      - Screenshot capture for UI-related tasks

  [ ] File watching
      - Watch project files for external changes
      - Notify agent of file modifications
      - Auto-refresh context on changes

  [ ] Custom commands
      - Define slash commands as markdown files in .agent/commands/
      - Parameterized commands with $ARGUMENTS
      - Share command libraries

  DELIVERABLE: Full-featured AI coding agent competitive with OpenCode.

================================================================================
  PHASE 7 — Polish & Distribution
  Goal: Production-ready release
================================================================================

  [ ] Themes & appearance
      - Configurable color schemes
      - Syntax highlighting for code blocks (tree-sitter or regex-based)
      - Markdown rendering in chat

  [ ] Performance
      - Async I/O for all network operations
      - Connection pooling for API requests
      - Efficient memory management (arena allocators for requests)

  [ ] Packaging
      - Cross-compilation for Linux, macOS, Windows
      - Static binary (Zig's strength — zero runtime dependencies)
      - Install script (curl | bash)
      - Package manager entries (brew, pacman, etc.)

  [ ] Documentation
      - README with installation & usage
      - Configuration reference
      - Tool documentation
      - Contributing guide

  [ ] Testing
      - Unit tests for all tools
      - Integration tests with mock LLM server
      - TUI rendering tests

================================================================================
  ARCHITECTURE OVERVIEW
================================================================================

  src/
  ├── main.zig            Entry point, TUI initialization
  ├── app.zig             Application state, event dispatch
  ├── config.zig          Configuration loading & management
  │
  ├── tui/
  │   ├── layout.zig      Screen layout (chat area, input, status bar)
  │   ├── chat.zig        Chat message rendering
  │   ├── input.zig       Text input widget
  │   ├── status.zig      Status bar widget
  │   └── dialog.zig      Confirmation dialogs (tool permissions)
  │
  ├── llm/
  │   ├── provider.zig    Provider interface
  │   ├── anthropic.zig   Claude API client
  │   ├── openai.zig      OpenAI API client
  │   ├── message.zig     Message types (user, assistant, tool_use, tool_result)
  │   └── stream.zig      SSE streaming parser
  │
  ├── tools/
  │   ├── registry.zig    Tool registration & dispatch
  │   ├── read.zig        File read tool
  │   ├── write.zig       File write tool
  │   ├── edit.zig        File edit tool
  │   ├── glob.zig        File search tool
  │   ├── grep.zig        Content search tool
  │   ├── list.zig        Directory listing tool
  │   ├── bash.zig        Shell execution tool
  │   └── permission.zig  Permission checking
  │
  ├── agent/
  │   ├── loop.zig        Agentic execution loop
  │   ├── context.zig     Context/token management
  │   └── session.zig     Session persistence
  │
  └── util/
      ├── json.zig        JSON helpers
      ├── http.zig        HTTP client wrapper
      └── fs.zig          Filesystem utilities

================================================================================
  IMMEDIATE NEXT STEPS (Phase 1 kickoff)
================================================================================

  1. Set up project structure (copy build files from tui/, add src/ dirs)
  2. Implement HTTP client that can POST to Anthropic API
  3. Parse a simple non-streaming response and print it
  4. Add streaming (SSE) support
  5. Build the basic TUI: input → send → stream response → display
  6. Add conversation history (multi-turn)

================================================================================
  NOTES
================================================================================

  - Zig's std.http.Client supports HTTPS — no external deps needed for HTTP
  - Zig's std.json handles JSON parsing/serialization
  - libvaxis handles all terminal rendering, input, and events
  - Target: single static binary with zero runtime dependencies
  - All network I/O should be non-blocking where possible
  - Memory: use arena allocators for per-request allocations, GPA for long-lived

================================================================================

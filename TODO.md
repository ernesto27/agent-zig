
[x] - basic read tool file/
[x] - show thinking
[x] - show code before accept- deny
[x] - tool for search internet
[x] - add provider deep seek
[x] - when attach image show name for that in chat
[x] - first ctrl-c should empty input box
[x] - show image in TUI (PNG preview via Kitty protocol) 
[x] - show image preview for non-PNG formats (jpg, webp, etc.)
[x] - render attached text files preview in panel
[] - send message with only attachments (empty input + attached files)
[] - mouse wheel scroll for attachment preview panel
[] - show preview of sessions
[] - save session in jsonl
[] - on start TUI show this info [Context]
  AGENTS.md
[Skills]
  caveman, commit-push, find-skills, update-todo, zig-best-practices, zig-review
[Extensions]
  zig-fmt-check.t
[x] - save think in config.json
[] - command to copy to clipboar current session
[x] - only accept attach of images
[x] - show skill command as skills:nameskill
[] - when run skill,  execute
[] - export data to html
[] - share session using gist
[] - rename session
[] - show nice date created in session
[x] - add a system prompt
[] - add command tu run as cli query
[] - option to replace systemp prompt
[] - add reload
[] - when change session i want to update usage of context
[] - context use KB does not work in deep seek
[x] - create github actions ,  build TUI
[x] - compact session
[x] - fork session ,  new context
[] - add provider google
[] - connect to provider github copilot
[x] - save command result in history to resume
[x] - add option to run command bash
[] - add option to add folder to current context
[] - make tool calls in parallet internet
[] - show read file using
[x] - suuport skills protocol
[] - show folder running agent,  branch
[] - add copy text from input
[x] - exit command
[] - when accept all changes,  show files and dir created in preview
[] - model name at right bottom is cut /home/ernesto/Pictures/Screenshots/Screenshot from 2026-04-26 21-20-28.png
[x] - ctrl+c prevent close app, ask
[x] - show seconds, mins, in feedback, now only show seconds
[x] - clear conversation 
[x] - agent.log must be save in .config folder
[x] - refactor render 
[x] - when sho preview file,  put scroll at top
[x] - add plan mode
[] - when command to execute is big, overflow with questions /home/ernesto/Pictures/Screenshots/Screenshot from 2026-04-17 21-20-36.png
[] - fix model descriptcion space ,  
[] - do not show this err.httprequestfailes, show a nice error message
[] - when do some change or edit, explain what ihi
hs doing
[x] - command show,  is overlap with content text
[] - save in config.json thinking choosen
[] - when paste message large ,  format
[] - when update files only show diff changes, not all file
[] - init command
[] - paset larget text crash
[] - drag stop working
[] - somethimes code preview does not show 
[] - refactor providers llms services
[] - (low priority / cosmetic) pick ONE convention for method-bearing structs: `const Self = @This();` (App.zig, sandbox.zig) vs spelling out the type name (config.zig ConfigStore, command_picker.zig). Apply to new code; normalize a file only when already editing it.
[] - when think or executing show time counter
[] - save conversations to resume
[] - add arena options to have two models or more doint same task in paraller

## Sandbox (Docker)

[x] - /sandbox command: run tool actions in a Docker container on a git worktree branch
[] - commit worktree changes on the branch when the task finishes (auto-commit in container, e.g. on /sandbox off), so results land as a real commit instead of just uncommitted working-tree changes
[] - show a diff/summary of what changed when the sandbox stops
[] - configurable commit message (default: task summary) for the finish-task commit
[] - merge-back helper: command to merge the sandbox branch into the current branch

## MCP - missing features (real gaps, ranked)

[x] - mcp: add streamable HTTP / SSE transport
[x] - mcp: fix protocolVersion — sends "2025-11-25" (latest stable spec)

[] - mcp: add per-request timeout (read loop + stdio read + HTTP connect) — wedged server hangs agent thread forever during a tool call
[] - mcp: grow stdout_buf dynamically — 64 KB cap breaks stdio servers that emit large tool results or schemas
[] - mcp: surface RPC protocol error code+message to the model as tool_result — currently crashes call as error.RpcError, model can't self-correct
[] - mcp: cancel in-flight tools/call on Esc (today only the LLM stream cancels; MCP request keeps running)
[] - mcp: HTTP transport OAuth flow (needed for Linear/Notion/Sentry/Atlassian; v1 = static auth headers only)

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
- 
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

  [~] MCP (Model Context Protocol) support
      [x] Launch local MCP servers (subprocess with stdio transport)
      [x] Connect to remote MCP servers (HTTP streamable + SSE) — OAuth still pending
      [x] Discover and expose MCP tools to the LLM

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

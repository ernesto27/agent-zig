
[x] - basic read tool file
[] - show thinking
[x] - show code before accept- deny
[] - tool could not create child folders


================================================================================
  PHASE 1 — Minimal Chat Loop (MVP)
  Goal: Talk to an LLM from the terminal
================================================================================

  [x] Project scaffolding
      - Creata base project , with tui libvaxis

  [x] Basic TUI layout (from existing tui/ code)
      - Chat message area (scrollable)
      - Input field at bottom (multi-line later)
      - Status bar (model name, token count)
      - Keybindings: Enter=send, Ctrl+C=quit, Esc=cancel generation

  [x] HTTP client for LLM API
      - Implement HTTPS POST requests using Zig std.http.Client
      - Support streaming responses (SSE / Server-Sent Events)
      - Parse JSON responses (use std.json)
      - Start withi  Anthropic Claude API (Messages API)
        - POST https://api.anthropic.com/v1/messages
        - Headers: x-api-key, anthropic-version, content-type
        - Streaming: stream=true, parse event: content_block_delta

  [ ] Configuration
      - Optional: read from ~/.config/agent/config.json
      - Model selection (default: claude-sonnet-4-6)



  [ ] Conversation state
      - In-memory message history (user/assistant roles)
      - Send full conversation context with each request
      - Display streaming tokens as they arrive

  DELIVERABLE: A terminal app where you type a message, it streams a
  response from Claude, and you can have a multi-turn conversation.

================================================================================
  PHASE 2 — Tool System (File Operations)
  Goal: Let the LLM read and write files
================================================================================

  [ ] Tool execution framework
      - Define Tool interface: name, description, input_schema, execute()
      - Tool registry (register tools at startup)
      - Parse tool_use blocks from Claude API response
      - Send tool_result blocks back in conversation
      - Handle tool call chains (LLM calls tool → result → LLM continues)

  [ ] Built-in tools — File operations
      - read:  Read file contents (with line range support)
      - write: Create/overwrite files
      - edit:  String replacement in files (old_string → new_string)
      - glob:  Find files by pattern (use std.fs.Dir.walk)
      - grep:  Search file contents with pattern matching
      - list:  Directory listing

  [ ] Tool permission system
      - Per-tool permission modes: allow, ask, deny
      - TUI prompt for "ask" mode (Y/n confirmation)
      - Default: read tools = allow, write tools = ask, bash = ask

  [ ] TUI enhancements
      - Display tool calls in chat (collapsible sections)
      - Show file paths as clickable/highlighted
      - Diff view for file edits (before/after)

  DELIVERABLE: The agent can autonomously read your codebase, suggest edits,
  and apply them with your approval.

================================================================================
  PHASE 3 — Shell Execution & Agentic Loop
  Goal: Run commands and iterate on errors autonomously
================================================================================

  [ ] Bash tool
      - Execute shell commands (already have executeCommand from tui/)
      - Capture stdout, stderr, exit code
      - Timeout support (configurable, default 120s)
      - Working directory management
      - Environment variable passthrough
      - Dangerous command detection (rm -rf, git push --force, etc.)

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

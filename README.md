# Zigent

Terminal-based AI coding agent written in Zig.

## Features

- **Multi-provider LLM**: Anthropic (Claude Opus/Sonnet/Haiku), OpenAI (GPT-5 family), and DeepSeek (V4 Flash/Pro)
- **Streaming responses**: SSE streaming with real-time token display
- **Extended thinking**: Visible reasoning for thinking-capable models
- **Tool system** with approve/deny/accept-all confirmation UI:
  - `read_file`, `write_file`, `edit_file`, `bash`, `glob`, `grep`
  - `web_search`, `web_extract` (Tavily — requires API key)
- **Skills**: Load custom agent skills from `.agents/skills/`
- **Modes**: `build` and `plan` modes with tailored system prompts
- **Slash commands**: `/provider`, `/model`, `/clear`, `/resume`, `/init`, `/exit` + loaded skills
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

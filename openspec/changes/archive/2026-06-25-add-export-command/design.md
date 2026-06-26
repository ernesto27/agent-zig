## Context

Slash commands are declared in `src/commands/command_picker.zig` as a `CommandAction` enum plus a `commands` table, dispatched in `runSlashCommand` (`src/input_handler.zig`), and implemented as methods on `App` (`src/App.zig`) following the pattern of `compactCMD` / `initCMD`. The live conversation is already held in memory as `App.messages` (`src/messages.zig`), where `Messages.items` is a list of `Message { role, content, thinking, ... }` with `Role = { user, assistant, notice }`. The working directory is available via `std.fs.cwd()` and `realpathAlloc(".")` (used elsewhere in `App.zig`). This is the simplest, most accurate source for export — no need to re-parse session JSON logs.

## Goals / Non-Goals

**Goals:**
- Add `/export` that writes the current conversation to a self-contained HTML file in the project directory.
- Clean, simple, readable layout that distinguishes user from assistant.
- Escape HTML-significant characters so message text is shown literally.
- Report the saved path back to the user via a notice message.

**Non-Goals:**
- No search box, filtering, collapsing, or any client-side JavaScript.
- No theming options, export format choices, or destination prompts in this change.
- No rendering of tool calls/results or full markdown fidelity — plain message text is sufficient for a first version (thinking blocks are excluded).
- No re-reading of persisted session logs; export operates on in-memory `App.messages`.

## Decisions

- **Source of data: in-memory `App.messages.items`.** It already reflects the visible conversation and avoids JSON parsing. `notice` messages are skipped; only `user` and `assistant` roles are exported. Rationale over reading `sessions/*.log`: simpler, no parsing, matches what the user sees.

- **New module `src/commands/export.zig` owns all export logic.** It exposes `exportSession(alloc, msgs: []const Message) ![]u8`, which does the empty-session check, builds the HTML (internal `buildHtml`), writes the file to cwd, and returns an owned **notice string** describing the outcome (saved path, empty session, or write failure). `App.exportCMD` is a thin caller: it passes `self.messages.view()`, displays the returned notice via `appendNotice`, and frees it. Rationale: keeps file I/O and message formatting out of `App.zig`; `App` only bridges to the UI.

- **Markup lives in a template file, embedded with `@embedFile`.** The full HTML document (with its inline `<style>`) is stored in `src/commands/export_template.html` and embedded at compile time via `@embedFile`, matching the repo convention (`init.zig`, `compact.zig`). The template carries a `<!--MESSAGES-->` placeholder; `buildHtml` splits the template at that marker and splices the generated per-message `<div>`s in between. Rationale: keeps all CSS/markup out of the Zig source (easy to restyle without touching code) while still producing a single self-contained file with zero network requests. User and assistant turns get distinct CSS classes for a chat-like read.

- **HTML escaping helper.** Escape `&`, `<`, `>`, `"` when emitting message content. Preserve line breaks by rendering content inside `white-space: pre-wrap` so newlines survive without converting to `<br>`.

- **Filename: timestamped in cwd**, e.g. `session-export-<unix-ts>.html`, written with `std.fs.cwd().createFile`. A timestamp avoids clobbering previous exports and needs no user prompt.

- **Feedback via notice message.** Append a `Message{ .role = .notice, ... }` containing the absolute saved path, consistent with how other commands surface results, rather than returning `.send` to the LLM. `runSlashCommand` returns `.none`.

- **Empty conversation is a no-op with feedback.** If there are no exportable (`user`/`assistant`) messages, `exportCMD` does not write a file; it appends a notice telling the user the session is empty.

## Risks / Trade-offs

- [Large conversations produce large HTML] → Acceptable; output is static and a browser handles long pages. No pagination needed for a first version.
- [Plain-text rendering loses markdown formatting (code blocks, lists)] → Acceptable for "simple, view-only"; `pre-wrap` keeps readability. Markdown rendering can be a later enhancement.
- [Writing into cwd may fail on read-only directories] → Handle the error and append an error notice instead of crashing.
- [Excluding thinking blocks] → Intentional to keep the view clean; revisit if users want it.

## Why

Users currently have no way to take a conversation out of the TUI. Sessions live as JSON logs under `~/.config/agent-zig/sessions/` that are not meant for human reading or sharing. A `/export` command that writes a clean, self-contained HTML file into the current project lets users save, read, and share a conversation in a browser.

## What Changes

- Add a new `/export` slash command to the command picker.
- When invoked, capture the current session's conversation (user and assistant turns) and render it to a single self-contained HTML file.
- Save the file into the current project directory (the process working directory).
- The HTML is view-only: a simple, readable layout that visually distinguishes user messages from assistant messages. No search box, no interactivity, no external assets.
- Surface the saved file path back to the user as a notice in the TUI.

## Capabilities

### New Capabilities
- `session-export`: Exporting the active conversation to a self-contained, view-only HTML file in the current project directory.

### Modified Capabilities
<!-- None: no existing spec requirements change. -->

## Impact

- `src/commands/command_picker.zig`: new `export` entry in `CommandAction` and `commands`.
- `src/input_handler.zig`: dispatch the new action in `runSlashCommand`.
- `src/App.zig`: new `exportCMD` method that reads `Messages.items`, builds HTML, writes the file to cwd, and appends a notice message.
- New module (e.g. `src/commands/export.zig`) to build the HTML document.
- No new external dependencies; output is a static HTML file.

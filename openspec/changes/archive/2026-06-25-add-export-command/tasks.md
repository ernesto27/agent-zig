## 1. HTML template + export module

- [x] 1.1 Create `src/commands/export_template.html`: full self-contained document with inline `<style>` (no JS, no external assets) and a `<!--MESSAGES-->` placeholder
- [x] 1.2 Create `src/commands/export.zig` as an `Export` struct (same convention as `compact.zig`) that embeds the template with `@embedFile`
- [x] 1.3 Build per-message `<div>`s for `user`/`assistant` only (distinct CSS classes, HTML-escape `&`,`<`,`>`,`"`; skip `notice` and thinking), then splice into the template at the placeholder

## 2. Command wiring

- [x] 2.1 Add `export_session` to `CommandAction` and an `export` `commands` entry in `src/commands/command_picker.zig`
- [x] 2.2 Dispatch `.export_session` in `runSlashCommand` (`src/input_handler.zig`), guarding on `loading.active` and calling `App.exportCMD`, returning `.none`

## 3. Export logic lives in export.zig (not App.zig)

- [x] 3.1 `Export.exportSession(allocator, msgs) ![]u8` does the empty-session check and returns an owned "empty session" notice when there is nothing to export
- [x] 3.2 Build HTML and write to `session-export-<unix-ts>.html` in cwd using `std.fs.cwd().createFile`
- [x] 3.3 Return an owned notice string: absolute saved path on success, or a failure notice on write error (no crash). `App.exportCMD` only displays the notice via `appendNotice`

## 4. Verify

- [x] 4.1 `zig build` compiles clean
- [ ] 4.2 `zig build run`; trigger `/export`, confirm the file is created in the project directory and opens correctly in a browser offline; verify HTML-significant characters display literally and the empty-session case shows the notice

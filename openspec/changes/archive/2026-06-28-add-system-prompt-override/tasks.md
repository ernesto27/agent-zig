## 1. Core implementation

- [x] 1.1 In `src/system_prompt.zig::readContent`, attempt to open `SYSTEM.md` in cwd before falling back to `src/prompts/system.txt`; set the base content from whichever source succeeds.
- [x] 1.2 On `SYSTEM.md` open/read failure (file exists but unreadable), log via `std.log.scoped(.app)` and fall back to `src/prompts/system.txt`; keep the missing-file path as a clean fallback (no log spam).
- [x] 1.3 Preserve the existing `AGENTS.md` append step so it runs identically regardless of whether the base came from `SYSTEM.md` or `system.txt`.

## 2. Tests

- [~] 2.1 Skipped per user.
- [~] 2.2 Skipped per user.
- [~] 2.3 Skipped per user.

## 3. Verification

- [x] 3.1 Run `zig build test` and confirm both the library module (`src/root.zig`) and app module (`src/main.zig`) test executables pass.
- [x] 3.2 Run `zig build` to confirm the app compiles cleanly.

---
name: update-version
description: Bump the TUI app version, keeping build.zig and build.zig.zon in sync. Use when the user says "update version", "bump version", "/update-version", "release 0.0.x", or wants to cut a new version before tagging a release.
---

# Update TUI Version

Bump the app version in the two places that must always match. The version is the source of truth for the `--version` flag and the release tag.

## Version locations (both required, must match)

- `build.zig` — `const app_version = "X.Y.Z";` (near top, ~line 3). Compiled into the binary via `build_options.addOption(..., "version", app_version)`.
- `build.zig.zon` — `.version = "X.Y.Z",` (~line 12). Package manifest version.

If these two ever disagree, the build still compiles but the manifest and the runtime `--version` report different numbers. Always update both.

## Steps

1. **Read the current version** from `build.zig` (`app_version`) and `build.zig.zon` (`.version`). Confirm they currently match; if they don't, flag it to the user before proceeding.

2. **Determine the target version** from the user's argument:
   - Explicit version (`/update-version 0.1.0`) → use it verbatim.
   - Bump keyword (`patch` / `minor` / `major`) → apply semver bump to the current version. Default to `patch` if no argument given.
   - Validate the result matches `^\d+\.\d+\.\d+$`. Refuse anything else.

3. **Apply edits** with the Edit tool to both files:
   - `build.zig`: replace `const app_version = "<old>";` → `const app_version = "<new>";`
   - `build.zig.zon`: replace `.version = "<old>",` → `.version = "<new>",`

4. **Verify** with `zig build` — confirm it compiles. Then `grep -n "<new>" build.zig build.zig.zon` to confirm both files carry the new version and the old version is gone.

5. **Report**: old → new version, and the two files changed.

## Rules

- Never bump only one file. Both or neither.
- Do not commit, tag, or push unless the user explicitly asks. Cutting the tag (`git tag vX.Y.Z`) is what triggers the release workflow — leave that to the user.
- Do not touch `minimum_zig_version` in `build.zig.zon` — that is the Zig toolchain version, not the app version.
- If the user passes a full version that is lower than the current one, warn before applying (likely a typo).

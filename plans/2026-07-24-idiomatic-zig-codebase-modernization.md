# Idiomatic Zig Codebase Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor agent-zig into an idiomatic, maintainable Zig 0.15.2 codebase with executable tests, explicit ownership, a Vaxis-free core module, and smaller state owners while preserving current behavior.

**Architecture:** Keep the existing concrete Zig design and split it into three dependency directions: a reusable `agent` core, a Vaxis TUI, and headless CLI entrypoints. Introduce typed state and ownership contracts before moving orchestration code, then split tools and providers only after their public interfaces are stable.

**Tech Stack:** Zig 0.15.2, libvaxis 0.5.1, Zig build system, GitHub Actions. No new runtime dependencies.

**Date:** 2026-07-24

**Domains:** Zig architecture, TUI, build/test infrastructure

**Author:** plan-from-spec (reviewed with ernestoponce27@gmail.com)

**Status:** Draft

## Global Constraints

- Work directly on `master`; do not create a feature branch or worktree.
- Do not commit unless the user explicitly asks. If commits are requested, use one-line subjects and no `Co-Authored-By` trailer.
- Preserve user-visible behavior, persisted config compatibility, session compatibility, provider support, and the single-static-binary property.
- Do not optimize performance or combine this work with unrelated bug fixes.
- Use `std.ArrayList(T){}` / unmanaged containers with allocators passed per operation, matching current Zig 0.15.2 conventions in this repository.
- Keep allocator ownership explicit; every public allocating return documents who frees it.
- Use `camelCase` for functions, `TitleCase` for types, and `snake_case` for variables, fields, namespace files, and enum tags.
- Verification for every task is `zig fmt --check src build.zig build.zig.zon`, `zig build`, and `zig build test`, plus focused tests named by the task.
- Code previews below define target interfaces and exact structural changes. During implementation, retain current provider JSON and Vaxis call details surrounding the changed blocks.

---

## 1. Summary

The repository has good leaf modules and working functionality, but its maintenance boundaries are obscured by a broad `App`, a 600-line `main` event loop, an input context with many borrowed pointers, a core module that imports Vaxis, and result/message types with unclear ownership. The first milestone fixes the misleading test target: 57 source tests exist, but both current test executables run zero tests. Later milestones separate core data from rendering, make variant states typed, move TUI lifecycle into a `Tui` owner, and reduce duplication in tool and provider registration.

This is an incremental refactor. Every task leaves a compiling application and can be reviewed independently.

## 2. Scope

### In scope

- Make all existing unit tests discoverable by `zig build test`.
- Replace network-dependent tests with deterministic in-process fixtures and fakes.
- Enforce `zig fmt --check` in CI.
- Remove Vaxis and theme dependencies from the reusable `agent` module.
- Separate persisted settings data from the settings modal.
- Separate message queue data from queue rendering.
- Replace string-plus-optionals domain variants with tagged unions.
- Give tool results one unambiguous ownership contract.
- Introduce a `Tui` owner and reduce `main()` to bootstrap code.
- Centralize mutually exclusive overlays.
- Split `tools.zig` by responsibility and use typed input structs.
- Replace the global OpenRouter store with an injected provider catalog.
- Normalize naming and remove the catch-all `utils` namespace.
- Add short architecture and development documentation.

### Out of scope / non-goals

- Changing TUI appearance, keyboard shortcuts, commands, prompts, or tool behavior.
- Changing persisted `config.json` keys or session JSONL format.
- Adding providers, tools, MCP capabilities, or sandbox features.
- Performance tuning, allocation-count reduction, or provider protocol redesign.
- Replacing libvaxis or introducing a framework, dependency-injection library, or runtime reflection system.
- A one-shot rewrite of all files.

## 3. Resolved decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Is the reusable `agent` module retained? | Yes. Headless mode benefits from it, but it must not depend on Vaxis or TUI rendering. |
| 2 | How is the modernization delivered? | Incremental tasks with a build/test gate after every task. |
| 3 | What is the first change? | Repair test discovery and formatting enforcement before structural refactors. |
| 4 | How are network tests handled? | They are replaced by deterministic unit/component tests with embedded fixtures and injected in-process transports; no listener or external process is used. |
| 5 | How are variant states represented? | `union(enum)` when variants carry distinct data; plain `enum` for stateless modes. |
| 6 | What is the tool-result ownership rule? | Every `ToolResult.content` is owned `[]u8`; ownership transfers to conversation history or is released by `deinit`. |
| 7 | How are infrastructure failures represented? | Zig error unions; model-visible tool failures remain `ToolResult{ .is_error = true }`. |
| 8 | Is comptime host dispatch retained? | Yes. `agent_loop` keeps its comptime host but gains a compile-time contract and fake-host tests. |
| 9 | How are provider implementations abstracted? | Keep an explicit backend `switch`; provider catalog entries carry their backend instead of deriving it from strings. |
| 10 | How is dynamic provider state owned? | `ProviderCatalog` owns `OpenRouterStore`; no public mutable module global. |
| 11 | How far is the TUI split taken? | One `Tui.zig` lifecycle owner plus focused state/input/render namespaces; no file-per-widget rewrite. |
| 12 | Are config keys renamed? | No. Wire-format structs retain existing camelCase keys and convert to idiomatic internal state where needed. |
| 13 | Are all silent `catch` expressions removed? | No. Domain/infrastructure errors propagate; intentionally best-effort UI/log/shutdown paths may catch with a comment or scoped log. |
| 14 | Are existing planning artifacts deleted? | No history is deleted. Completed plans are retained; the active backlog is cleaned and new architecture is documented in one place. |

## 4. Target design

### 4.1 Dependency direction

```text
src/main.zig
    |
    +--> src/Tui.zig --------------------> vaxis, theme
    |        |                              TUI-only modules
    |        +--> input_handler.zig
    |        +--> ui.zig
    |        +--> pickers / modal_list
    |
    +--> @import("agent") ---------------> no vaxis/theme import
             |
             +--> agent_loop.zig
             +--> conversation/message model
             +--> tools + sandbox
             +--> llm providers/catalog
             +--> mcp
             +--> config/settings data
             +--> skills/tasks/message queue
```

`src/root.zig` exports only core declarations. TUI files import `agent` for core data and use local imports for Vaxis renderers.

### 4.2 Runtime ownership

```text
main()
  owns allocator, ConfigStore, ProviderCatalog, Client, App, Tui

App
  owns agent-session state and background request coordination
  does not own terminal widgets, pickers, selection, or frame buffers

Tui
  owns terminal/Vaxis lifecycle, input editor, overlays, selection,
  scrolling, frame arenas, render state, and the event loop

Conversation
  owns canonical messages and provider-neutral content blocks

ProviderCatalog
  owns static provider metadata plus dynamic OpenRouter data
```

### 4.3 Background-to-UI flow

The first migration keeps the existing mutex and wake mechanism but hides them behind `App` methods. The final shape uses typed notifications:

```zig
pub const AppEvent = union(enum) {
    redraw,
    request_finished: agent_loop.Outcome,
    mcp_catalog_changed,
    sandbox_changed,
};

pub const NotifyFn = *const fn (ctx: *anyopaque, event: AppEvent) void;
```

`App` invokes the callback; `Tui` owns the Vaxis event-loop wake operation. No core module stores a `vaxis.Loop` pointer.

### 4.4 Error policy

- Public core functions return typed or inferred error unions rather than converting allocation failures into success strings.
- Expected model-visible failures use `ToolResult.is_error`.
- UI rendering may return early on frame-arena exhaustion.
- Shutdown/logging may ignore secondary failures, but the code states why.
- Public allocation APIs return `[]u8` and document caller ownership.

## 5. File map

| Action | File | Final responsibility |
|--------|------|----------------------|
| Modify | `build.zig` | Core, executable, unit-test, and run build graph only; remove template commentary. |
| Modify | `.github/workflows/ci.yml` | Format, unit tests, native build, Windows cross-build. |
| Modify | `src/root.zig` | Small Vaxis-free public core surface and unit-test discovery. |
| Create | `src/root_tests.zig` | Imports every core unit-test-bearing module. |
| Create | `src/app_tests.zig` | Imports every TUI unit-test-bearing module. |
| Create | `src/settings.zig` | Persisted settings data only; no Vaxis. |
| Modify | `src/commands/settings.zig` | Settings modal state/rendering only. |
| Modify | `src/message_queue.zig` | FIFO ownership only; no rendering. |
| Modify | `src/ui.zig` | Queue rendering and top-level view rendering. |
| Modify | `src/modal_list.zig` and picker files | Local TUI imports instead of `agent.modal_list`. |
| Modify | `src/markdown.zig`, `src/messages.zig`, `src/chat_selection.zig` | TUI-local markdown types; no `agent.markdown` export. |
| Modify | `src/llm/message.zig` | Provider-neutral tagged content model. |
| Modify | `src/llm/{anthropic,openai,gemini,client}.zig` | Wire adapters to/from the tagged content model. |
| Modify | `src/sessions.zig`, `src/messages.zig`, `src/agent_loop.zig` | Canonical content ownership and serialization. |
| Modify | `src/tools.zig` | Tool public API, definitions, dispatch, and backend selection. |
| Create | `src/tools/filesystem.zig` | Read/write/edit/glob/grep implementation. |
| Create | `src/tools/shell.zig` | Host/sandbox shell implementation. |
| Create | `src/tools/skills.zig` | Skill/resource/script tool implementation. |
| Create | `src/tools/task_write.zig` | Typed task-write parsing and application. |
| Create | `src/tools/schema.zig` | Schema parsing and required-field extraction. |
| Modify | `src/llm/providers.zig` | Provider identifiers, metadata, store implementation; no global. |
| Create | `src/llm/catalog.zig` | Runtime-owned provider catalog. |
| Modify | picker and startup files | Receive a catalog pointer instead of reading a global. |
| Create | `src/Tui.zig` | Terminal lifecycle, event loop, frame rendering, and UI ownership. |
| Create | `src/tui_state.zig` | Input editor, scroll, selection, overlay, and picker ownership. |
| Modify | `src/main.zig` | Argument/config/runtime bootstrap only. |
| Modify | `src/App.zig` | Agent-session coordination and typed app events. |
| Modify | `src/input_handler.zig` | Key routing against `TuiState`, not a bag of borrowed pointers. |
| Modify | `src/mode.zig`; delete `src/modes/*.zig` after migration | Stateless mode enum and policy in one cohesive module. |
| Create | `src/environment.zig` | Environment and home-directory helpers. |
| Create | `src/git_info.zig` | Current repository display information. |
| Create | `src/text.zig` | UTF-8-safe display truncation. |
| Delete | `src/utils.zig` after callers migrate | Replaced by focused namespaces. |
| Modify | `src/context_usage.zig` | Idiomatic type and field names. |
| Create | `docs/architecture.md` | Stable dependency, ownership, and concurrency guide. |
| Modify | `README.md`, `AGENTS.md`, `TODO.md` | Development commands, verified structure, and clean active backlog. |

## 6. Interfaces and contracts

### 6.1 Provider-neutral content

Replace `ContentBlock.type` plus nullable fields with:

```zig
pub const Thinking = struct {
    text: []const u8,
    signature: []const u8 = "",
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: Thinking,
    tool_use: ToolUse,
    image: ImageSource,

    pub fn jsonStringify(self: ContentBlock, jw: anytype) !void {
        switch (self) {
            .text => |text| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(text);
                try jw.endObject();
            },
            .thinking => |thinking| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("thinking");
                try jw.objectField("thinking");
                try jw.write(thinking.text);
                if (thinking.signature.len > 0) {
                    try jw.objectField("signature");
                    try jw.write(thinking.signature);
                }
                try jw.endObject();
            },
            .tool_use => |tool| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("tool_use");
                try jw.objectField("id");
                try jw.write(tool.id);
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("input");
                try jw.write(tool.input);
                try jw.endObject();
            },
            .image => |image| try image.jsonStringify(jw),
        }
    }
};
```

Provider wire structs remain private to each adapter. They convert to this union after parsing.

JSON values inside tool-use blocks follow the same ownership rule as the enclosing block. Use recursive clone/deinit helpers instead of copying `std.json.Value` containers:

```zig
pub fn cloneJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{
            .number_string = try allocator.dupe(u8, item),
        },
        .string => |item| .{ .string = try allocator.dupe(u8, item) },
        .array => |array| blk: {
            var copy = std.json.Array.init(allocator);
            errdefer {
                for (copy.items) |*item| deinitJsonValue(allocator, item);
                copy.deinit();
            }
            for (array.items) |item| {
                var item_copy = try cloneJsonValue(allocator, item);
                copy.append(item_copy) catch |err| {
                    deinitJsonValue(allocator, &item_copy);
                    return err;
                };
            }
            break :blk .{ .array = copy };
        },
        .object => |object| blk: {
            var copy = std.json.ObjectMap.init(allocator);
            errdefer {
                var copy_it = copy.iterator();
                while (copy_it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr);
                }
                copy.deinit();
            }
            var object_it = object.iterator();
            while (object_it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                var item_copy = cloneJsonValue(
                    allocator,
                    entry.value_ptr.*,
                ) catch |err| {
                    allocator.free(key);
                    return err;
                };
                copy.put(key, item_copy) catch |err| {
                    allocator.free(key);
                    deinitJsonValue(allocator, &item_copy);
                    return err;
                };
            }
            break :blk .{ .object = copy };
        },
    };
}

pub fn deinitJsonValue(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
) void {
    switch (value.*) {
        .number_string => |item| allocator.free(item),
        .string => |item| allocator.free(item),
        .array => |*array| {
            for (array.items) |*item| deinitJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
    value.* = .null;
}
```

### 6.2 Tool result ownership

```zig
pub const ToolResult = struct {
    content: []u8,
    is_error: bool = false,

    pub fn success(allocator: std.mem.Allocator, text_value: []const u8) !ToolResult {
        return .{ .content = try allocator.dupe(u8, text_value) };
    }

    pub fn failure(allocator: std.mem.Allocator, text_value: []const u8) !ToolResult {
        return .{
            .content = try allocator.dupe(u8, text_value),
            .is_error = true,
        };
    }

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    ctx: Context,
    tool_name: []const u8,
    input: std.json.Value,
) !ToolResult;
```

Contract: the caller owns `content`. `agent_loop` transfers that allocation into the history block. Callers that do not transfer it invoke `deinit`.

### 6.3 Tool activity and confirmation

```zig
pub const ToolActivity = union(enum) {
    idle,
    generic: []const u8,
    grep: GrepStatus,
    glob: GlobStatus,
    web: WebStatus,
};

pub const ConfirmationState = union(enum) {
    idle,
    waiting: PendingConfirmation,
    resolved: ConfirmationAction,
};

pub const PendingConfirmation = struct {
    tool_name: []const u8,
    tool: ?agent.tools.ToolName,
    file_path: []const u8,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    start_line: usize,
    cursor: ConfirmationAction,
};
```

The condition variable remains in the confirmation controller, not inside the variant payload.

### 6.4 Provider catalog

```zig
pub const ProviderId = enum {
    anthropic,
    openai,
    deep_seek,
    gemini,
    open_router,
};

pub const Backend = enum {
    anthropic,
    openai,
    gemini,
};

pub const Provider = struct {
    id: ProviderId,
    name: []const u8,
    backend: Backend,
    models: []const Model,
};

pub const Catalog = struct {
    open_router: providers.OpenRouterStore = .{},

    pub fn deinit(self: *Catalog) void {
        self.open_router.deinit();
    }

    pub fn findModel(self: *Catalog, id: []const u8) ?providers.FindResult {
        return providers.findStaticModel(id) orelse self.open_router.find(id);
    }
};
```

### 6.5 App notification boundary

```zig
pub const Notifier = struct {
    ctx: *anyopaque,
    notify_fn: *const fn (ctx: *anyopaque, event: AppEvent) void,

    pub fn notify(self: Notifier, event: AppEvent) void {
        self.notify_fn(self.ctx, event);
    }
};
```

`App` depends on `Notifier`, never on `vaxis.Event` or `vaxis.Loop`.

## 7. Implementation tasks

### Task 1 — Make tests and formatting real

**Why:** All later refactors need an executable safety net; current `zig build test` runs zero tests.

**Files:**

- Create: `src/root_tests.zig`
- Create: `src/app_tests.zig`
- Modify: `src/root.zig`
- Modify: `src/main.zig`
- Modify: `src/llm/client.zig`
- Modify: `build.zig`
- Modify: `.github/workflows/ci.yml`
- Format: `src/sandbox.zig`, `src/mcp/client.zig`

**Interfaces:**

- Produces: unit-test discovery through the existing `test` step.
- Produces: deterministic request/response fixture tests that require no listening server or network access.

- [ ] **Step 1: Capture the failing baseline**

Run:

```bash
zig build test --summary all
zig build test --verbose
```

Expected before the change: both generated test executables complete in roughly microseconds and print `All 0 tests passed` when run directly.

- [ ] **Step 2: Add core test discovery**

Create `src/root_tests.zig`:

```zig
test {
    _ = @import("config.zig");
    _ = @import("json_helpers.zig");
    _ = @import("llm/client.zig");
    _ = @import("llm/message.zig");
    _ = @import("llm/providers.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("tools.zig");
    _ = @import("utils.zig");
}
```

Add to the end of `src/root.zig`:

```zig
test {
    _ = @import("root_tests.zig");
}
```

- [ ] **Step 3: Add executable/TUI test discovery**

Create `src/app_tests.zig`:

```zig
test {
    _ = @import("chat_selection.zig");
    _ = @import("image_attach.zig");
    _ = @import("modes/plan.zig");
    _ = @import("sessions.zig");
}
```

Add to the end of `src/main.zig`:

```zig
test {
    _ = @import("app_tests.zig");
}
```

- [ ] **Step 4: Replace network-dependent client tests**

Delete the two tests in `src/llm/client.zig` that call `anthropic.sendMessage` over the network. Replace them with deterministic tests at the provider boundary:

- request serialization from single-turn and multi-turn `Message` values;
- response parsing from embedded JSON fixtures;
- streaming normalization from embedded SSE/event fixtures;
- `statusToError` and error-message mapping.

Extract pure request-building and response-parsing functions only where needed to make those tests possible. Tests pass fixture bytes directly to the parser and never open a socket, start a process, or depend on external state.

- [ ] **Step 5: Enforce formatting in CI**

Change `.github/workflows/ci.yml` test steps to:

```yaml
      - run: zig fmt --check src build.zig build.zig.zon
      - run: zig build test
      - run: zig build
      - run: zig build -Dtarget=x86_64-windows
```

Run `zig fmt src/sandbox.zig src/mcp/client.zig` so the new gate starts green.

- [ ] **Step 6: Verify**

Run:

```bash
zig fmt --check src build.zig build.zig.zon
zig build
zig build test --summary all
```

Expected: format passes, build passes, and the test executables run the source tests rather than zero tests.

- [ ] **Step 7: Optional commit if explicitly authorized**

```bash
git add .github/workflows/ci.yml build.zig src
git commit -m "make Zig tests discoverable"
```

### Task 2 — Make the core module Vaxis-free

**Why:** The public `agent` module currently exports rendering code and therefore cannot act as a clean headless core.

**Files:**

- Create: `src/settings.zig`
- Modify: `src/root.zig`
- Modify: `build.zig`
- Modify: `src/message_queue.zig`
- Modify: `src/ui.zig`
- Modify: `src/commands/settings.zig`
- Modify: `src/App.zig`
- Modify: `src/input_handler.zig`
- Modify: `src/main.zig`
- Modify: `src/messages.zig`
- Modify: `src/chat_selection.zig`
- Modify: picker files importing `agent.modal_list`

**Interfaces:**

- Produces: `agent.settings.Settings`, a data-only config type.
- Produces: `commands/settings.zig.SettingsModal`, a TUI-only modal.
- Preserves: existing config JSON keys and settings behavior.

- [ ] **Step 1: Write a core-boundary test**

Add a build-only test that compiles `src/root.zig` without `vaxis` or `theme` imports. This test initially fails because `agent.settings`, `agent.markdown`, `agent.modal_list`, and `agent.message_queue` reach Vaxis.

- [ ] **Step 2: Extract settings data**

Create `src/settings.zig`:

```zig
pub const Setting = struct {
    status: bool = false,
};

pub const Settings = struct {
    showThinking: Setting = .{},
    testOption: Setting = .{},
};
```

The camelCase fields are retained as wire-format compatibility fields.

Change `src/config.zig` to:

```zig
const settings = @import("settings.zig");
```

Change `src/root.zig` to export:

```zig
pub const settings = @import("settings.zig");
```

- [ ] **Step 3: Convert the existing settings type into a modal**

In `src/commands/settings.zig`, import `agent.settings` and rename the UI type:

```zig
pub const SettingsModal = struct {
    value: agent.settings.Settings,
    active: bool = false,
    selected: usize = 0,

    pub fn init(value: agent.settings.Settings) SettingsModal {
        return .{ .value = value };
    }

    pub fn config(self: *const SettingsModal) agent.settings.Settings {
        return self.value;
    }
};
```

Update its comptime field iteration to inspect `agent.settings.Settings` and mutate `self.value`. Rename `App.settings` to `App.settings_modal`; use `settings_modal.value.showThinking.status` in streaming display and `settings_modal.config()` when persisting.

- [ ] **Step 4: Remove rendering from `MessageQueue`**

Delete the `vaxis` and `theme` imports and the `render` method from `src/message_queue.zig`. Add this renderer to `src/ui.zig`:

```zig
pub fn renderMessageQueue(
    queue: *const agent.message_queue.MessageQueue,
    win: vaxis.Window,
    top_y: u16,
    max_rows: u16,
) void {
    const messages = queue.getAll();
    const n: u16 = @min(@as(u16, @intCast(messages.len)), max_rows);
    for (messages[0..n], 0..) |msg, i| {
        const row = top_y + @as(u16, @intCast(i));
        const prefix = win.printSegment(.{
            .text = "Steering: ",
            .style = .{ .fg = palette.cyan },
        }, .{ .row_offset = row, .col_offset = 1 });
        _ = win.printSegment(.{
            .text = msg,
            .style = .{ .fg = palette.dim },
        }, .{ .row_offset = row, .col_offset = prefix.col });
    }
}
```

Update the current call site to `ui.renderMessageQueue(...)`.

- [ ] **Step 5: Make markdown and modal list TUI-local**

Remove `markdown` and `modal_list` exports from `src/root.zig`.

In `messages.zig` and `chat_selection.zig`, replace `agent.markdown` with:

```zig
const markdown = @import("markdown.zig");
```

In `model_picker.zig`, `provider_picker.zig`, `logout_picker.zig`, `mcp_picker.zig`, `skills_picker.zig`, and `sessions.zig`, replace `agent.modal_list` with:

```zig
const modal_list = @import("modal_list.zig");
```

- [ ] **Step 6: Remove Vaxis imports from the core module graph**

In `build.zig`, remove:

```zig
mod.addImport("vaxis", vaxis_dep.module("vaxis"));
mod.addImport("theme", theme_mod);
```

Keep both imports on the executable root module.

- [ ] **Step 7: Verify**

Run:

```bash
zig fmt src build.zig
zig fmt --check src build.zig build.zig.zon
zig build
zig build test
```

Expected: the `agent` module compiles without Vaxis/theme imports; the TUI and settings behavior remain available through the executable module.

### Task 3 — Introduce typed conversation content

**Why:** `ContentBlock` currently permits invalid combinations and forces string comparisons throughout providers, sessions, and the agent loop.

**Files:**

- Modify: `src/llm/message.zig`
- Modify: `src/llm/client.zig`
- Modify: `src/llm/anthropic.zig`
- Modify: `src/llm/openai.zig`
- Modify: `src/llm/gemini.zig`
- Modify: `src/agent_loop.zig`
- Modify: `src/App.zig`
- Modify: `src/messages.zig`
- Modify: `src/sessions.zig`

**Interfaces:**

- Produces: `message.ContentBlock` tagged union from §6.1.
- Produces: `message.cloneContentBlock(allocator, block)`.
- Produces: `message.deinitContentBlock(allocator, block)`.

- [ ] **Step 1: Add failing content-model tests**

Add tests in `src/llm/message.zig` for JSON serialization of `.text`, `.thinking`, `.tool_use`, and `.image`, plus a clone/deinit test using `std.testing.allocator`.

Test shape:

```zig
test "ContentBlock serializes tool use without unrelated fields" {
    const allocator = std.testing.allocator;
    const block: ContentBlock = .{ .tool_use = .{
        .id = "call-1",
        .name = "read_file",
        .input = .null,
    } };
    const json = try std.json.Stringify.valueAlloc(allocator, block, .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\"") == null);
}
```

- [ ] **Step 2: Replace the struct with the tagged union**

Apply the §6.1 interface. Give `ImageSource` its own `jsonStringify` method.

Add ownership helpers:

```zig
pub fn cloneContentBlock(
    allocator: std.mem.Allocator,
    block: ContentBlock,
) !ContentBlock {
    return switch (block) {
        .text => |text_value| .{ .text = try allocator.dupe(u8, text_value) },
        .thinking => |thinking| .{ .thinking = .{
            .text = try allocator.dupe(u8, thinking.text),
            .signature = try allocator.dupe(u8, thinking.signature),
        } },
        .tool_use => |tool| .{ .tool_use = .{
            .id = try allocator.dupe(u8, tool.id),
            .name = try allocator.dupe(u8, tool.name),
            .input = try cloneJsonValue(allocator, tool.input),
        } },
        .image => |source| .{ .image = try source.clone(allocator) },
    };
}
```

The same module provides the matching exhaustive deinitializer.

- [ ] **Step 3: Convert provider wire adapters**

Keep provider-specific response structs private. Each adapter converts parsed wire blocks with an exhaustive switch or type-name comparison at the boundary only.

Example normalized construction:

```zig
try blocks.append(allocator, .{ .tool_use = .{
    .id = try allocator.dupe(u8, wire.id),
    .name = try allocator.dupe(u8, wire.name),
    .input = try cloneJsonValue(allocator, wire.input),
} });
```

Replace request-building field checks such as `block.type == "image"` with:

```zig
switch (block) {
    .text => |text_value| try appendTextPart(allocator, out, text_value),
    .image => |source| try appendImagePart(allocator, out, source),
    .thinking => |thinking| try appendThinkingPart(allocator, out, thinking),
    .tool_use => |tool| try appendToolUsePart(allocator, out, tool),
}
```

- [ ] **Step 4: Convert agent loop and App construction**

Replace `splitResponse` string tests with tagged-union switches. Replace attachment construction in `App.fetchAiResponse`:

```zig
blocks[0] = .{ .text = text };
try image_blocks.append(alloc, .{ .image = .{
    .media_type = mime,
    .data = b64,
    .path = alloc.dupe(u8, path) catch null,
} });
```

- [ ] **Step 5: Centralize conversation deallocation**

Replace manual content-block field frees in `messages.zig` and `sessions.zig` with `message.deinitContentBlock`. Every exhaustive switch must compile without `else`.

- [ ] **Step 6: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
```

Expected: tagged-block serialization tests pass, provider request fixture tests pass, and there are no remaining `ContentBlock.type` string comparisons outside provider wire parsing.

Check:

```bash
rg -n 'block\\.type|\\.type = "(text|thinking|tool_use|image)"' src
```

Expected: only provider wire DTO declarations or external JSON keys remain.

### Task 4 — Make tool-result ownership explicit

**Why:** `ToolResult.content` currently mixes literals and allocations, obscuring who releases memory.

**Files:**

- Modify: `src/tools.zig`
- Modify: `src/tools/web.zig`
- Modify: `src/sandbox.zig`
- Modify: `src/mcp/registry.zig`
- Modify: `src/agent_loop.zig`
- Modify: `src/modes/shell.zig`
- Modify: `src/input_handler.zig`
- Modify: `src/App.zig`

**Interfaces:**

- Produces: owned `ToolResult` and `!ToolResult` execution contract from §6.2.
- Preserves: `is_error` as the model-visible tool failure signal.

- [ ] **Step 1: Add ownership tests**

In `tools.zig`, add tests that construct success/failure results with `std.testing.allocator`, deinitialize them, and execute an unknown tool while confirming the returned content is owned.

- [ ] **Step 2: Introduce owned constructors**

Apply the §6.2 `ToolResult` definition. Add:

```zig
fn ownedResult(content: []u8, is_error: bool) ToolResult {
    return .{ .content = content, .is_error = is_error };
}
```

Use `success`/`failure` for literals and `ownedResult` for process/file/MCP results whose allocation already belongs to the caller.

- [ ] **Step 3: Propagate infrastructure errors**

Change `execute` and built-in handlers to return `!ToolResult`. Convert allocation failures from `"Out of memory"` strings into `try`.

Example:

```zig
const tool = std.meta.stringToEnum(ToolName, tool_name) orelse
    return ToolResult.failure(allocator, "Unknown tool");

return switch (tool) {
    .read_file => try readTool(allocator, exec, input),
    .write_file => try writeTool(allocator, exec, input),
    // remaining exhaustive cases
};
```

Input validation remains model-visible:

```zig
const path = getStringField(input, "file_path") orelse
    return ToolResult.failure(
        allocator,
        "Invalid input: expected { file_path: string }",
    );
```

- [ ] **Step 4: Transfer ownership in `agent_loop`**

Change the tool execution block:

```zig
var result = agent.tools.execute(alloc, tool_ctx, tu.name, tu.input) catch |err| {
    fireRequestError(Host, host, err);
    return .request_failed;
};
if (comptime @hasDecl(Host, "onToolResult")) {
    host.onToolResult(tu.name, tu.input, result);
}
results[i] = .{
    .tool_use_id = alloc.dupe(u8, tu.id) catch {
        result.deinit(alloc);
        return .request_failed;
    },
    .content = result.content,
    .is_error = result.is_error,
};
```

The assignment transfers `result.content` into history; do not call `deinit` after successful transfer.

- [ ] **Step 5: Update non-agent-loop consumers**

In shell mode and other direct consumers, either transfer `content` into an owned message or use:

```zig
var result = try agent.tools.runBashCommand(allocator, command);
errdefer result.deinit(allocator);
```

- [ ] **Step 6: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
rg -n '\\.content = "[^"]+"' src/tools.zig src/tools src/mcp src/sandbox.zig
```

Expected: unit tests and builds pass; direct string-literal construction of owned tool results is gone.

### Task 5 — Simplify mode and tool-status state

**Why:** Stateless mode structs and parallel activity fields add indirection and permit contradictory state.

**Files:**

- Modify: `src/mode.zig`
- Modify: `src/App.zig`
- Modify: `src/ui.zig`
- Modify: `src/layout.zig`
- Modify: `src/code_modal.zig`
- Modify: `src/input_handler.zig`
- Delete after migration: `src/modes/build.zig`, `src/modes/plan.zig`, `src/modes/shell.zig`

**Interfaces:**

- Produces: `Mode` enum with methods.
- Produces: `ToolActivity` tagged union.
- Produces: `ConfirmationController` with a tagged state.

- [ ] **Step 1: Port mode tests to `mode.zig`**

Move plan-policy tests and add build/shell label and toggle tests before deleting variant files.

- [ ] **Step 2: Replace the mode union**

Use:

```zig
pub const Mode = enum {
    build,
    plan,
    shell,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .build => " BUILD ",
            .plan => " PLAN ",
            .shell => " SHELL ",
        };
    }

    pub fn toggle(self: Mode) Mode {
        return switch (self) {
            .build => .plan,
            .plan, .shell => .build,
        };
    }
};
```

Move prompt composition and plan tool policy into exhaustive methods on this enum. Move shell command execution to a file-level `runShellCommand` function.

- [ ] **Step 3: Replace parallel status fields**

Replace `tool_status`, `grep_status`, `glob_status`, and `web_status` with:

```zig
tool_activity: ToolActivity = .idle,
```

Update `onToolActivity`, `onToolsComplete`, `onFinished`, layout calculation, and rendering to switch exhaustively on `tool_activity`.

- [ ] **Step 4: Replace confirmation booleans**

Create a controller containing `Condition` and `ConfirmationState`. Rendering receives `?*const PendingConfirmation` from:

```zig
pub fn pending(self: *const ConfirmationController) ?*const PendingConfirmation {
    return switch (self.state) {
        .waiting => |*value| value,
        else => null,
    };
}
```

Update call sites to use `pending()` rather than reading `pending` plus unrelated empty fields.

- [ ] **Step 5: Delete old mode files and verify**

Run:

```bash
zig fmt src
zig build test
zig build
rg -n 'grep_status|glob_status|web_status|tool_confirmation\\.pending' src
```

Expected: builds and tests pass; the search returns no obsolete parallel-state access.

### Task 6 — Introduce `Tui` as the terminal lifecycle owner

**Why:** `main()` currently bootstraps dependencies, owns UI widgets, handles events, and renders frames.

**Files:**

- Create: `src/Tui.zig`
- Create: `src/tui_state.zig`
- Modify: `src/main.zig`
- Modify: `src/input_handler.zig`
- Modify: `src/App.zig`
- Modify: `src/ui.zig`
- Modify: `src/layout.zig`
- Modify: `src/chat_selection.zig`
- Modify: picker and modal modules

**Interfaces:**

- Produces: `Tui.init(allocator, app)`, `Tui.deinit()`, and `Tui.run()`.
- Produces: `TuiState` owning input, overlay, pickers, selections, scroll, and clipboard status.
- Consumes: `App.Notifier`.

- [ ] **Step 1: Add state lifecycle tests**

Add tests for `TuiState.init/deinit`, overlay transitions, input-history cleanup, and picker cleanup using `std.testing.allocator`. These tests do not initialize a real terminal.

- [ ] **Step 2: Create `TuiState`**

Start with:

```zig
pub const TuiState = struct {
    input: std.ArrayList(u8) = .{},
    cursor_pos: usize = 0,
    history: std.ArrayList([]u8) = .{},
    history_idx: ?usize = null,
    draft: std.ArrayList(u8) = .{},
    ctrl_c_count: u32 = 0,
    scroll_offset: usize = 0,
    auto_scroll: bool = true,
    preview_scroll: usize = 0,
    overlay: Overlay = .none,
    selection: chat_selection.SelectionState = .{},
    input_selection: chat_selection.InputSelectionState = .{},

    pub fn deinit(self: *TuiState, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.draft.deinit(allocator);
        for (self.history.items) |entry| allocator.free(entry);
        self.history.deinit(allocator);
        self.overlay.deinit(allocator);
    }
};
```

`Overlay` is a tagged union owning exactly one active picker/modal:

```zig
pub const Overlay = union(enum) {
    none,
    command: command_picker.CommandPicker,
    model: model_picker.ModelPicker,
    provider: provider_picker.ProviderPicker,
    logout: logout_picker.LogoutPicker,
    mcp: mcp_picker.McpPicker,
    skills: skills_picker.SkillsPicker,
    trust: trust_dialog.TrustDialog,
    settings: settings_modal.SettingsModal,
};
```

Sessions and tool confirmation remain App-driven overlays but are represented by explicit `activeOverlay()` results, not independent booleans.

- [ ] **Step 3: Create `Tui.zig`**

Use a type-file with top-level fields so the TitleCase filename is idiomatic:

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("App.zig").App;
const state_mod = @import("tui_state.zig");

const Tui = @This();
const Event = vaxis.Event;
const EventLoop = vaxis.Loop(Event);

allocator: std.mem.Allocator,
app: *App,
state: state_mod.TuiState,

pub fn init(allocator: std.mem.Allocator, app: *App) !Tui;
pub fn deinit(self: *Tui) void;
pub fn run(self: *Tui) !void;
fn configureTerminal(
    self: *Tui,
    vx: *vaxis.Vaxis,
    loop: *EventLoop,
    tty: *vaxis.Tty,
) !void;
fn runEventLoop(
    self: *Tui,
    vx: *vaxis.Vaxis,
    loop: *EventLoop,
    tty: *vaxis.Tty,
) !void;
fn handleEvent(
    self: *Tui,
    loop: *EventLoop,
    vx: *vaxis.Vaxis,
    event: Event,
) !bool;
fn renderFrame(
    self: *Tui,
    loop: *EventLoop,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
) !void;
```

Keep terminal objects scoped inside `run` so `Tty` never retains a pointer to a buffer in a returned/moved `Tui` value:

```zig
pub fn run(self: *Tui) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(self.allocator, .{});
    defer vx.deinit(self.allocator, tty.writer());

    var loop: EventLoop = .{ .tty = &tty, .vaxis = &vx };
    try loop.start();
    defer loop.stop();

    try self.configureTerminal(&vx, &loop, &tty);
    try self.runEventLoop(&vx, &loop, &tty);
}
```

Preserve the current initialization/deinitialization LIFO order. Move the current `while (running)` body into `runEventLoop`, mouse handling into `handleMouse`, and lines from `app.mutex.lock()` through `vx.render` into `renderFrame`.

- [ ] **Step 4: Reduce `main()`**

After CLI/config/client/App initialization, replace terminal setup and the event loop with:

```zig
var tui = try Tui.init(alloc, &app);
defer tui.deinit();
try tui.run();
```

`main.zig` should no longer import individual picker, layout, selection, preview, or render modules.

- [ ] **Step 5: Replace `InputContext`**

Change input entrypoints to:

```zig
pub fn handleKey(
    allocator: std.mem.Allocator,
    app: *App,
    tui: *TuiState,
    loop: *EventLoop,
    key: vaxis.Key,
) !Action;

pub const Action = enum {
    none,
    redraw,
    quit,
};
```

Remove the module-global `countCtrlPlusC`; use `tui.ctrl_c_count`.

- [ ] **Step 6: Hide wake-loop details behind the notifier**

Configure `App.Notifier` inside `Tui.run`, after the local `EventLoop` exists, and clear it before that loop is destroyed. The callback posts the existing resize/wake event. `App` ignores notifications after the notifier is cleared. Remove `active_loop`, `Event`, `EventLoop`, and `wakeLoop` from `App.zig`; neither `App` nor the returned `Tui` value retains a pointer to the stack-local loop.

- [ ] **Step 7: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
zig build run
```

Manual smoke check: startup, trust dialog, every picker, settings, session resume, text input, paste, mouse selection, tool confirmation, streaming, cancellation, sandbox toggle, and clean exit.

### Task 7 — Split and type the tool system

**Why:** Tool registration, JSON schema, parsing, host/sandbox execution, and unrelated algorithms currently share one 1,100-line namespace.

**Files:**

- Modify: `src/tools.zig`
- Create: `src/tools/schema.zig`
- Create: `src/tools/filesystem.zig`
- Create: `src/tools/shell.zig`
- Create: `src/tools/skills.zig`
- Create: `src/tools/task_write.zig`
- Modify: `src/tools/web.zig`
- Move focused tests with their implementations

**Interfaces:**

- Preserves: `ToolName`, `Context`, `getDefinitions`, `execute`, `runBashCommand`, and `matchStartLine`.
- Produces: typed parameter structs and one-source required-field extraction.

- [ ] **Step 1: Lock behavior with dispatch tests**

Add table-driven tests covering every `ToolName` tag, its schema name, required fields, and dispatch registration. Add parse tests for missing/wrong fields for read, edit, grep, and task-write inputs.

- [ ] **Step 2: Add typed input structs**

In the owning implementation modules:

```zig
pub const ReadParams = struct {
    file_path: []const u8,
};

pub const EditParams = struct {
    file_path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
};

pub const GrepParams = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    include: ?[]const u8 = null,
};
```

Use one shared parser:

```zig
pub fn parseInput(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !T {
    return std.json.parseFromValueLeaky(T, allocator, value, .{
        .ignore_unknown_fields = false,
    });
}
```

Map parse failures to model-visible `ToolResult.failure`; propagate allocator failures.

- [ ] **Step 3: Remove duplicated required arrays**

Remove `ToolSpec.required`. In `schema.zig`, parse both `properties` and `required` from `schema_json`:

```zig
pub const Parsed = struct {
    properties: std.json.Value,
    required: []const []const u8,
};

pub fn parse(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
) !Parsed;
```

`getDefinitions` uses only this parsed representation, so the JSON schema is the single required-field source.

- [ ] **Step 4: Move cohesive implementations**

- `filesystem.zig`: backend union plus read/write/edit/glob/grep and path-search tests.
- `shell.zig`: host/sandbox process execution.
- `skills.zig`: skill load/resource/script resolution.
- `task_write.zig`: typed task list parsing and store update.
- `web.zig`: retain current Tavily adapter.
- `tools.zig`: specs, definition assembly, MCP-first routing, exhaustive dispatch.

Do not introduce a runtime handler registry. Keep the explicit `switch (ToolName)` so the compiler checks exhaustiveness.

- [ ] **Step 5: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
wc -l src/tools.zig
```

Expected: all tests pass and `tools.zig` contains registry/dispatch logic rather than filesystem/search implementations.

### Task 8 — Introduce an owned provider catalog

**Why:** Provider metadata, backend selection, and dynamic OpenRouter lifecycle are currently joined through strings and a mutable global.

**Files:**

- Create: `src/llm/catalog.zig`
- Modify: `src/llm/providers.zig`
- Modify: `src/llm/client.zig`
- Modify: `src/llm.zig`
- Modify: `src/main.zig`
- Modify: `src/App.zig`
- Modify: `src/model_picker.zig`
- Modify: `src/provider_picker.zig`
- Modify: `src/input_handler.zig`
- Modify: `src/cli/print.zig`

**Interfaces:**

- Produces: `ProviderId`, `Backend`, and `Catalog` from §6.4.
- Removes: `pub var openrouter_store`.
- Preserves: current provider names, models, endpoints, and config JSON.

- [ ] **Step 1: Write catalog tests**

Cover static lookup, dynamic lookup with a test-published store, duplicate model IDs, provider/backend mapping, and unknown IDs.

- [ ] **Step 2: Put backend metadata on providers**

Change static entries:

```zig
.{ .id = .anthropic, .name = "Anthropic", .backend = .anthropic, .models = ... },
.{ .id = .openai, .name = "OpenAI", .backend = .openai, .models = ... },
.{ .id = .deep_seek, .name = "DeepSeek", .backend = .anthropic, .models = ... },
.{ .id = .gemini, .name = "Gemini", .backend = .gemini, .models = ... },
```

Delete `client.backendFor`.

- [ ] **Step 3: Add the runtime-owned catalog**

Create `catalog.zig` with the §6.4 shape. Move public model lookup through `Catalog.findModel`.

- [ ] **Step 4: Inject the catalog**

`main()` owns:

```zig
var provider_catalog = agent.llm.Catalog{};
defer provider_catalog.deinit();
```

Pass `&provider_catalog` to `App`, model/provider pickers, and headless CLI. Change the OpenRouter fetch thread to call `provider_catalog.open_router.fetch(...)`.

- [ ] **Step 5: Dispatch using resolved backend**

Change `Client.Config`:

```zig
pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    provider_id: ?providers.ProviderId = null,
    backend: ?providers.Backend = null,
    effort: config_mod.Effort = .none,
};
```

Add `ProviderNotConfigured` to `RequestError`. This keeps startup/config loading representable before the user selects a valid provider. The streaming switch becomes:

```zig
const backend = self.config.backend orelse
    return error.ProviderNotConfigured;

return switch (backend) {
    .anthropic => anthropic.sendMessageStreaming(...),
    .openai => openai.sendMessageStreaming(...),
    .gemini => gemini.sendMessageStreaming(...),
};
```

- [ ] **Step 6: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
rg -n 'openrouter_store|backendFor\\(' src
```

Expected: tests/build pass and both legacy symbols are absent.

### Task 9 — Normalize names and focused namespaces

**Why:** A small final naming pass makes the new boundaries predictable without obscuring structural diffs.

**Files:**

- Create: `src/environment.zig`
- Create: `src/git_info.zig`
- Create: `src/text.zig`
- Modify callers of `agent.utils` / local `utils`
- Modify: `src/context_usage.zig`
- Modify: `src/main.zig` or `src/Tui.zig`
- Delete: `src/utils.zig`
- Modify: `src/root.zig`
- Modify: `src/root_tests.zig`

**Interfaces:**

- Produces: `environment.homeDir/getEnvBuf`, `git_info.currentBranch`, `text.truncate`.
- Produces: `ContextUsage` with snake_case fields.

- [ ] **Step 1: Move tests before implementations**

Move `utils.zig` tests to the matching focused modules. Add direct tests for UTF-8 truncation and home-prefix display behavior.

- [ ] **Step 2: Create focused namespaces**

Move environment functions unchanged into `environment.zig`.

Move Git branch reading into:

```zig
pub fn currentBranch(buf: []u8) ![]const u8;
```

Move UTF-8 truncation into:

```zig
pub fn truncate(
    value: []const u8,
    max_width: usize,
    reserve: usize,
) []const u8;
```

Keep `getCwdPretty` with TUI display code or rename it `environment.formatCwd` if it remains core.

- [ ] **Step 3: Update imports and delete `utils.zig`**

Replace each caller with the focused namespace. Export only `environment` from `root.zig`; `text` and `git_info` remain executable-local unless headless code needs them.

- [ ] **Step 4: Normalize remaining identifiers**

Change:

```zig
pub const ContextUsage = struct {
    tokens_count: u32 = 0,
    tokens_percentage: u32 = 0,
    buf: [32]u8 = undefined,
};
```

Rename local/enum identifiers such as `currentBranch`, `skillsLoad`, and `countCtrlPlusC` to Zig-conventional names. Do not rename camelCase functions.

- [ ] **Step 5: Verify**

Run:

```bash
zig fmt src
zig build test
zig build
rg -n 'utils|contextUsage|tokensCount|tokensPercentage|countCtrlPlusC|skillsLoad' src
```

Expected: no obsolete identifiers remain.

### Task 10 — Simplify build and document the architecture

**Why:** The final structure should be discoverable without reverse-engineering imports or generated template commentary.

**Files:**

- Modify: `build.zig`
- Create: `docs/architecture.md`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `TODO.md`

**Interfaces:**

- Produces documented commands: build, run, unit tests, format check, and release build.
- Produces architecture ownership and dependency rules for future changes.

- [ ] **Step 1: Simplify `build.zig`**

Remove generated tutorial comments and group the build into small helpers:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = addBuildOptions(b);
    const dependencies = addDependencies(b, target, optimize);
    const core = addCoreModule(b, target, optimize, options);
    const exe = addExecutable(b, target, optimize, core, dependencies);

    addRunStep(b, exe);
    addUnitTestStep(b, core, exe.root_module);
    b.installArtifact(exe);
}
```

Each helper stays in `build.zig`; do not create a build-script directory.

- [ ] **Step 2: Add `docs/architecture.md`**

Document:

- core/TUI/CLI dependency direction;
- allocator and slice ownership rules;
- conversation and tool-result ownership transfer;
- `App` versus `Tui` responsibilities;
- background notification and mutex rules;
- unit-test discovery and deterministic provider fixture tests;
- provider and tool extension steps.

- [ ] **Step 3: Add a README development section**

Include:

````markdown
## Development

```bash
zig fmt --check src build.zig build.zig.zon
zig build
zig build test
zig build run
```
````

- [ ] **Step 4: Reconcile repository guidance**

Update `AGENTS.md` code map and test behavior to match the implemented structure. Clean `TODO.md` to active product work only; retain completed planning history in existing plan/spec directories.

- [ ] **Step 5: Run the final gate**

Run:

```bash
zig fmt --check src build.zig build.zig.zon
zig build
zig build test --summary all
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast --prefix dist/linux
git diff --check
git status --short
```

Expected: all commands pass; only intended modernization files are changed; production behavior has not changed.

## 8. Testing strategy

### Unit tests

- Test roots prove every test-bearing module is discovered.
- Content-block tagged-union serialization, cloning, and deinitialization.
- Tool-result allocation ownership and failure constructors.
- Tool parameter parsing and schema required fields.
- Mode transitions, plan policy, tool activity, and confirmation transitions.
- `TuiState` lifecycle and overlay transitions without a terminal.
- Provider catalog static/dynamic lookup and backend selection.
- Environment, Git display, and UTF-8 text helpers.
- Existing config, JSON, MCP protocol, session, image, selection, task, and filesystem tests remain enabled.

All allocating tests use `std.testing.allocator`.

### Component and build gates

- Add embedded request, response, and streaming fixtures per provider for text, thinking, tool-use, and usage normalization.
- Provider transport tests use an injected in-process fake transport; they never open a listening socket or invoke an external process.
- Manual TUI smoke test after the `Tui` migration covers terminal lifecycle and real Vaxis behavior.
- Windows cross-build and Linux musl release build remain compile-level integration gates.

### Test discovery invariant

Every new module containing tests must be imported by `root_tests.zig` or `app_tests.zig`. CI must never return to zero executed tests.

## 9. Acceptance criteria

- `zig build test` executes the repository's unit tests rather than two empty binaries.
- CI rejects unformatted Zig files.
- The `agent` module compiles without Vaxis or theme imports.
- `src/root.zig` exposes only reusable core APIs.
- Persisted config and session formats remain readable without migration.
- `ContentBlock`, tool activity, and confirmation state use tagged variants with exhaustive switches.
- Every `ToolResult.content` allocation has one documented owner.
- `main()` performs bootstrap and delegates terminal behavior to `Tui.run()`.
- Input handling no longer receives a context containing pointers to every picker and UI flag.
- `tools.zig` is a registry/dispatcher, with implementations in focused sibling modules.
- Provider backend selection does not depend on provider-name string maps.
- Dynamic OpenRouter state is runtime-owned and testable without a module global.
- No catch-all `utils` namespace or non-idiomatic `contextUsage` identifiers remain.
- `docs/architecture.md`, README commands, AGENTS instructions, build graph, and implemented structure agree.
- Native build, unit tests, Windows cross-build, and Linux musl release build pass.

## 10. Risks and controlled deferrals

- The content-block migration touches every provider adapter. Control it with serialization fixtures and perform it before the TUI move so failures remain localized.
- Moving `main()` into `Tui` can disturb terminal cleanup order. Preserve the exact current LIFO order and perform the listed manual exit/resume checks.
- Persisted settings fields use camelCase for JSON compatibility. They are intentionally not renamed in this modernization.
- A fully event-driven UI thread would be a larger concurrency redesign. This plan introduces a notifier boundary but retains the existing mutex where necessary; replacing shared state with a channel is deferred until the notifier has proven stable.
- Provider wire structs remain provider-specific and may still contain optional fields. Only the provider-neutral model is made strictly typed.
- The `testOption` persisted setting is retained to avoid a config-format behavior change. Removing it belongs in a separately reviewed config migration.

# Skills Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in `/skills` command that opens a searchable modal for all loaded skills and lets the user toggle each skill's session-only `enabled` state.

**Architecture:** Keep skill enablement attached to each `agent.skills.Skill` record via a new `enabled: bool` field. Add a dedicated `SkillsPicker` modal controller, wire it into the existing picker/render/event flow in `main.zig` and `input_handler.zig`, and filter skill-backed slash-command entries by `skill.enabled` while leaving built-in slash commands unchanged.

**Tech Stack:** Zig 0.15.2, vaxis, existing modal picker helpers in `src/modal_list.zig`

## Global Constraints

- Enablement is session-only and must not be persisted to `~/.config/agent-zig/config.json`.
- Disabled skills must still appear in `/skills` so they can be re-enabled.
- Disabled skills must not appear in the normal slash command picker skill results.
- Direct execution attempts for disabled skills must be blocked with a short notice.
- Do not add tests for this change.
- Verify implementation with `zig build`.
- Do not commit unless the user explicitly asks for a commit.

---

## File Structure

- `src/skills.zig`: extend the in-memory `Skill` model with `enabled: bool = true`.
- `src/commands/command_picker.zig`: register `/skills` as a built-in command and exclude disabled skills from slash skill results.
- `src/skills_picker.zig`: new modal controller that owns query text, filtered results, selection, toggle behavior, and modal rendering.
- `src/input_handler.zig`: wire `/skills` command handling, modal key routing, toggle-on-enter, and disabled-skill execution guard.
- `src/main.zig`: instantiate/deinit the picker, pass it through `InputContext`, and render it as an overlay.

### Task 1: Extend skill state and register `/skills`

**Files:**
- Modify: `src/skills.zig`
- Modify: `src/commands/command_picker.zig`

**Interfaces:**
- Consumes: `agent.skills.Registry.skills.items`, `command_picker_mod.CommandAction`
- Produces: `agent.skills.Skill.enabled: bool`, `command_picker_mod.CommandAction.skills`

- [ ] **Step 1: Add the runtime enable flag to `Skill`**

Update `src/skills.zig` so each loaded skill carries session-only state:

```zig
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    license: ?[]const u8,
    metadata: ?[]const u8,
    dir_path: []const u8,
    enabled: bool = true,

    fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.license) |v| allocator.free(v);
        if (self.metadata) |v| allocator.free(v);
        allocator.free(self.dir_path);
    }
};
```

- [ ] **Step 2: Keep skill loading behavior unchanged except for the default**

Leave `Registry.loadOne()` appending skills exactly as today so the new field uses its default `true` value:

```zig
try self.skills.append(allocator, .{
    .name = parsed.name,
    .description = parsed.description,
    .license = parsed.license,
    .metadata = parsed.metadata,
    .dir_path = dir_path,
});
```

This task intentionally does not add config parsing or persistence.

- [ ] **Step 3: Register `/skills` as a built-in slash command**

Update `src/commands/command_picker.zig`:

```zig
pub const CommandAction = enum {
    provider,
    model,
    clear,
    compact,
    fork,
    resume_session,
    init,
    mcp,
    skills,
    rename,
    sandbox,
    export_session,
    exit,
};

pub const commands = [_]Command{
    .{ .name = "provider", .description = "Set provider API key", .action = .provider },
    .{ .name = "model", .description = "Choose active model", .action = .model },
    .{ .name = "clear", .description = "Clear conversation", .action = .clear },
    .{ .name = "compact", .description = "Compact conversation", .action = .compact },
    .{ .name = "fork", .description = "Fork session", .action = .fork },
    .{ .name = "resume", .description = "Resume conversation", .action = .resume_session },
    .{ .name = "init", .description = "Create or update AGENTS.md", .action = .init },
    .{ .name = "mcp", .description = "List active MCP servers", .action = .mcp },
    .{ .name = "skills", .description = "List skills and toggle enablement", .action = .skills },
    .{ .name = "rename", .description = "Rename current session", .action = .rename },
    .{ .name = "sandbox", .description = "Toggle Docker sandbox", .action = .sandbox },
    .{ .name = "export", .description = "Export conversation to HTML", .action = .export_session },
    .{ .name = "exit", .description = "Exit the application", .action = .exit },
};
```

- [ ] **Step 4: Verify the repo still compiles after the enum/model changes**

Run: `zig build`

Expected: build fails only if later `/skills` wiring is still missing; if so, continue immediately to Task 2 before re-running.

### Task 2: Add the `SkillsPicker` modal controller

**Files:**
- Create: `src/skills_picker.zig`

**Interfaces:**
- Consumes: `*agent.skills.Registry`, `modal_list.render`, `agent.skills.Skill.name`, `agent.skills.Skill.description`, `agent.skills.Skill.enabled`
- Produces:
  - `pub const SkillsPicker = struct { ... }`
  - `pub fn init() SkillsPicker`
  - `pub fn deinit(self: *SkillsPicker, alloc: std.mem.Allocator) void`
  - `pub fn open(self: *SkillsPicker, alloc: std.mem.Allocator, registry: *agent.skills.Registry) !void`
  - `pub fn refresh(self: *SkillsPicker, alloc: std.mem.Allocator) !void`
  - `pub fn moveUp(self: *SkillsPicker) void`
  - `pub fn moveDown(self: *SkillsPicker) void`
  - `pub fn toggleSelected(self: *SkillsPicker, alloc: std.mem.Allocator) !void`
  - `pub fn reset(self: *SkillsPicker) void`
  - `pub fn render(self: *SkillsPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void`

- [ ] **Step 1: Create the picker skeleton and state**

Start `src/skills_picker.zig` with the same shape used by `model_picker.zig` and `mcp_picker.zig`:

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = @import("modal_list.zig");

const enabled_fg: vaxis.Color = .{ .rgb = .{ 0x60, 0xCC, 0x60 } };
const disabled_fg: vaxis.Color = .{ .rgb = .{ 0xFF, 0x60, 0x60 } };

pub const SkillsPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    selected: usize = 0,
    results: std.ArrayList(*agent.skills.Skill) = .{},
    registry: ?*agent.skills.Registry = null,

    pub fn init() SkillsPicker {
        return .{};
    }

    pub fn deinit(self: *SkillsPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
    }
};
```

- [ ] **Step 2: Implement open/reset/refresh around mutable skill pointers**

Build filtered results from `registry.skills.items` so toggling can mutate the real `Skill` values:

```zig
pub fn open(self: *SkillsPicker, alloc: std.mem.Allocator, registry: *agent.skills.Registry) !void {
    self.active = true;
    self.registry = registry;
    self.query.clearRetainingCapacity();
    self.selected = 0;
    try self.refresh(alloc);
}

pub fn reset(self: *SkillsPicker) void {
    self.active = false;
    self.query.clearRetainingCapacity();
    self.selected = 0;
    self.results.clearRetainingCapacity();
    self.registry = null;
}

pub fn refresh(self: *SkillsPicker, alloc: std.mem.Allocator) !void {
    self.results.clearRetainingCapacity();
    self.selected = 0;

    const registry = self.registry orelse return;
    for (registry.skills.items) |*skill| {
        if (self.query.items.len == 0 or std.ascii.indexOfIgnoreCase(skill.name, self.query.items) != null) {
            try self.results.append(alloc, skill);
        }
    }
}
```

- [ ] **Step 3: Implement selection movement and toggle behavior**

Use bounded selection like the other pickers and flip the selected skill in place:

```zig
pub fn moveUp(self: *SkillsPicker) void {
    if (self.selected > 0) self.selected -= 1;
}

pub fn moveDown(self: *SkillsPicker) void {
    if (self.selected + 1 < self.results.items.len) self.selected += 1;
}

pub fn toggleSelected(self: *SkillsPicker, alloc: std.mem.Allocator) !void {
    if (self.selected >= self.results.items.len) return;
    self.results.items[self.selected].enabled = !self.results.items[self.selected].enabled;
    const selected_name = self.results.items[self.selected].name;
    try self.refresh(alloc);
    for (self.results.items, 0..) |skill, i| {
        if (std.mem.eql(u8, skill.name, selected_name)) {
            self.selected = i;
            break;
        }
    }
}
```

- [ ] **Step 4: Implement modal rendering with search and badges**

Render all skills, including disabled ones, through `modal_list.render`:

```zig
pub fn render(self: *SkillsPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
    const max_items = 64;
    var items_buf: [max_items]modal_list.Item = undefined;
    const n = @min(self.results.items.len, max_items);

    for (self.results.items[0..n], 0..) |skill, i| {
        items_buf[i] = .{
            .primary = skill.name,
            .secondary = skill.description,
            .badge = if (skill.enabled)
                .{ .text = "enabled", .fg = enabled_fg }
            else
                .{ .text = "disabled", .fg = disabled_fg },
        };
    }

    modal_list.render(win, screen_w, screen_h, .{
        .title = " Skills",
        .esc_hint = "enter toggle  esc",
        .query = self.query.items,
        .items = items_buf[0..n],
        .selected = self.selected,
        .empty_message = " (no skills loaded)",
        .max_width = 90,
        .max_height = 22,
    });
}
```

- [ ] **Step 5: Verify the new file is syntactically sound once wired in Task 3**

Run: `zig build`

Expected: build may still fail until `main.zig` and `input_handler.zig` import the new module; proceed directly to Task 3.

### Task 3: Wire `SkillsPicker` into app startup, overlay rendering, and input routing

**Files:**
- Modify: `src/main.zig`
- Modify: `src/input_handler.zig`

**Interfaces:**
- Consumes: `skills_picker_mod.SkillsPicker`, `runSlashCommand`, `handleEscape`, `handleArrow`, `handleTextInput`, `handleEnter`
- Produces:
  - `InputContext.skills_picker: *skills_picker_mod.SkillsPicker`
  - `/skills` action opens the picker
  - active picker captures text, arrows, `Enter`, and `Esc`

- [ ] **Step 1: Instantiate and render the picker in `main.zig`**

Add the import, local variable, `defer`, `InputContext` field, and overlay render block:

```zig
const skills_picker_mod = @import("skills_picker.zig");

var skills_picker = skills_picker_mod.SkillsPicker.init();
defer skills_picker.deinit(alloc);

var ctx = input_handler.InputContext{
    .alloc = alloc,
    .app = &app,
    .loop = &loop,
    .at_picker = &at_picker,
    .command_picker = &command_picker,
    .model_picker = &model_picker,
    .provider_picker = &provider_picker,
    .mcp_picker = &mcp_picker,
    .skills_picker = &skills_picker,
    .trust_dialog = &trust_dialog,
    // ...existing fields...
};

if (skills_picker.active) {
    skills_picker.render(win, vx.screen.width, vx.screen.height);
}
```

- [ ] **Step 2: Add the picker to `InputContext` and slash command dispatch**

Extend `src/input_handler.zig` imports and struct fields, then wire the new action:

```zig
const skills_picker_mod = @import("skills_picker.zig");

pub const InputContext = struct {
    alloc: std.mem.Allocator,
    app: *App,
    loop: *EventLoop,
    at_picker: *at_picker_mod.AtPicker,
    command_picker: *command_picker_mod.CommandPicker,
    model_picker: *model_picker_mod.ModelPicker,
    provider_picker: *provider_picker_mod.ProviderPicker,
    mcp_picker: *mcp_picker_mod.McpPicker,
    skills_picker: *skills_picker_mod.SkillsPicker,
    trust_dialog: *trust_dialog_mod.TrustDialog,
    // ...existing fields...
};

fn runSlashCommand(ctx: *InputContext, action: command_picker_mod.CommandAction) !SlashResult {
    clearInput(ctx);
    switch (action) {
        .provider => ctx.provider_picker.open(),
        .model => try ctx.model_picker.open(ctx.alloc),
        .clear => ctx.app.clearHistory(),
        .compact => { /* existing code */ },
        .fork => { /* existing code */ },
        .resume_session => ctx.app.sessions.open(),
        .init => { /* existing code */ },
        .mcp => try ctx.mcp_picker.open(ctx.alloc, &ctx.app.mcp_registry, ctx.app.mcp_config),
        .skills => try ctx.skills_picker.open(ctx.alloc, &ctx.app.skill_registry),
        .sandbox => { /* existing code */ },
        .export_session => { /* existing code */ },
        .exit => return .quit,
    }
    return .none;
}
```

- [ ] **Step 3: Route `Esc` and arrow keys to the picker before normal input history**

Update the active-modal checks so the skills picker behaves like the others:

```zig
const modal_open =
    ctx.app.tool_confirmation.pending or
    ctx.at_picker.active or
    ctx.command_picker.active or
    ctx.model_picker.active or
    ctx.provider_picker.active or
    ctx.mcp_picker.active or
    ctx.skills_picker.active or
    ctx.app.sessions.active or
    ctx.app.sessions.rename_active;

fn handleEscape(ctx: *InputContext) !void {
    if (ctx.app.tool_confirmation.pending) {
        try ctx.app.resolveToolConfirmation(ctx.alloc, .deny);
    } else if (ctx.app.cancelActiveRequest(ctx.loop)) {
        return;
    } else if (ctx.at_picker.active) {
        ctx.at_picker.reset(ctx.alloc);
    } else if (ctx.command_picker.active) {
        ctx.command_picker.reset(ctx.alloc);
    } else if (ctx.model_picker.active) {
        ctx.model_picker.reset();
    } else if (ctx.provider_picker.active) {
        ctx.provider_picker.reset();
    } else if (ctx.mcp_picker.active) {
        if (!ctx.mcp_picker.backOrClose()) ctx.mcp_picker.reset();
    } else if (ctx.skills_picker.active) {
        ctx.skills_picker.reset();
    } else if (ctx.app.sessions.rename_active) {
        ctx.app.sessions.resetRename();
    } else if (ctx.app.sessions.active) {
        ctx.app.sessions.reset();
    } else switch (ctx.app.mode) {
        .shell => {
            ctx.app.mode = .{ .build = .{} };
            ctx.app.needs_redraw = true;
        },
        else => {},
    }
}
```

Then add arrow routing:

```zig
} else if (ctx.mcp_picker.active) {
    ctx.mcp_picker.moveUp();
} else if (ctx.skills_picker.active) {
    ctx.skills_picker.moveUp();
}

} else if (ctx.mcp_picker.active) {
    ctx.mcp_picker.moveDown();
} else if (ctx.skills_picker.active) {
    ctx.skills_picker.moveDown();
}
```

- [ ] **Step 4: Route text input and Enter to query/toggle behavior**

Make the picker searchable and toggle with `Enter` instead of sending chat:

```zig
fn handleTextInput(ctx: *InputContext, txt: []const u8) !void {
    resetExitState(ctx);
    const alloc = ctx.alloc;
    if (ctx.app.sessions.rename_active) {
        try ctx.app.sessions.rename_input.appendSlice(alloc, txt);
    } else if (ctx.provider_picker.active and ctx.provider_picker.phase == .key_input) {
        try ctx.provider_picker.key_input.appendSlice(alloc, txt);
    } else if (ctx.model_picker.active) {
        try ctx.model_picker.query.appendSlice(alloc, txt);
        try ctx.model_picker.refresh(alloc);
    } else if (ctx.skills_picker.active) {
        try ctx.skills_picker.query.appendSlice(alloc, txt);
        try ctx.skills_picker.refresh(alloc);
    } else if (txt.len > 0) {
        // existing input behavior
    }
}
```

Add matching backspace behavior:

```zig
} else if (ctx.model_picker.active) {
    if (ctx.model_picker.query.items.len > 0) {
        _ = ctx.model_picker.query.orderedRemove(ctx.model_picker.query.items.len - 1);
        try ctx.model_picker.refresh(alloc);
    }
} else if (ctx.skills_picker.active) {
    if (ctx.skills_picker.query.items.len > 0) {
        _ = ctx.skills_picker.query.orderedRemove(ctx.skills_picker.query.items.len - 1);
        try ctx.skills_picker.refresh(alloc);
    }
}
```

Handle `Enter` before the MCP/provider/session branches:

```zig
} else if (ctx.skills_picker.active) {
    try ctx.skills_picker.toggleSelected(alloc);
    try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
}
```

- [ ] **Step 5: Verify `/skills` opens, filters, and toggles without crashing**

Run: `zig build`

Expected: PASS

### Task 4: Hide disabled skills from slash results and block direct execution

**Files:**
- Modify: `src/commands/command_picker.zig`
- Modify: `src/input_handler.zig`

**Interfaces:**
- Consumes: `agent.skills.Skill.enabled`, `ctx.app.skill_registry.find`, `ctx.app.appendNotice`, `ctx.app.skillCMD`
- Produces:
  - command picker only appends enabled skill entries
  - direct execution path guards disabled skills

- [ ] **Step 1: Filter disabled skills out of command picker refresh results**

Update the skill-appending loop in `src/commands/command_picker.zig`:

```zig
if (self.skill_registry) |registry| {
    const prefix_matches = self.query.items.len > 0 and
        std.ascii.indexOfIgnoreCase(SKILL_PREFIX, self.query.items) != null;
    for (registry.skills.items) |skill| {
        if (!skill.enabled) continue;
        if (prefix_matches or matchesQuery(skill.name, self.query.items)) {
            const skillName = try std.fmt.allocPrint(alloc, "{s}{s}", .{ SKILL_PREFIX, skill.name });
            try self.results.append(alloc, .{
                .name = skillName,
                .description = skill.description,
                .action = null,
            });
        }
    }
}
```

- [ ] **Step 2: Guard direct skill execution in `handleEnter`**

Replace the nullable `find()` check with explicit enabled-state handling:

```zig
if (ctx.app.skill_registry.find(bare_name)) |skill| {
    if (ctx.app.loading.active) {
        // leave existing no-send behavior unchanged
    } else if (!skill.enabled) {
        clearInput(ctx);
        ctx.app.appendNotice(try std.fmt.allocPrint(ctx.alloc, "Skill \"{s}\" is disabled", .{bare_name}));
    } else {
        clearInput(ctx);
        try ctx.app.skillCMD(bare_name);
        result = .send;
    }
}
```

Implement the string allocation safely by freeing it after `appendNotice()` if `appendNotice()` does not take ownership; if it does take ownership internally, keep the allocation pattern consistent with existing callers.

- [ ] **Step 3: Refresh slash suggestions after a toggle affects visibility**

Keep slash results consistent after a skill is toggled while the input still contains a slash command:

```zig
} else if (ctx.skills_picker.active) {
    try ctx.skills_picker.toggleSelected(alloc);
    try ctx.command_picker.updateFromInput(alloc, ctx.input.items);
}
```

This step matters because disabling a skill should immediately remove it from the slash picker the next time it is opened or refreshed.

- [ ] **Step 4: Final verification**

Run: `zig build`

Expected: PASS

- [ ] **Step 5: Manual smoke-check in the TUI**

Run: `zig build run`

Check these exact behaviors:

- `/skills` appears in the built-in slash command list.
- Opening `/skills` shows every loaded skill with an `enabled` or `disabled` badge.
- Typing in the modal filters by skill name.
- Pressing `Enter` toggles the selected skill.
- A disabled skill disappears from slash command skill suggestions.
- Re-enabling the same skill from `/skills` makes it appear in slash skill suggestions again.

Expected: all interactions work without a crash; stop the TUI manually when done.

## Self-Review

- Spec coverage: every approved requirement maps to a task above: `/skills` command registration (Task 1), searchable modal and toggling (Tasks 2 and 3), session-only state on `Skill` (Task 1), hide disabled skills from slash results (Task 4), and block disabled execution (Task 4).
- Placeholder scan: no `TODO`, `TBD`, or implicit "handle it later" steps remain.
- Type consistency: the plan uses one new picker type, `SkillsPicker`, with one mutable result type, `*agent.skills.Skill`, and one new enum member, `CommandAction.skills`, consistently across all tasks.

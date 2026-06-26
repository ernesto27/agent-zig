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
    items: std.ArrayList(modal_list.Item) = .{},
    registry: ?*agent.skills.Registry = null,

    pub fn init() SkillsPicker {
        return .{};
    }

    pub fn deinit(self: *SkillsPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
        self.items.deinit(alloc);
    }

    pub fn open(self: *SkillsPicker, alloc: std.mem.Allocator, registry: *agent.skills.Registry) !void {
        self.registry = registry;
        self.active = true;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        try self.refresh(alloc);
    }

    pub fn refresh(self: *SkillsPicker, alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.selected = 0;

        const registry = self.registry orelse return;
        for (registry.skills.items) |*skill| {
            if (self.query.items.len == 0 or std.ascii.indexOfIgnoreCase(skill.name, self.query.items) != null) {
                try self.results.append(alloc, skill);
                try self.items.append(alloc, .{
                    .primary = skill.name,
                    .secondary = null,
                    .badge = .{
                        .text = if (skill.enabled) "enabled " else "disabled ",
                        .fg = if (skill.enabled) enabled_fg else disabled_fg,
                    },
                });
            }
        }
    }

    pub fn moveUp(self: *SkillsPicker) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *SkillsPicker) void {
        if (self.results.items.len == 0) return;
        if (self.selected + 1 < self.results.items.len) self.selected += 1;
    }

    pub fn toggleSelected(self: *SkillsPicker, alloc: std.mem.Allocator) !void {
        if (self.selected >= self.results.items.len) return;

        const selected_skill = self.results.items[self.selected];
        const selected_name = selected_skill.name;
        selected_skill.enabled = !selected_skill.enabled;

        try self.refresh(alloc);
        for (self.results.items, 0..) |skill, i| {
            if (std.mem.eql(u8, skill.name, selected_name)) {
                self.selected = i;
                break;
            }
        }
    }

    pub fn reset(self: *SkillsPicker) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.results.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.registry = null;
    }

    pub fn render(self: *SkillsPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        modal_list.render(win, screen_w, screen_h, .{
            .title = " Skills",
            .esc_hint = "space toggle  esc",
            .query = self.query.items,
            .items = self.items.items,
            .selected = self.selected,
            .empty_message = " (no skills)",
            .max_width = 50,
            .max_height = 20,
        });
    }
};

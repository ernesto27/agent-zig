const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = @import("modal_list.zig");

const p = agent.llm.providers;

const free_badge_fg: vaxis.Color = .{ .rgb = .{ 0x60, 0xCC, 0x60 } };

// Re-export data types so existing callers don't need to change imports
pub const Model = p.Model;
pub const Provider = p.Provider;
pub const providers = p.providers;
pub const findModel = p.findModel;

pub const ModelPicker = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .{},
    selected: usize = 0,
    results: std.ArrayList(*const Model) = .{},

    pub fn init() ModelPicker {
        return .{};
    }

    pub fn deinit(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
    }

    pub fn refresh(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (&p.providers) |*prov| {
            for (prov.models) |*m| {
                if (self.query.items.len == 0) {
                    try self.results.append(alloc, m);
                } else {
                    const q = self.query.items;
                    if (std.ascii.indexOfIgnoreCase(m.display, q) != null or
                        std.ascii.indexOfIgnoreCase(m.id, q) != null)
                    {
                        try self.results.append(alloc, m);
                    }
                }
            }
        }
    }

    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.active = true;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        try self.refresh(alloc);
    }

    pub fn reset(self: *ModelPicker) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.results.clearRetainingCapacity();
    }

    pub fn render(self: *const ModelPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const max_items = 64;
        var items_buf: [max_items]modal_list.Item = undefined;
        const n = @min(self.results.items.len, max_items);
        for (self.results.items[0..n], 0..) |m, i| {
            items_buf[i] = .{
                .primary = m.display,
                .badge = if (m.free) modal_list.Badge{ .text = "Free", .fg = free_badge_fg } else null,
            };
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " Select model",
            .query = self.query.items,
            .items = items_buf[0..n],
            .selected = self.selected,
            .max_width = 60,
            .max_height = 20,
        });
    }
};

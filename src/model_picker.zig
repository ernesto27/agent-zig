const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = agent.modal_list;

const p = agent.llm.providers;

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
    labels: std.ArrayList([]const u8) = .{},
    providers_cfg: ?*const agent.config.Providers = null,

    pub fn init() ModelPicker {
        return .{};
    }

    pub fn deinit(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.clearLabels(alloc);
        self.labels.deinit(alloc);
        self.results.deinit(alloc);
    }

    fn clearLabels(self: *ModelPicker, alloc: std.mem.Allocator) void {
        for (self.labels.items) |l| alloc.free(l);
        self.labels.clearRetainingCapacity();
    }

    fn buildLabel(alloc: std.mem.Allocator, provider_name: []const u8, id: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(alloc);
        try buf.appendSlice(alloc, id);
        try buf.appendSlice(alloc, " [");
        for (provider_name) |c| try buf.append(alloc, std.ascii.toLower(c));
        try buf.append(alloc, ']');
        return buf.toOwnedSlice(alloc);
    }

    pub fn refresh(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.clearLabels(alloc);
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (&p.providers) |*prov| {
            if (self.providers_cfg) |cfg| {
                if (!cfg.isConfigured(prov.name)) continue;
            }
            for (prov.models) |*m| {
                const q = self.query.items;
                const matches = q.len == 0 or
                    std.ascii.indexOfIgnoreCase(m.display, q) != null or
                    std.ascii.indexOfIgnoreCase(m.id, q) != null or
                    std.ascii.indexOfIgnoreCase(prov.name, q) != null;
                if (!matches) continue;
                try self.results.append(alloc, m);
                try self.labels.append(alloc, try buildLabel(alloc, prov.name, m.id));
            }
        }

        const or_prov = p.openrouter_store.provider();
        const or_configured = if (self.providers_cfg) |cfg| cfg.isConfigured(or_prov.name) else true;
        if (!or_configured) return;
        for (p.openrouter_store.models()) |*m| {
            const q = self.query.items;
            const matches = q.len == 0 or
                std.ascii.indexOfIgnoreCase(m.display, q) != null or
                std.ascii.indexOfIgnoreCase(m.id, q) != null or
                std.ascii.indexOfIgnoreCase(or_prov.name, q) != null;
            if (!matches) continue;
            try self.results.append(alloc, m);
            try self.labels.append(alloc, try buildLabel(alloc, or_prov.name, m.id));
        }
    }

    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator, providers_cfg: *const agent.config.Providers) !void {
        self.active = true;
        self.providers_cfg = providers_cfg;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        try self.refresh(alloc);
    }

    pub fn reset(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.clearLabels(alloc);
        self.results.clearRetainingCapacity();
        self.providers_cfg = null;
    }

    pub fn render(self: *const ModelPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        const max_items = 64;
        var items_buf: [max_items]modal_list.Item = undefined;

        // The list can hold hundreds of entries (dynamic OpenRouter models), but
        // `items_buf` caps at `max_items`. Pass a window that always contains
        // `self.selected`, with a selected index relative to that window;
        // modal_list scrolls within whatever slice it's given.
        const total = self.results.items.len;
        var start: usize = 0;
        if (self.selected >= max_items) start = self.selected - max_items + 1;
        const end = @min(total, start + max_items);
        const n = end - start;
        for (self.results.items[start..end], 0..) |_, i| {
            items_buf[i] = .{
                .primary = self.labels.items[start + i],
            };
        }

        modal_list.render(win, screen_w, screen_h, .{
            .title = " Select model",
            .query = self.query.items,
            .items = items_buf[0..n],
            .selected = self.selected - start,
            .max_width = 60,
            .max_height = 20,
        });
    }
};

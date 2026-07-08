const std = @import("std");
const vaxis = @import("vaxis");
const agent = @import("agent");
const modal_list = agent.modal_list;
const p = agent.llm.providers;
const palette = @import("theme");

pub const Phase = enum { list, key_input };

pub const ProviderPicker = struct {
    active: bool = false,
    selected: usize = 0,
    phase: Phase = .list,
    key_input: std.ArrayList(u8) = .{},
    query: std.ArrayList(u8) = .{},
    results: std.ArrayList(*const p.Provider) = .{},

    pub fn init() ProviderPicker {
        return .{};
    }

    pub fn deinit(self: *ProviderPicker, alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
        self.results.deinit(alloc);
        self.key_input.deinit(alloc);
    }

    pub fn refresh(self: *ProviderPicker, alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        self.selected = 0;

        for (&p.providers) |*prov| {
            const q = self.query.items;
            const matches = q.len == 0 or
                std.ascii.indexOfIgnoreCase(prov.name, q) != null;
            if (!matches) continue;
            try self.results.append(alloc, prov);
        }

        const or_prov = p.openrouter_store.provider();
        const q = self.query.items;
        if (q.len == 0 or std.ascii.indexOfIgnoreCase(or_prov.name, q) != null) {
            try self.results.append(alloc, or_prov);
        }
    }

    pub fn open(self: *ProviderPicker, alloc: std.mem.Allocator) !void {
        self.active = true;
        self.selected = 0;
        self.phase = .list;
        self.query.clearRetainingCapacity();
        try self.refresh(alloc);
    }

    pub fn selectedProvider(self: *const ProviderPicker) *const p.Provider {
        return self.results.items[self.selected];
    }

    pub fn reset(self: *ProviderPicker) void {
        self.active = false;
        self.selected = 0;
        self.phase = .list;
        self.query.clearRetainingCapacity();
        self.results.clearRetainingCapacity();
        self.key_input.clearRetainingCapacity();
    }

    pub fn moveUp(self: *ProviderPicker) void {
        if (self.phase == .list and self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *ProviderPicker) void {
        if (self.phase == .list and self.selected + 1 < self.results.items.len) self.selected += 1;
    }

    pub fn render(self: *const ProviderPicker, win: vaxis.Window, screen_w: u16, screen_h: u16) void {
        switch (self.phase) {
            .list => {
                const max_items = 64;
                var items_buf: [max_items]modal_list.Item = undefined;
                const n = @min(self.results.items.len, max_items);
                for (self.results.items[0..n], 0..) |prov, i| {
                    items_buf[i] = .{ .primary = prov.name };
                }

                modal_list.render(win, screen_w, screen_h, .{
                    .title = " Select provider",
                    .query = self.query.items,
                    .items = items_buf[0..n],
                    .selected = self.selected,
                    .max_width = 60,
                    .max_height = 20,
                });
            },
            .key_input => {
                const modal_w: u16 = @min(50, screen_w -| 4);
                const modal_h: u16 = 7;
                const modal_x: u16 = (screen_w -| modal_w) / 2;
                const modal_y: u16 = (screen_h -| modal_h) / 2;

                const modal = win.child(.{
                    .x_off = modal_x,
                    .y_off = modal_y,
                    .width = modal_w,
                    .height = modal_h,
                    .border = .{ .where = .all, .glyphs = .single_rounded },
                });

                var fr: u16 = 0;
                while (fr < modal_h) : (fr += 1) {
                    var fc: u16 = 0;
                    while (fc < modal_w) : (fc += 1) {
                        modal.writeCell(fc, fr, .{ .char = .{ .grapheme = " ", .width = 1 } });
                    }
                }

                const provider = self.selectedProvider();
                _ = modal.printSegment(.{
                    .text = " API key for ",
                    .style = .{ .fg = palette.white, .bold = true },
                }, .{ .row_offset = 0, .col_offset = 1 });
                _ = modal.printSegment(.{
                    .text = provider.name,
                    .style = .{ .fg = palette.amber_dark, .bold = true },
                }, .{ .row_offset = 0, .col_offset = 15 });

                const key_text = if (self.key_input.items.len > 0)
                    self.key_input.items
                else
                    "Enter API key...";
                const key_style: vaxis.Style = if (self.key_input.items.len > 0)
                    .{ .fg = palette.white }
                else
                    .{ .fg = palette.faint };

                _ = modal.printSegment(.{
                    .text = key_text,
                    .style = key_style,
                }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

                _ = modal.printSegment(.{
                    .text = "Enter to save   esc to cancel",
                    .style = .{ .fg = palette.faint },
                }, .{ .row_offset = 4, .col_offset = 2 });
            },
        }
    }
};

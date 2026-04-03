const std = @import("std");

pub const Model = struct {
    id: []const u8,
    display: []const u8,
    provider: []const u8,
    free: bool = false,
};

pub const models = [_]Model{
    .{ .id = "claude-opus-4-6", .display = "Claude Opus 4.6", .provider = "Anthropic" },
    .{ .id = "claude-sonnet-4-6", .display = "Claude Sonnet 4.6", .provider = "Anthropic" },
    .{ .id = "claude-haiku-4-5-20251001", .display = "Claude Haiku 4.5", .provider = "Anthropic" },
};

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

        for (&models) |*m| {
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

    pub fn open(self: *ModelPicker, alloc: std.mem.Allocator) !void {
        self.active = true;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        try self.refresh(alloc);
    }

    pub fn reset(self: *ModelPicker, alloc: std.mem.Allocator) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.results.clearRetainingCapacity();
        _ = alloc;
    }
};

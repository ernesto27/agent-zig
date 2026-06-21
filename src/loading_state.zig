const std = @import("std");

pub const LoadingState = struct {
    active: bool = false,
    start_time: ?i64 = null,
    accumulated: usize = 0,
    paused: bool = false,

    /// Begin loading; resets accumulated time.
    pub fn start(self: *LoadingState) void {
        self.active = true;
        self.paused = false;
        self.accumulated = 0;
        self.start_time = std.time.timestamp();
    }

    /// End loading; zeros everything.
    pub fn stop(self: *LoadingState) void {
        self.active = false;
        self.paused = false;
        self.accumulated = 0;
        self.start_time = null;
    }

    /// Freeze the timer; accumulated time is preserved.
    pub fn pause(self: *LoadingState) void {
        if (!self.active or self.paused) return;
        if (self.start_time) |st| {
            const now = std.time.timestamp();
            self.accumulated += @as(usize, @intCast(@max(0, now - st)));
        }
        self.paused = true;
        self.start_time = null;
    }

    /// Resume from pause; start_time is reset to now.
    pub fn unpause(self: *LoadingState) void {
        if (!self.active or !self.paused) return;
        self.paused = false;
        self.start_time = std.time.timestamp();
    }

    /// Total elapsed seconds (accumulated + current phase), or null if not active.
    pub fn elapsed(self: *const LoadingState) ?usize {
        if (!self.active) return null;
        const current: usize = if (self.start_time) |st|
            @as(usize, @intCast(@max(0, std.time.timestamp() - st)))
        else
            0;
        return self.accumulated + current;
    }

    /// Whether the spinner should animate (active and not paused).
    pub fn isActive(self: *const LoadingState) bool {
        return self.active and !self.paused;
    }
};

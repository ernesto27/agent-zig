const std = @import("std");
const vaxis = @import("vaxis");

pub const contextUsage = struct {
    tokensCount: u32 = 0,
    tokensPercentage: u32 = 0,
    buf: [32]u8 = undefined,

    pub fn render(self: *contextUsage, win: vaxis.Window, col_offset: u16, row: u16, bg: vaxis.Color) void {
        const whole = self.tokensCount / 1000;
        const decimal = (self.tokensCount % 1000) / 100;
        const text = std.fmt.bufPrint(&self.buf, "  {d}.{d}K ({d}%)", .{ whole, decimal, self.tokensPercentage }) catch return;
        _ = win.printSegment(
            .{ .text = text, .style = .{ .bg = bg, .fg = .{ .rgb = .{ 0x88, 0x88, 0x88 } } } },
            .{ .row_offset = row, .col_offset = col_offset },
        );
    }
};

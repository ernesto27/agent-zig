const std = @import("std");

pub const Init = struct {
    pub fn getInitPrompt() []const u8 {
        return @embedFile("init_prompt.txt");
    }
};

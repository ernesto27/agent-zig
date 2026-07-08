//! Central color palette for the TUI.
//!
//! All hardcoded hex colors live here so shades stay consistent across the app.
//! Import it wherever colors are needed:
//!
//!     const palette = @import("theme");
//!     ... .style = .{ .fg = palette.dim } ...
//!
//! Markdown syntax colors live under the `md` namespace (`palette.md.h1`).

const vaxis = @import("vaxis");
const Color = vaxis.Color;

// Neutrals, light -> dark.
pub const white: Color = .{ .rgb = .{ 0xFF, 0xFF, 0xFF } };
pub const bright: Color = .{ .rgb = .{ 0xDD, 0xDD, 0xDD } };
pub const light: Color = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } };
pub const muted: Color = .{ .rgb = .{ 0xAA, 0xAA, 0xAA } };
pub const dim: Color = .{ .rgb = .{ 0x88, 0x88, 0x88 } };
pub const subtle: Color = .{ .rgb = .{ 0x77, 0x77, 0x77 } };
pub const faint: Color = .{ .rgb = .{ 0x66, 0x66, 0x66 } };
pub const dark: Color = .{ .rgb = .{ 0x55, 0x55, 0x55 } };
pub const black: Color = .{ .rgb = .{ 0x00, 0x00, 0x00 } };

// Accents and status.
pub const accent: Color = .{ .rgb = .{ 0xFF, 0xD0, 0x40 } };
pub const amber: Color = .{ .rgb = .{ 0xFF, 0xC0, 0x40 } };
pub const amber_dark: Color = .{ .rgb = .{ 0xC0, 0x70, 0x20 } };
pub const yellow: Color = .{ .rgb = .{ 0xFF, 0xFF, 0x88 } };
pub const green: Color = .{ .rgb = .{ 0x60, 0xCC, 0x60 } };
pub const green_bright: Color = .{ .rgb = .{ 0x60, 0xFF, 0x60 } };
pub const green_light: Color = .{ .rgb = .{ 0xCC, 0xFF, 0xCC } };
pub const red: Color = .{ .rgb = .{ 0xFF, 0x60, 0x60 } };

// Blues and teals.
pub const blue: Color = .{ .rgb = .{ 0xA0, 0xD0, 0xFF } };
pub const cyan: Color = .{ .rgb = .{ 0x9C, 0xE3, 0xEE } };
pub const teal: Color = .{ .rgb = .{ 0x5A, 0x9E, 0xA8 } };
pub const spinner: Color = .{ .rgb = .{ 0x5F, 0x6C, 0x8C } };
pub const select_bg: Color = .{ .rgb = .{ 0x30, 0x60, 0xA0 } };

// Backgrounds.
pub const bg_dark: Color = .{ .rgb = .{ 0x1A, 0x1A, 0x1A } };

/// Markdown syntax highlighting theme.
pub const md = struct {
    pub const h1: Color = .{ .rgb = .{ 0x60, 0xD0, 0xD0 } };
    pub const h2: Color = .{ .rgb = .{ 0x40, 0xA0, 0xC0 } };
    pub const h3: Color = .{ .rgb = .{ 0x80, 0x80, 0xC0 } };
    pub const code_fg: Color = .{ .rgb = .{ 0x70, 0xB0, 0xF0 } };
    pub const code_block_bg: Color = .{ .rgb = .{ 0x3A, 0x3A, 0x3A } };
    pub const code_block_fg: Color = .{ .rgb = .{ 0xD0, 0xD0, 0xD0 } };
    pub const code_bg: Color = .{ .rgb = .{ 0x1A, 0x1A, 0x2E } };
    pub const quote: Color = .{ .rgb = .{ 0x70, 0x70, 0x90 } };
};

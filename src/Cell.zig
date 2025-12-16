const std = @import("std");

/// Single terminal cell
pub const Cell = @This();

/// Maximum number of combining marks that can be attached to a cell.
/// Covers common cases like é (e + acute), ö (o + umlaut), etc.
pub const MAX_COMBINING: usize = 2;

/// Unicode codepoint (or first codepoint of grapheme).
/// 0 indicates a continuation cell (second half of wide character).
char: u21,
/// Combining marks attached to this cell (e.g., accents, diacritics).
/// Zero values indicate unused slots.
combining: [MAX_COMBINING]u21 = .{ 0, 0 },
/// Foreground color
fg: Color,
/// Background color
bg: Color,
/// Text attributes
attrs: Attributes,

/// Terminal color representation
pub const Color = union(enum) {
    /// Terminal default color
    default,
    /// 256-color palette index (0-255)
    index: u8,
    /// True color (24-bit RGB)
    rgb: struct { r: u8, g: u8, b: u8 },

    /// Named colors (map to indices 0-15)
    pub const black: Color = .{ .index = 0 };
    pub const red: Color = .{ .index = 1 };
    pub const green: Color = .{ .index = 2 };
    pub const yellow: Color = .{ .index = 3 };
    pub const blue: Color = .{ .index = 4 };
    pub const magenta: Color = .{ .index = 5 };
    pub const cyan: Color = .{ .index = 6 };
    pub const white: Color = .{ .index = 7 };

    /// Bright variants (indices 8-15)
    pub const bright_black: Color = .{ .index = 8 };
    pub const bright_red: Color = .{ .index = 9 };
    pub const bright_green: Color = .{ .index = 10 };
    pub const bright_yellow: Color = .{ .index = 11 };
    pub const bright_blue: Color = .{ .index = 12 };
    pub const bright_magenta: Color = .{ .index = 13 };
    pub const bright_cyan: Color = .{ .index = 14 };
    pub const bright_white: Color = .{ .index = 15 };

    /// Create an RGB color
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create a grayscale color from a gray value (0-255)
    /// Maps to the 24-step grayscale ramp in the 256-color palette (indices 232-255)
    /// or to black/white for extreme values.
    pub fn fromGray(gray: u8) Color {
        // Map to 256-color grayscale ramp (indices 232-255)
        // These represent 24 shades from dark (232) to light (255)
        // The formula maps 0-255 -> 232-255
        if (gray < 8) return .{ .index = 16 }; // Near black in cube
        if (gray >= 248) return .{ .index = 231 }; // Near white in cube (>= to avoid overflow)
        // Map to grayscale ramp: (gray - 8) / 10 gives 0-23, add 232
        // Safe: gray is in range [8, 247], so ramp_idx is in [0, 23]
        const ramp_idx: u8 = @intCast(((@as(u16, gray) - 8) * 24) / 240);
        return .{ .index = 232 + ramp_idx };
    }

    /// Create a color from HSL values (hue: 0-360, saturation: 0-100, lightness: 0-100)
    pub fn fromHsl(h: u16, s: u8, l: u8) Color {
        // Clamp inputs
        const hue: f32 = @as(f32, @floatFromInt(@min(h, 360)));
        const sat: f32 = @as(f32, @floatFromInt(@min(s, 100))) / 100.0;
        const light: f32 = @as(f32, @floatFromInt(@min(l, 100))) / 100.0;

        if (sat == 0) {
            // Achromatic (gray)
            const gray: u8 = @intFromFloat(light * 255.0);
            return fromRgb(gray, gray, gray);
        }

        const q = if (light < 0.5) light * (1.0 + sat) else light + sat - light * sat;
        const p = 2.0 * light - q;

        const r = hueToRgb(p, q, hue + 120.0);
        const g = hueToRgb(p, q, hue);
        const b = hueToRgb(p, q, hue - 120.0);

        return fromRgb(
            @intFromFloat(r * 255.0),
            @intFromFloat(g * 255.0),
            @intFromFloat(b * 255.0),
        );
    }

    fn hueToRgb(p: f32, q: f32, h_in: f32) f32 {
        var h = h_in;
        if (h < 0) h += 360.0;
        if (h > 360) h -= 360.0;

        if (h < 60) return p + (q - p) * h / 60.0;
        if (h < 180) return q;
        if (h < 240) return p + (q - p) * (240.0 - h) / 60.0;
        return p;
    }

    /// Check if two colors are equal
    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .default => other == .default,
            .index => |i| switch (other) {
                .index => |j| i == j,
                else => false,
            },
            .rgb => |c1| switch (other) {
                .rgb => |c2| c1.r == c2.r and c1.g == c2.g and c1.b == c2.b,
                else => false,
            },
        };
    }

    /// RGB color components
    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    /// Convert any color to an RGB approximation.
    /// For default, returns a neutral gray. For indexed colors, maps to standard palette.
    pub fn toRgb(self: Color) Rgb {
        return switch (self) {
            .default => .{ .r = 192, .g = 192, .b = 192 }, // Light gray as default approximation
            .index => |idx| indexToRgb(idx),
            .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b },
        };
    }

    /// Convert a 256-color palette index to RGB values.
    /// Handles standard 16 colors, 6x6x6 color cube (16-231), and grayscale (232-255).
    fn indexToRgb(idx: u8) Rgb {
        if (idx < 16) {
            // Standard 16 colors (ANSI)
            const palette = [16][3]u8{
                .{ 0, 0, 0 }, // 0: black
                .{ 128, 0, 0 }, // 1: red
                .{ 0, 128, 0 }, // 2: green
                .{ 128, 128, 0 }, // 3: yellow
                .{ 0, 0, 128 }, // 4: blue
                .{ 128, 0, 128 }, // 5: magenta
                .{ 0, 128, 128 }, // 6: cyan
                .{ 192, 192, 192 }, // 7: white
                .{ 128, 128, 128 }, // 8: bright black (gray)
                .{ 255, 0, 0 }, // 9: bright red
                .{ 0, 255, 0 }, // 10: bright green
                .{ 255, 255, 0 }, // 11: bright yellow
                .{ 0, 0, 255 }, // 12: bright blue
                .{ 255, 0, 255 }, // 13: bright magenta
                .{ 0, 255, 255 }, // 14: bright cyan
                .{ 255, 255, 255 }, // 15: bright white
            };
            return .{ .r = palette[idx][0], .g = palette[idx][1], .b = palette[idx][2] };
        } else if (idx < 232) {
            // 6x6x6 color cube (indices 16-231)
            const cube_idx = idx - 16;
            const r = cube_idx / 36;
            const g = (cube_idx % 36) / 6;
            const b = cube_idx % 6;
            // Convert 0-5 to 0-255 (0, 95, 135, 175, 215, 255)
            const cube_values = [6]u8{ 0, 95, 135, 175, 215, 255 };
            return .{ .r = cube_values[r], .g = cube_values[g], .b = cube_values[b] };
        } else {
            // Grayscale (indices 232-255): 24 shades from 8 to 238
            const gray: u8 = @intCast(8 + (@as(u16, idx - 232) * 10));
            return .{ .r = gray, .g = gray, .b = gray };
        }
    }

    /// Approximate RGB to 256-color palette index.
    /// Chooses between 6x6x6 cube and grayscale based on which is closer.
    pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
        // Check if grayscale would be a better fit
        const max_rgb = @max(r, @max(g, b));
        const min_rgb = @min(r, @min(g, b));

        if (max_rgb - min_rgb < 20) {
            // Color is close to gray, use grayscale ramp
            const avg: u16 = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
            if (avg < 8) return 16; // Black in cube is closer (< 8 to avoid underflow)
            if (avg >= 248) return 231; // White in cube is closer (>= to avoid overflow)
            // Map to grayscale ramp (232-255)
            // Safe: avg is in range [8, 247], so result is in [232, 255]
            return @intCast(232 + ((avg - 8) * 24) / 240);
        }

        // Map to 6x6x6 color cube
        const r_idx: u8 = rgbComponent256(r);
        const g_idx: u8 = rgbComponent256(g);
        const b_idx: u8 = rgbComponent256(b);

        return 16 + r_idx * 36 + g_idx * 6 + b_idx;
    }

    /// Map a single RGB component (0-255) to a 6x6x6 cube index (0-5)
    fn rgbComponent256(v: u8) u8 {
        // Cube values are: 0, 95, 135, 175, 215, 255
        // Thresholds are midpoints: 48, 115, 155, 195, 235
        if (v < 48) return 0;
        if (v < 115) return 1;
        if (v < 155) return 2;
        if (v < 195) return 3;
        if (v < 235) return 4;
        return 5;
    }

    /// Approximate 256-color palette index to 16-color (basic ANSI).
    /// Uses perceptual color matching.
    pub fn idx256To16(idx: u8) u8 {
        if (idx < 16) return idx;

        // Get RGB values for this index
        const rgb_vals = indexToRgb(idx);
        const r = rgb_vals.r;
        const g = rgb_vals.g;
        const b = rgb_vals.b;

        return rgbTo16(r, g, b);
    }

    /// Approximate RGB to 16-color (basic ANSI) palette.
    pub fn rgbTo16(r: u8, g: u8, b: u8) u8 {
        // Check for grayscale first
        const max_rgb = @max(r, @max(g, b));
        const min_rgb = @min(r, @min(g, b));

        if (max_rgb - min_rgb < 30) {
            // Grayscale: map to black, gray, or white
            const avg = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
            if (avg < 50) return 0; // black
            if (avg < 150) return 8; // bright black (dark gray)
            if (avg < 200) return 7; // white (light gray)
            return 15; // bright white
        }

        // Determine brightness (normal vs bright)
        const brightness: u8 = if (max_rgb >= 170) 8 else 0;

        // Determine color components using higher thresholds for more accuracy
        const threshold: u8 = if (brightness == 8) 85 else 64;
        var color: u8 = 0;
        if (r >= threshold and r >= g -| 30 and r >= b -| 30) color |= 1; // red
        if (g >= threshold and g >= r -| 30 and g >= b -| 30) color |= 2; // green
        if (b >= threshold and b >= r -| 30 and b >= g -| 30) color |= 4; // blue

        if (color == 0) color = 7; // Default to white if nothing matched

        return color + brightness;
    }

    /// Downgrade a color to the specified color depth.
    /// Returns a new Color that can be rendered at the target depth.
    pub fn downgrade(self: Color, target_depth: ColorDepth) Color {
        return switch (target_depth) {
            .mono => .default, // Mono terminals use default colors only
            .basic => switch (self) {
                .default => .default,
                .index => |idx| .{ .index = if (idx < 16) idx else idx256To16(idx) },
                .rgb => |c| .{ .index = rgbTo16(c.r, c.g, c.b) },
            },
            .color_256 => switch (self) {
                .default => .default,
                .index => self, // Already valid
                .rgb => |c| .{ .index = rgbTo256(c.r, c.g, c.b) },
            },
            .true_color => self, // No downgrade needed
        };
    }
};

/// Color depth levels for terminal capability detection
pub const ColorDepth = enum {
    /// Monochrome (2 colors)
    mono,
    /// Basic 8/16 colors
    basic,
    /// 256 colors
    color_256,
    /// True color (24-bit RGB)
    true_color,
};

/// Text attributes
pub const Attributes = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reverse: bool = false,
    dim: bool = false,
    blink: bool = false,
    _padding: u1 = 0,

    pub fn eql(self: Attributes, other: Attributes) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }
};

/// The default cell used for clear() and out-of-bounds reads
pub const default: Cell = .{
    .char = ' ',
    .combining = .{ 0, 0 },
    .fg = .default,
    .bg = .default,
    .attrs = .{},
};

/// Check if this is a continuation cell (second half of wide character)
pub fn isContinuation(self: Cell) bool {
    return self.char == 0;
}

/// Create a continuation cell (for wide character second half)
pub fn continuation(fg: Color, bg: Color, attrs: Attributes) Cell {
    return .{
        .char = 0,
        .combining = .{ 0, 0 },
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

/// Check if two cells are equal
pub fn eql(self: Cell, other: Cell) bool {
    return self.char == other.char and
        self.combining[0] == other.combining[0] and
        self.combining[1] == other.combining[1] and
        self.fg.eql(other.fg) and
        self.bg.eql(other.bg) and
        self.attrs.eql(other.attrs);
}

/// Add a combining mark to this cell.
/// Returns true if successful, false if no more slots available.
pub fn addCombining(self: *Cell, mark: u21) bool {
    for (&self.combining) |*slot| {
        if (slot.* == 0) {
            slot.* = mark;
            return true;
        }
    }
    return false; // No slots available, mark is dropped
}

/// Check if this cell has any combining marks
pub fn hasCombining(self: Cell) bool {
    return self.combining[0] != 0;
}

test "Cell default" {
    const cell = default;
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
    try std.testing.expect(cell.fg.eql(.default));
    try std.testing.expect(cell.bg.eql(.default));
}

test "Cell continuation" {
    const cell = continuation(.default, .default, .{});
    try std.testing.expect(cell.isContinuation());
    try std.testing.expectEqual(@as(u21, 0), cell.char);
}

test "Color equality" {
    try std.testing.expect(Color.red.eql(Color.red));
    try std.testing.expect(!Color.red.eql(Color.green));
    try std.testing.expect(Color.fromRgb(255, 0, 0).eql(Color.fromRgb(255, 0, 0)));
    try std.testing.expect(!Color.fromRgb(255, 0, 0).eql(Color.fromRgb(0, 255, 0)));
}

test "Attributes equality" {
    const a1: Attributes = .{ .bold = true };
    const a2: Attributes = .{ .bold = true };
    const a3: Attributes = .{ .italic = true };
    try std.testing.expect(a1.eql(a2));
    try std.testing.expect(!a1.eql(a3));
}

// ============================================================================
// Color creation helper tests
// ============================================================================

test "Color.fromGray" {
    // Test extreme values
    const near_black = Color.fromGray(5);
    try std.testing.expectEqual(@as(u8, 16), near_black.index);

    const near_white = Color.fromGray(250);
    try std.testing.expectEqual(@as(u8, 231), near_white.index);

    // Test mid-range (should be in grayscale ramp 232-255)
    const mid_gray = Color.fromGray(128);
    try std.testing.expect(mid_gray.index >= 232 and mid_gray.index <= 255);

    // Test boundary values to ensure no overflow/underflow
    // These used to cause panics before the fix
    const gray_0 = Color.fromGray(0);
    try std.testing.expectEqual(@as(u8, 16), gray_0.index);

    const gray_7 = Color.fromGray(7);
    try std.testing.expectEqual(@as(u8, 16), gray_7.index);

    const gray_8 = Color.fromGray(8);
    try std.testing.expectEqual(@as(u8, 232), gray_8.index); // First grayscale

    const gray_247 = Color.fromGray(247);
    try std.testing.expect(gray_247.index >= 232 and gray_247.index <= 255);

    const gray_248 = Color.fromGray(248);
    try std.testing.expectEqual(@as(u8, 231), gray_248.index); // Near white

    const gray_255 = Color.fromGray(255);
    try std.testing.expectEqual(@as(u8, 231), gray_255.index);
}

test "Color.fromHsl basic colors" {
    // Red: HSL(0, 100, 50)
    const red = Color.fromHsl(0, 100, 50);
    const red_rgb = red.toRgb();
    try std.testing.expect(red_rgb.r > 200); // Should be close to 255
    try std.testing.expect(red_rgb.g < 50); // Should be close to 0
    try std.testing.expect(red_rgb.b < 50); // Should be close to 0

    // Green: HSL(120, 100, 50)
    const green = Color.fromHsl(120, 100, 50);
    const green_rgb = green.toRgb();
    try std.testing.expect(green_rgb.g > 200);
    try std.testing.expect(green_rgb.r < 50);
    try std.testing.expect(green_rgb.b < 50);

    // Blue: HSL(240, 100, 50)
    const blue = Color.fromHsl(240, 100, 50);
    const blue_rgb = blue.toRgb();
    try std.testing.expect(blue_rgb.b > 200);
    try std.testing.expect(blue_rgb.r < 50);
    try std.testing.expect(blue_rgb.g < 50);
}

test "Color.fromHsl grayscale" {
    // Gray: saturation = 0
    const gray = Color.fromHsl(0, 0, 50);
    const gray_rgb = gray.toRgb();
    // All components should be equal (or very close)
    try std.testing.expect(gray_rgb.r == gray_rgb.g and gray_rgb.g == gray_rgb.b);
    try std.testing.expect(gray_rgb.r > 100 and gray_rgb.r < 150);
}

// ============================================================================
// Color conversion tests
// ============================================================================

test "Color.toRgb for indexed colors" {
    // Standard black
    const black_rgb = Color.black.toRgb();
    try std.testing.expectEqual(@as(u8, 0), black_rgb.r);
    try std.testing.expectEqual(@as(u8, 0), black_rgb.g);
    try std.testing.expectEqual(@as(u8, 0), black_rgb.b);

    // Standard red
    const red_rgb = Color.red.toRgb();
    try std.testing.expectEqual(@as(u8, 128), red_rgb.r);
    try std.testing.expectEqual(@as(u8, 0), red_rgb.g);
    try std.testing.expectEqual(@as(u8, 0), red_rgb.b);

    // Bright white
    const bright_white_rgb = Color.bright_white.toRgb();
    try std.testing.expectEqual(@as(u8, 255), bright_white_rgb.r);
    try std.testing.expectEqual(@as(u8, 255), bright_white_rgb.g);
    try std.testing.expectEqual(@as(u8, 255), bright_white_rgb.b);
}

test "Color.toRgb for 256-color cube" {
    // Pure red in cube (index 196 = 5*36 + 0*6 + 0 + 16)
    const cube_red: Color = .{ .index = 196 };
    const cube_red_rgb = cube_red.toRgb();
    try std.testing.expectEqual(@as(u8, 255), cube_red_rgb.r);
    try std.testing.expectEqual(@as(u8, 0), cube_red_rgb.g);
    try std.testing.expectEqual(@as(u8, 0), cube_red_rgb.b);

    // Black in cube (index 16)
    const cube_black: Color = .{ .index = 16 };
    const cube_black_rgb = cube_black.toRgb();
    try std.testing.expectEqual(@as(u8, 0), cube_black_rgb.r);
    try std.testing.expectEqual(@as(u8, 0), cube_black_rgb.g);
    try std.testing.expectEqual(@as(u8, 0), cube_black_rgb.b);
}

test "Color.toRgb for grayscale ramp" {
    // Darkest gray (232)
    const dark_gray: Color = .{ .index = 232 };
    const dark_gray_rgb = dark_gray.toRgb();
    try std.testing.expectEqual(@as(u8, 8), dark_gray_rgb.r);
    try std.testing.expect(dark_gray_rgb.r == dark_gray_rgb.g and dark_gray_rgb.g == dark_gray_rgb.b);

    // Lightest gray (255)
    const light_gray: Color = .{ .index = 255 };
    const light_gray_rgb = light_gray.toRgb();
    try std.testing.expectEqual(@as(u8, 238), light_gray_rgb.r);
    try std.testing.expect(light_gray_rgb.r == light_gray_rgb.g and light_gray_rgb.g == light_gray_rgb.b);
}

test "Color.rgbTo256 basic colors" {
    // Black
    try std.testing.expectEqual(@as(u8, 16), Color.rgbTo256(0, 0, 0));

    // White
    try std.testing.expectEqual(@as(u8, 231), Color.rgbTo256(255, 255, 255));

    // Pure red
    try std.testing.expectEqual(@as(u8, 196), Color.rgbTo256(255, 0, 0));

    // Pure green
    try std.testing.expectEqual(@as(u8, 46), Color.rgbTo256(0, 255, 0));

    // Pure blue
    try std.testing.expectEqual(@as(u8, 21), Color.rgbTo256(0, 0, 255));
}

test "Color.rgbTo256 grayscale detection" {
    // Gray values should map to grayscale ramp, not color cube
    const gray_idx = Color.rgbTo256(128, 128, 128);
    try std.testing.expect(gray_idx >= 232); // Should be in grayscale ramp
}

test "Color.rgbTo256 boundary values" {
    // Test boundary values to ensure no overflow/underflow
    // These used to cause panics before the fix

    // Near black (avg < 8)
    try std.testing.expectEqual(@as(u8, 16), Color.rgbTo256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 16), Color.rgbTo256(5, 5, 5));
    try std.testing.expectEqual(@as(u8, 16), Color.rgbTo256(7, 7, 7));

    // First grayscale value (avg = 8)
    try std.testing.expectEqual(@as(u8, 232), Color.rgbTo256(8, 8, 8));

    // Near white (avg >= 248)
    try std.testing.expectEqual(@as(u8, 231), Color.rgbTo256(248, 248, 248));
    try std.testing.expectEqual(@as(u8, 231), Color.rgbTo256(250, 250, 250));
    try std.testing.expectEqual(@as(u8, 231), Color.rgbTo256(255, 255, 255));
}

test "Color.rgbTo16 basic colors" {
    // Black
    try std.testing.expectEqual(@as(u8, 0), Color.rgbTo16(0, 0, 0));

    // Bright red
    try std.testing.expectEqual(@as(u8, 9), Color.rgbTo16(255, 0, 0));

    // Bright green
    try std.testing.expectEqual(@as(u8, 10), Color.rgbTo16(0, 255, 0));

    // Bright blue
    try std.testing.expectEqual(@as(u8, 12), Color.rgbTo16(0, 0, 255));

    // Bright white
    try std.testing.expectEqual(@as(u8, 15), Color.rgbTo16(255, 255, 255));
}

test "Color.rgbTo16 grayscale" {
    // Dark gray -> bright black (8)
    try std.testing.expectEqual(@as(u8, 8), Color.rgbTo16(80, 80, 80));

    // Light gray -> white (7)
    try std.testing.expectEqual(@as(u8, 7), Color.rgbTo16(180, 180, 180));
}

test "Color.idx256To16 passthrough for basic colors" {
    // Basic colors 0-15 should pass through unchanged
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(i, Color.idx256To16(i));
    }
}

test "Color.idx256To16 cube colors" {
    // Pure red in cube (196) should map to bright red (9)
    try std.testing.expectEqual(@as(u8, 9), Color.idx256To16(196));

    // Pure green in cube (46) should map to bright green (10)
    try std.testing.expectEqual(@as(u8, 10), Color.idx256To16(46));

    // Pure blue in cube (21) should map to bright blue (12)
    try std.testing.expectEqual(@as(u8, 12), Color.idx256To16(21));
}

// ============================================================================
// Color downgrade tests
// ============================================================================

test "Color.downgrade to mono" {
    // All colors should become default in mono mode
    try std.testing.expect(Color.red.downgrade(.mono).eql(.default));
    try std.testing.expect(Color.fromRgb(255, 128, 64).downgrade(.mono).eql(.default));
    const default_color: Color = .default;
    try std.testing.expect(default_color.downgrade(.mono).eql(.default));
}

test "Color.downgrade to basic" {
    // RGB should be converted to 16-color index
    const red_rgb = Color.fromRgb(255, 0, 0);
    const downgraded = red_rgb.downgrade(.basic);
    try std.testing.expectEqual(@as(u8, 9), downgraded.index); // bright red

    // Basic colors should remain unchanged
    try std.testing.expect(Color.red.downgrade(.basic).eql(Color.red));

    // 256-color should be converted to 16-color
    const cube_color: Color = .{ .index = 196 };
    const basic_color = cube_color.downgrade(.basic);
    try std.testing.expect(basic_color.index < 16);
}

test "Color.downgrade to 256" {
    // RGB should be converted to 256-color index
    const rgb_color = Color.fromRgb(255, 0, 0);
    const downgraded = rgb_color.downgrade(.color_256);
    try std.testing.expectEqual(@as(u8, 196), downgraded.index);

    // Index colors should remain unchanged
    const idx_color: Color = .{ .index = 100 };
    try std.testing.expect(idx_color.downgrade(.color_256).eql(idx_color));
}

test "Color.downgrade to true_color" {
    // True color should remain unchanged
    const rgb_color = Color.fromRgb(123, 45, 67);
    try std.testing.expect(rgb_color.downgrade(.true_color).eql(rgb_color));
}

// ============================================================================
// Combining mark tests
// ============================================================================

test "Cell addCombining" {
    var cell: Cell = .{
        .char = 'e',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    // First combining mark should succeed
    try std.testing.expect(cell.addCombining(0x0301)); // Combining acute accent
    try std.testing.expectEqual(@as(u21, 0x0301), cell.combining[0]);
    try std.testing.expectEqual(@as(u21, 0), cell.combining[1]);

    // Second combining mark should succeed
    try std.testing.expect(cell.addCombining(0x0327)); // Combining cedilla
    try std.testing.expectEqual(@as(u21, 0x0301), cell.combining[0]);
    try std.testing.expectEqual(@as(u21, 0x0327), cell.combining[1]);

    // Third combining mark should fail (only 2 slots)
    try std.testing.expect(!cell.addCombining(0x0308)); // Combining diaeresis
}

test "Cell hasCombining" {
    const no_combining: Cell = .{
        .char = 'a',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!no_combining.hasCombining());

    const with_combining: Cell = .{
        .char = 'e',
        .combining = .{ 0x0301, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(with_combining.hasCombining());
}

test "Cell eql with combining marks" {
    const cell1: Cell = .{
        .char = 'e',
        .combining = .{ 0x0301, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    const cell2: Cell = .{
        .char = 'e',
        .combining = .{ 0x0301, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    const cell3: Cell = .{
        .char = 'e',
        .combining = .{ 0x0300, 0 }, // Different combining mark
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    const cell4: Cell = .{
        .char = 'e',
        .combining = .{ 0, 0 }, // No combining marks
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    try std.testing.expect(cell1.eql(cell2));
    try std.testing.expect(!cell1.eql(cell3));
    try std.testing.expect(!cell1.eql(cell4));
}

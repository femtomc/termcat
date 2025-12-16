const std = @import("std");

/// Single terminal cell
pub const Cell = @This();

/// Unicode codepoint (or first codepoint of grapheme).
/// 0 indicates a continuation cell (second half of wide character).
char: u21,
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
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

/// Check if two cells are equal
pub fn eql(self: Cell, other: Cell) bool {
    return self.char == other.char and
        self.fg.eql(other.fg) and
        self.bg.eql(other.bg) and
        self.attrs.eql(other.attrs);
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

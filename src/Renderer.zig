const std = @import("std");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;
const Buffer = @import("Buffer.zig");
const Event = @import("Event.zig");
const Size = Event.Size;
const Position = Event.Position;
const posix = @import("backend/posix.zig");
const ColorDepth = posix.ColorDepth;

/// Diff-based terminal renderer.
/// Maintains front and back buffers to minimize terminal output.
pub const Renderer = @This();

/// Front buffer (current terminal state)
front: Buffer,
/// Back buffer (desired state - user draws here)
back: Buffer,
/// Allocator for buffers
allocator: std.mem.Allocator,
/// Terminal color depth for output
color_depth: ColorDepth,
/// Current cursor position (null = hidden)
cursor_pos: ?Position,
/// Whether cursor visibility changed
cursor_dirty: bool,
/// Whether a full redraw is needed
needs_full_redraw: bool,

/// Render errors
pub const Error = error{
    SizeMismatch,
    OutOfMemory,
};

/// Initialize the renderer with the given size
pub fn init(allocator: std.mem.Allocator, dimensions: Size, color_depth: ColorDepth) !Renderer {
    var front = try Buffer.init(allocator, dimensions);
    errdefer front.deinit();

    var back = try Buffer.init(allocator, dimensions);
    errdefer back.deinit();

    return Renderer{
        .front = front,
        .back = back,
        .allocator = allocator,
        .color_depth = color_depth,
        .cursor_pos = null,
        .cursor_dirty = false,
        .needs_full_redraw = true,
    };
}

/// Clean up renderer resources
pub fn deinit(self: *Renderer) void {
    self.front.deinit();
    self.back.deinit();
    self.* = undefined;
}

/// Get the back buffer for drawing
pub fn buffer(self: *Renderer) *Buffer {
    return &self.back;
}

/// Get current size
pub fn size(self: Renderer) Size {
    return self.back.size();
}

/// Resize both buffers. Clears content.
pub fn resize(self: *Renderer, new_size: Size) !void {
    try self.front.resize(new_size);
    try self.back.resize(new_size);
    self.needs_full_redraw = true;
}

/// Set cursor position (or hide with null)
pub fn setCursor(self: *Renderer, pos: ?Position) void {
    if (self.cursor_pos == null and pos == null) return;
    if (self.cursor_pos != null and pos != null) {
        if (self.cursor_pos.?.x == pos.?.x and self.cursor_pos.?.y == pos.?.y) return;
    }
    self.cursor_pos = pos;
    self.cursor_dirty = true;
}

/// Clear the back buffer
pub fn clear(self: *Renderer) void {
    self.back.clear();
}

/// Flush changes to the terminal output buffer.
/// Computes diff between front and back buffers, emits minimal ANSI sequences.
/// After flush, front buffer matches back buffer.
pub fn flush(self: *Renderer, writer: anytype) !void {
    const w = self.back.width;
    const h = self.back.height;

    if (self.needs_full_redraw) {
        // Full redraw - clear screen and redraw everything
        try writer.writeAll("\x1b[2J\x1b[H");
        try self.renderFull(writer);
        self.needs_full_redraw = false;
    } else {
        // Diff-based update
        try self.renderDiff(writer);
    }

    // Copy back buffer to front buffer
    @memcpy(self.front.cells, self.back.cells);

    // Handle cursor
    if (self.cursor_dirty) {
        if (self.cursor_pos) |pos| {
            // Show cursor and move to position
            try writer.print("\x1b[{d};{d}H\x1b[?25h", .{ pos.y + 1, pos.x + 1 });
        } else {
            // Hide cursor
            try writer.writeAll("\x1b[?25l");
        }
        self.cursor_dirty = false;
    }

    _ = w;
    _ = h;
}

/// Render full screen (used on first draw or after clear)
fn renderFull(self: *Renderer, writer: anytype) !void {
    var last_fg: ?Color = null;
    var last_bg: ?Color = null;
    var last_attrs: ?Attributes = null;

    var y: u16 = 0;
    while (y < self.back.height) : (y += 1) {
        // Move to start of row
        try writer.print("\x1b[{d};1H", .{y + 1});

        var x: u16 = 0;
        while (x < self.back.width) {
            const cell = self.back.getCell(x, y);

            // Skip continuation cells (handled by previous wide char)
            if (cell.isContinuation()) {
                x += 1;
                continue;
            }

            // Update attributes if changed
            try self.emitAttributeChanges(writer, cell, &last_fg, &last_bg, &last_attrs);

            // Emit character
            try self.emitChar(writer, cell.char);

            x += 1;
        }
    }

    // Reset attributes at end
    try writer.writeAll("\x1b[0m");
}

/// Render only changed cells (diff-based)
fn renderDiff(self: *Renderer, writer: anytype) !void {
    var last_fg: ?Color = null;
    var last_bg: ?Color = null;
    var last_attrs: ?Attributes = null;
    var last_x: ?u16 = null;
    var last_y: ?u16 = null;

    var y: u16 = 0;
    while (y < self.back.height) : (y += 1) {
        var x: u16 = 0;
        while (x < self.back.width) {
            const back_cell = self.back.getCell(x, y);
            const front_cell = self.front.getCell(x, y);

            // Skip if cell unchanged
            if (back_cell.eql(front_cell)) {
                x += 1;
                continue;
            }

            // Skip continuation cells
            if (back_cell.isContinuation()) {
                x += 1;
                continue;
            }

            // Move cursor if needed
            if (last_x == null or last_y == null or last_y.? != y or last_x.? != x) {
                try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            }

            // Update attributes if changed
            try self.emitAttributeChanges(writer, back_cell, &last_fg, &last_bg, &last_attrs);

            // Emit character
            try self.emitChar(writer, back_cell.char);

            // Track position for grouping consecutive writes
            last_x = x + 1;
            last_y = y;

            x += 1;
        }
    }

    // Reset attributes at end if we wrote anything
    if (last_x != null) {
        try writer.writeAll("\x1b[0m");
    }
}

/// Emit attribute/color change sequences
fn emitAttributeChanges(
    self: *Renderer,
    writer: anytype,
    cell: Cell,
    last_fg: *?Color,
    last_bg: *?Color,
    last_attrs: *?Attributes,
) !void {
    const need_fg_change = last_fg.* == null or !last_fg.*.?.eql(cell.fg);
    const need_bg_change = last_bg.* == null or !last_bg.*.?.eql(cell.bg);
    const need_attr_change = last_attrs.* == null or !last_attrs.*.?.eql(cell.attrs);

    if (!need_fg_change and !need_bg_change and !need_attr_change) {
        return;
    }

    // For simplicity, reset and re-apply all attributes on any change
    // A more optimized version would emit only the delta
    try writer.writeAll("\x1b[0m");

    // Apply attributes
    if (cell.attrs.bold) try writer.writeAll("\x1b[1m");
    if (cell.attrs.dim) try writer.writeAll("\x1b[2m");
    if (cell.attrs.italic) try writer.writeAll("\x1b[3m");
    if (cell.attrs.underline) try writer.writeAll("\x1b[4m");
    if (cell.attrs.blink) try writer.writeAll("\x1b[5m");
    if (cell.attrs.reverse) try writer.writeAll("\x1b[7m");
    if (cell.attrs.strikethrough) try writer.writeAll("\x1b[9m");

    // Apply foreground color
    try self.emitFgColor(writer, cell.fg);

    // Apply background color
    try self.emitBgColor(writer, cell.bg);

    last_fg.* = cell.fg;
    last_bg.* = cell.bg;
    last_attrs.* = cell.attrs;
}

/// Emit foreground color sequence
fn emitFgColor(self: *Renderer, writer: anytype, color: Color) !void {
    switch (color) {
        .default => try writer.writeAll("\x1b[39m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{30 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{90 + idx - 8});
            } else {
                // 256-color mode
                if (self.color_depth == .basic or self.color_depth == .mono) {
                    // Fallback to basic color
                    const basic = approximate256To16(idx);
                    try self.emitFgColor(writer, .{ .index = basic });
                } else {
                    try writer.print("\x1b[38;5;{d}m", .{idx});
                }
            }
        },
        .rgb => |c| {
            if (self.color_depth == .true_color) {
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
            } else if (self.color_depth == .color_256) {
                // Fallback to 256-color
                const idx = approximateRgbTo256(c.r, c.g, c.b);
                try writer.print("\x1b[38;5;{d}m", .{idx});
            } else {
                // Fallback to basic
                const idx = approximateRgbTo16(c.r, c.g, c.b);
                try self.emitFgColor(writer, .{ .index = idx });
            }
        },
    }
}

/// Emit background color sequence
fn emitBgColor(self: *Renderer, writer: anytype, color: Color) !void {
    switch (color) {
        .default => try writer.writeAll("\x1b[49m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{40 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{100 + idx - 8});
            } else {
                // 256-color mode
                if (self.color_depth == .basic or self.color_depth == .mono) {
                    const basic = approximate256To16(idx);
                    try self.emitBgColor(writer, .{ .index = basic });
                } else {
                    try writer.print("\x1b[48;5;{d}m", .{idx});
                }
            }
        },
        .rgb => |c| {
            if (self.color_depth == .true_color) {
                try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
            } else if (self.color_depth == .color_256) {
                const idx = approximateRgbTo256(c.r, c.g, c.b);
                try writer.print("\x1b[48;5;{d}m", .{idx});
            } else {
                const idx = approximateRgbTo16(c.r, c.g, c.b);
                try self.emitBgColor(writer, .{ .index = idx });
            }
        },
    }
}

/// Emit a character (UTF-8 encoded)
fn emitChar(self: *Renderer, writer: anytype, char: u21) !void {
    _ = self;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &buf) catch 1;
    try writer.writeAll(buf[0..len]);
}

/// Approximate 256-color palette index to 16-color
fn approximate256To16(idx: u8) u8 {
    if (idx < 16) return idx;

    // 216 color cube (indices 16-231)
    if (idx < 232) {
        const cube_idx = idx - 16;
        const r = cube_idx / 36;
        const g = (cube_idx % 36) / 6;
        const b = cube_idx % 6;

        // Simple mapping based on dominant color
        const max = @max(r, @max(g, b));
        if (max == 0) return 0; // black

        const bright: u8 = if (max >= 4) 8 else 0;

        var result: u8 = 0;
        if (r >= 3) result |= 1; // red
        if (g >= 3) result |= 2; // green
        if (b >= 3) result |= 4; // blue

        if (result == 0) result = 7; // white-ish
        return result + bright;
    }

    // Grayscale (indices 232-255)
    const gray = idx - 232; // 0-23
    if (gray < 6) return 0; // black
    if (gray < 18) return 7; // white
    return 15; // bright white
}

/// Approximate RGB to 256-color palette
fn approximateRgbTo256(r: u8, g: u8, b: u8) u8 {
    // Map to 6x6x6 color cube
    const r_idx: u8 = @min(5, r / 43);
    const g_idx: u8 = @min(5, g / 43);
    const b_idx: u8 = @min(5, b / 43);

    return 16 + r_idx * 36 + g_idx * 6 + b_idx;
}

/// Approximate RGB to 16-color palette
fn approximateRgbTo16(r: u8, g: u8, b: u8) u8 {
    const idx = approximateRgbTo256(r, g, b);
    return approximate256To16(idx);
}

test "Renderer init and deinit" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 80, .height = 24 }, .true_color);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u16, 80), renderer.size().width);
    try std.testing.expectEqual(@as(u16, 24), renderer.size().height);
}

test "Renderer buffer access" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(5, 2, Cell{ .char = 'X', .fg = .default, .bg = .default, .attrs = .{} });

    try std.testing.expectEqual(@as(u21, 'X'), buf.getCell(5, 2).char);
}

test "Renderer flush produces output" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(0, 0, Cell{ .char = 'H', .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(1, 0, Cell{ .char = 'i', .fg = .default, .bg = .default, .attrs = .{} });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    // Should contain cursor positioning and characters
    try std.testing.expect(output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "i") != null);
}

test "Renderer setCursor" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    renderer.setCursor(.{ .x = 5, .y = 3 });
    try std.testing.expect(renderer.cursor_dirty);
    try std.testing.expectEqual(@as(u16, 5), renderer.cursor_pos.?.x);
    try std.testing.expectEqual(@as(u16, 3), renderer.cursor_pos.?.y);
}

test "Renderer resize" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    try renderer.resize(.{ .width = 20, .height = 10 });

    try std.testing.expectEqual(@as(u16, 20), renderer.size().width);
    try std.testing.expectEqual(@as(u16, 10), renderer.size().height);
    try std.testing.expect(renderer.needs_full_redraw);
}

test "approximate256To16" {
    // Standard colors should pass through
    try std.testing.expectEqual(@as(u8, 0), approximate256To16(0));
    try std.testing.expectEqual(@as(u8, 1), approximate256To16(1));
    try std.testing.expectEqual(@as(u8, 15), approximate256To16(15));

    // Grayscale
    try std.testing.expectEqual(@as(u8, 0), approximate256To16(232)); // darkest gray
    try std.testing.expectEqual(@as(u8, 15), approximate256To16(255)); // lightest gray
}

test "approximateRgbTo256" {
    // Black
    try std.testing.expectEqual(@as(u8, 16), approximateRgbTo256(0, 0, 0));
    // White
    try std.testing.expectEqual(@as(u8, 231), approximateRgbTo256(255, 255, 255));
    // Pure red
    try std.testing.expectEqual(@as(u8, 196), approximateRgbTo256(255, 0, 0));
}

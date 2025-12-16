const std = @import("std");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const ColorDepth = Cell.ColorDepth;
const Attributes = Cell.Attributes;
const Buffer = @import("Buffer.zig");
const Event = @import("Event.zig");
const Size = Event.Size;
const Position = Event.Position;

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

            // Emit character and combining marks
            try self.emitCell(writer, cell);

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

            // Emit character and combining marks
            try self.emitCell(writer, back_cell);

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
    // Downgrade color to match terminal capability
    const effective_color = color.downgrade(self.color_depth);

    switch (effective_color) {
        .default => try writer.writeAll("\x1b[39m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{30 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{90 + idx - 8});
            } else {
                // 256-color mode (only reached if color_depth >= color_256)
                try writer.print("\x1b[38;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            // Only reached if color_depth == true_color
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }
}

/// Emit background color sequence
fn emitBgColor(self: *Renderer, writer: anytype, color: Color) !void {
    // Downgrade color to match terminal capability
    const effective_color = color.downgrade(self.color_depth);

    switch (effective_color) {
        .default => try writer.writeAll("\x1b[49m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{40 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{100 + idx - 8});
            } else {
                // 256-color mode (only reached if color_depth >= color_256)
                try writer.print("\x1b[48;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            // Only reached if color_depth == true_color
            try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }
}

/// Emit a character with its combining marks (UTF-8 encoded)
fn emitCell(self: *Renderer, writer: anytype, cell: Cell) !void {
    _ = self;
    var buf: [4]u8 = undefined;

    // Emit base character
    const len = std.unicode.utf8Encode(cell.char, &buf) catch blk: {
        // Invalid codepoint - emit replacement character (U+FFFD)
        break :blk std.unicode.utf8Encode(0xFFFD, &buf) catch 1;
    };
    try writer.writeAll(buf[0..len]);

    // Emit combining marks
    for (cell.combining) |mark| {
        if (mark == 0) break;
        const mark_len = std.unicode.utf8Encode(mark, &buf) catch continue;
        try writer.writeAll(buf[0..mark_len]);
    }
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

test "Renderer color downgrade in output" {
    // Test that renderer properly downgrades colors based on color depth
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .basic);
    defer renderer.deinit();

    const buf = renderer.buffer();
    // Set a cell with RGB color - should be downgraded to basic when rendered
    buf.setCell(0, 0, Cell{ .char = 'X', .fg = Color.fromRgb(255, 0, 0), .bg = .default, .attrs = .{} });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    // Output should NOT contain 38;2 (true color) since we're in basic mode
    try std.testing.expect(std.mem.indexOf(u8, output.items, "38;2") == null);
    // Should contain basic color escape sequence
    try std.testing.expect(output.items.len > 0);
}

test "Renderer attributes output" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(0, 0, Cell{
        .char = 'B',
        .fg = .default,
        .bg = .default,
        .attrs = .{ .bold = true },
    });
    buf.setCell(1, 0, Cell{
        .char = 'I',
        .fg = .default,
        .bg = .default,
        .attrs = .{ .italic = true },
    });
    buf.setCell(2, 0, Cell{
        .char = 'U',
        .fg = .default,
        .bg = .default,
        .attrs = .{ .underline = true },
    });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    // Check for attribute escape sequences
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[1m") != null); // bold
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[3m") != null); // italic
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[4m") != null); // underline
}

test "Renderer emits combining marks" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    // Set a cell with 'e' and combining acute accent (U+0301)
    buf.setCell(0, 0, Cell{
        .char = 'e',
        .combining = .{ 0x0301, 0 }, // combining acute
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    // Output should contain 'e' followed by combining acute (U+0301 = 0xCC 0x81 in UTF-8)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "e\xCC\x81") != null);
}

test "Renderer emits wide characters correctly" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    // Use print to set a wide character (CJK)
    buf.print(0, 0, "中", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    // Output should contain the CJK character (中 = U+4E2D = 0xE4 0xB8 0xAD in UTF-8)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\xE4\xB8\xAD") != null);
}

test "Renderer diff skips unchanged cells" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.print(0, 0, "Hello", .default, .default, .{});

    var output1: std.ArrayList(u8) = .empty;
    defer output1.deinit(std.testing.allocator);
    try renderer.flush(output1.writer(std.testing.allocator));

    // Change only one cell
    buf.setCell(2, 0, Cell{
        .char = 'X',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    var output2: std.ArrayList(u8) = .empty;
    defer output2.deinit(std.testing.allocator);
    try renderer.flush(output2.writer(std.testing.allocator));

    // Second flush should be smaller (diff-based) and contain 'X'
    try std.testing.expect(output2.items.len < output1.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output2.items, "X") != null);
}

test "Renderer handles combining marks in diff" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    // First render with plain 'e'
    buf.setCell(0, 0, Cell{
        .char = 'e',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    var output1: std.ArrayList(u8) = .empty;
    defer output1.deinit(std.testing.allocator);
    try renderer.flush(output1.writer(std.testing.allocator));

    // Now change to 'e' with combining mark - should trigger re-render
    buf.setCell(0, 0, Cell{
        .char = 'e',
        .combining = .{ 0x0301, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    var output2: std.ArrayList(u8) = .empty;
    defer output2.deinit(std.testing.allocator);
    try renderer.flush(output2.writer(std.testing.allocator));

    // Second output should contain the combining mark
    try std.testing.expect(std.mem.indexOf(u8, output2.items, "e\xCC\x81") != null);
}

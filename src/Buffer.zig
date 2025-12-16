const std = @import("std");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;
const Event = @import("Event.zig");
const Size = Event.Size;
const Rect = Event.Rect;
const unicode = @import("unicode/width.zig");

/// Cell buffer for drawing.
/// All coordinates are bounds-checked: out-of-range writes are silently ignored,
/// out-of-range reads return default_cell. This allows safe clipping without
/// explicit bounds checks at every call site.
pub const Buffer = @This();

/// Width of the buffer in cells
width: u16,
/// Height of the buffer in cells
height: u16,
/// Cell data (row-major order: index = y * width + x)
cells: []Cell,
/// Allocator used for cells
allocator: std.mem.Allocator,

/// Create a new buffer with the given dimensions
pub fn init(allocator: std.mem.Allocator, dimensions: Size) !Buffer {
    const total_cells = @as(usize, dimensions.width) * @as(usize, dimensions.height);
    const cells = try allocator.alloc(Cell, total_cells);
    @memset(cells, Cell.default);

    return Buffer{
        .width = dimensions.width,
        .height = dimensions.height,
        .cells = cells,
        .allocator = allocator,
    };
}

/// Free buffer resources
pub fn deinit(self: *Buffer) void {
    self.allocator.free(self.cells);
    self.* = undefined;
}

/// Resize the buffer to new dimensions.
/// Clears the buffer content (does not preserve existing content).
pub fn resize(self: *Buffer, new_size: Size) !void {
    const new_total = @as(usize, new_size.width) * @as(usize, new_size.height);

    // Allocate new cells FIRST (before freeing old) to ensure memory safety.
    // If allocation fails, the buffer remains in a valid state.
    const new_cells = try self.allocator.alloc(Cell, new_total);
    @memset(new_cells, Cell.default);

    // Now safe to free old cells
    self.allocator.free(self.cells);

    self.cells = new_cells;
    self.width = new_size.width;
    self.height = new_size.height;
}

/// Get the index into the cells array for a position
fn index(self: Buffer, x: u16, y: u16) ?usize {
    if (x >= self.width or y >= self.height) return null;
    return @as(usize, y) * @as(usize, self.width) + @as(usize, x);
}

/// Set cell at position. Out-of-bounds coordinates are silently ignored.
/// WARNING: For wide characters (CJK, emoji), use setWideCell() instead.
/// Using setCell directly with a wide character will not set the required
/// continuation marker, which may cause rendering corruption.
pub fn setCell(self: *Buffer, x: u16, y: u16, cell: Cell) void {
    if (self.index(x, y)) |idx| {
        self.cells[idx] = cell;
    }
}

/// Set a wide character (width 2) at position with proper continuation marker.
/// Returns false if there's not enough room (x + 1 >= width) or out of bounds.
/// Use this instead of setCell for CJK, emoji, and other double-width characters.
pub fn setWideCell(self: *Buffer, x: u16, y: u16, cell: Cell) bool {
    // Need room for both the char cell and the continuation cell
    if (x + 1 >= self.width) return false;
    if (y >= self.height) return false;

    // Set the main cell
    if (self.index(x, y)) |idx| {
        self.cells[idx] = cell;
    }

    // Set the continuation marker
    if (self.index(x + 1, y)) |idx| {
        self.cells[idx] = Cell.continuation(cell.fg, cell.bg, cell.attrs);
    }

    return true;
}

/// Get cell at position. Out-of-bounds returns default_cell.
pub fn getCell(self: Buffer, x: u16, y: u16) Cell {
    if (self.index(x, y)) |idx| {
        return self.cells[idx];
    }
    return Cell.default;
}

/// Clear buffer to default_cell.
pub fn clear(self: *Buffer) void {
    @memset(self.cells, Cell.default);
}

/// Fill rectangle with cell. Rectangle is clipped to buffer bounds.
pub fn fill(self: *Buffer, rect: Rect, cell: Cell) void {
    // Clip rectangle to buffer bounds
    const x_start = rect.x;
    const y_start = rect.y;
    const x_end = @min(rect.x +| rect.width, self.width);
    const y_end = @min(rect.y +| rect.height, self.height);

    if (x_start >= self.width or y_start >= self.height) return;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            self.setCell(x, y, cell);
        }
    }
}

/// Write string starting at position (handles wide chars and zero-width chars).
/// Characters that extend beyond the right edge are clipped.
/// Wide characters at the final column are replaced with a space.
/// Zero-width characters (combining marks, control chars) are skipped and do not consume cells.
pub fn print(self: *Buffer, x: u16, y: u16, str: []const u8, fg: Color, bg: Color, attrs: Attributes) void {
    if (y >= self.height) return;

    var cur_x = x;
    var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };

    while (iter.nextCodepoint()) |cp| {
        if (cur_x >= self.width) break;

        const char_width = unicode.codePointWidth(cp);

        if (char_width == 0) {
            // Zero-width character (combining mark, control char, ZWJ, etc.)
            // Skip - do not consume a cell or advance cursor.
            // Note: Proper grapheme cluster support would require different handling.
            continue;
        } else if (char_width == 2) {
            // Wide character - needs 2 cells
            if (cur_x + 1 >= self.width) {
                // Can't fit wide char at final column - replace with space
                self.setCell(cur_x, y, Cell{
                    .char = ' ',
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                });
                break;
            }
            // First cell: the character
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            // Second cell: continuation marker
            self.setCell(cur_x + 1, y, Cell.continuation(fg, bg, attrs));
            cur_x += 2;
        } else {
            // Regular width character (width 1)
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            cur_x += 1;
        }
    }
}

/// Get buffer size
pub fn size(self: Buffer) Size {
    return Size{ .width = self.width, .height = self.height };
}

test "Buffer init and deinit" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer buf.deinit();

    try std.testing.expectEqual(@as(u16, 80), buf.width);
    try std.testing.expectEqual(@as(u16, 24), buf.height);
    try std.testing.expectEqual(@as(usize, 80 * 24), buf.cells.len);
}

test "Buffer setCell and getCell" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    const cell = Cell{
        .char = 'X',
        .fg = Color.red,
        .bg = Color.blue,
        .attrs = .{ .bold = true },
    };

    buf.setCell(5, 2, cell);
    const got = buf.getCell(5, 2);
    try std.testing.expect(got.eql(cell));
}

test "Buffer out of bounds reads return default" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    // Out of bounds should return default
    const cell = buf.getCell(100, 100);
    try std.testing.expect(cell.eql(Cell.default));
}

test "Buffer out of bounds writes are ignored" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    // This should not crash or corrupt memory
    buf.setCell(100, 100, Cell{ .char = 'X', .fg = .default, .bg = .default, .attrs = .{} });
}

test "Buffer clear" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    buf.setCell(5, 2, Cell{ .char = 'X', .fg = .default, .bg = .default, .attrs = .{} });
    buf.clear();

    const cell = buf.getCell(5, 2);
    try std.testing.expect(cell.eql(Cell.default));
}

test "Buffer fill" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    const fill_cell = Cell{
        .char = '#',
        .fg = Color.green,
        .bg = .default,
        .attrs = .{},
    };

    buf.fill(.{ .x = 2, .y = 1, .width = 3, .height = 2 }, fill_cell);

    // Check filled cells
    try std.testing.expect(buf.getCell(2, 1).eql(fill_cell));
    try std.testing.expect(buf.getCell(3, 1).eql(fill_cell));
    try std.testing.expect(buf.getCell(4, 1).eql(fill_cell));
    try std.testing.expect(buf.getCell(2, 2).eql(fill_cell));
    try std.testing.expect(buf.getCell(3, 2).eql(fill_cell));
    try std.testing.expect(buf.getCell(4, 2).eql(fill_cell));

    // Check unfilled cells
    try std.testing.expect(buf.getCell(1, 1).eql(Cell.default));
    try std.testing.expect(buf.getCell(5, 1).eql(Cell.default));
}

test "Buffer fill clips to bounds" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    const fill_cell = Cell{
        .char = '#',
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    // Fill extending beyond buffer bounds
    buf.fill(.{ .x = 8, .y = 3, .width = 10, .height = 10 }, fill_cell);

    // Check clipped fill
    try std.testing.expect(buf.getCell(8, 3).eql(fill_cell));
    try std.testing.expect(buf.getCell(9, 3).eql(fill_cell));
    try std.testing.expect(buf.getCell(8, 4).eql(fill_cell));
    try std.testing.expect(buf.getCell(9, 4).eql(fill_cell));
}

test "Buffer print simple ASCII" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    buf.print(2, 1, "Hello", Color.white, Color.black, .{});

    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(3, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), buf.getCell(4, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), buf.getCell(5, 1).char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.getCell(6, 1).char);
}

test "Buffer print clips at right edge" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 1 });
    defer buf.deinit();

    buf.print(2, 0, "Hello World", .default, .default, .{});

    // Only "Hel" should fit (positions 2, 3, 4)
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), buf.getCell(4, 0).char);
}

test "Buffer resize" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    try buf.resize(.{ .width = 20, .height = 10 });

    try std.testing.expectEqual(@as(u16, 20), buf.width);
    try std.testing.expectEqual(@as(u16, 10), buf.height);
    try std.testing.expectEqual(@as(usize, 200), buf.cells.len);
}

test "Buffer print wide characters" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print CJK character (width 2)
    buf.print(0, 0, "中", .default, .default, .{});

    // First cell has the character
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(0, 0).char); // 中
    // Second cell is continuation
    try std.testing.expect(buf.getCell(1, 0).isContinuation());
    // Third cell is still default
    try std.testing.expect(buf.getCell(2, 0).eql(Cell.default));
}

test "Buffer print wide char at final column replaced with space" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 1 });
    defer buf.deinit();

    // Try to print wide char at position 4 (final column in width 5 buffer)
    buf.print(4, 0, "中", .default, .default, .{});

    // Wide char can't fit - should be replaced with space
    try std.testing.expectEqual(@as(u21, ' '), buf.getCell(4, 0).char);
}

test "Buffer print skips zero-width characters" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print string with combining acute accent (U+0301) - zero width
    // "é" as "e" + combining acute = e + U+0301
    buf.print(0, 0, "e\xCC\x81x", .default, .default, .{}); // e + combining acute + x

    // 'e' at position 0, combining mark skipped, 'x' at position 1
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'x'), buf.getCell(1, 0).char);
    // Position 2 should still be default
    try std.testing.expect(buf.getCell(2, 0).eql(Cell.default));
}

test "Buffer setWideCell" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    const wide_cell = Cell{
        .char = 0x4E2D, // 中
        .fg = Color.white,
        .bg = Color.black,
        .attrs = .{},
    };

    // Set wide cell at position 3
    const result = buf.setWideCell(3, 1, wide_cell);
    try std.testing.expect(result);

    // First cell has the character
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(3, 1).char);
    // Second cell is continuation
    try std.testing.expect(buf.getCell(4, 1).isContinuation());
}

test "Buffer setWideCell fails at right edge" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 1 });
    defer buf.deinit();

    const wide_cell = Cell{
        .char = 0x4E2D,
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    // Try to set wide cell at position 4 (final column) - should fail
    const result = buf.setWideCell(4, 0, wide_cell);
    try std.testing.expect(!result);

    // Cell should remain unchanged (default)
    try std.testing.expect(buf.getCell(4, 0).eql(Cell.default));
}

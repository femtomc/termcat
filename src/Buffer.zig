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

/// Resize the buffer to new dimensions, preserving existing content.
/// Content that fits in the new size is copied; areas that don't fit are clipped.
/// New areas (if the buffer grows) are filled with default cells.
/// Wide characters clipped at the right edge are replaced with spaces to maintain
/// the invariant that wide chars always have their continuation cell.
pub fn resizePreserving(self: *Buffer, new_size: Size) !void {
    // Early return if size unchanged
    if (self.width == new_size.width and self.height == new_size.height) {
        return;
    }

    const new_total = @as(usize, new_size.width) * @as(usize, new_size.height);

    // Allocate new cells FIRST to ensure memory safety on failure
    const new_cells = try self.allocator.alloc(Cell, new_total);
    @memset(new_cells, Cell.default);

    // Copy existing content (clipping to overlapping region)
    const copy_width = @min(self.width, new_size.width);
    const copy_height = @min(self.height, new_size.height);

    for (0..copy_height) |y| {
        const old_row_start = y * @as(usize, self.width);
        const new_row_start = y * @as(usize, new_size.width);
        @memcpy(
            new_cells[new_row_start..][0..copy_width],
            self.cells[old_row_start..][0..copy_width],
        );

        // Sanitize the last column if we're shrinking width.
        // A wide char at the last column would have lost its continuation cell,
        // violating the invariant. Replace with a space preserving style.
        if (new_size.width > 0 and new_size.width < self.width) {
            const last_col_idx = new_row_start + @as(usize, new_size.width) - 1;
            const last_cell = new_cells[last_col_idx];
            // Check if it's a wide char lead (non-continuation with width 2)
            if (!last_cell.isContinuation() and unicode.codePointWidth(last_cell.char) == 2) {
                // Replace with space, preserving fg/bg/attrs
                new_cells[last_col_idx] = Cell{
                    .char = ' ',
                    .combining = .{ 0, 0 },
                    .fg = last_cell.fg,
                    .bg = last_cell.bg,
                    .attrs = last_cell.attrs,
                };
            }
        }
    }

    // Free old cells and update state
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

/// Write string starting at position (handles wide chars and combining marks).
/// Characters that extend beyond the right edge are clipped.
/// Wide characters at the final column are replaced with a space.
/// Combining marks (zero-width, non-control) are attached to the previous base character.
/// Control characters (including \n, \t) are skipped as they have special terminal meaning.
/// Invalid UTF-8 sequences are replaced with U+FFFD (replacement character).
pub fn print(self: *Buffer, x: u16, y: u16, str: []const u8, fg: Color, bg: Color, attrs: Attributes) void {
    if (y >= self.height) return;

    var cur_x = x;
    var last_cell_x: ?u16 = null; // Track position of last base character for combining marks
    var i: usize = 0;

    while (i < str.len) {
        if (cur_x >= self.width and last_cell_x == null) break;

        // Decode UTF-8 with error handling
        const decode_result = decodeUtf8(str[i..]);
        const cp = decode_result.codepoint;
        i += decode_result.bytes_consumed;

        const char_width = unicode.codePointWidth(cp);

        if (char_width == 0) {
            // Zero-width character - check if it's a control character or a combining mark
            if (unicode.isCombiningMark(cp)) {
                // Combining mark - attach to previous cell if one exists
                if (last_cell_x) |prev_x| {
                    if (self.index(prev_x, y)) |idx| {
                        // Try to add combining mark to the previous cell
                        _ = self.cells[idx].addCombining(cp);
                        // If all slots are full, the mark is silently dropped (MVP limitation)
                    }
                }
            }
            // Control characters and other zero-width chars (ZWJ, etc.) are skipped
            // They don't consume cells and aren't attached as combining marks
            continue;
        }

        // Beyond right edge - stop processing
        if (cur_x >= self.width) break;

        if (char_width == 2) {
            // Wide character - needs 2 cells
            if (cur_x + 1 >= self.width) {
                // Can't fit wide char at final column - replace with space
                self.setCell(cur_x, y, Cell{
                    .char = ' ',
                    .combining = .{ 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                });
                last_cell_x = cur_x;
                break;
            }
            // First cell: the character
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            // Second cell: continuation marker
            self.setCell(cur_x + 1, y, Cell.continuation(fg, bg, attrs));
            last_cell_x = cur_x;
            cur_x += 2;
        } else {
            // Regular width character (width 1)
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            last_cell_x = cur_x;
            cur_x += 1;
        }
    }
}

/// Decode result for UTF-8 handling
const DecodeResult = struct {
    codepoint: u21,
    bytes_consumed: usize,
};

/// Decode a single UTF-8 codepoint from a byte slice.
/// Returns U+FFFD (replacement character) for invalid sequences.
/// On invalid sequences, consumes only the invalid leading byte to allow resync
/// with subsequent valid bytes.
fn decodeUtf8(bytes: []const u8) DecodeResult {
    if (bytes.len == 0) {
        return .{ .codepoint = 0xFFFD, .bytes_consumed = 0 };
    }

    const first_byte = bytes[0];

    // Determine expected sequence length from first byte
    const seq_len: usize = if (first_byte < 0x80)
        1
    else if (first_byte & 0xE0 == 0xC0)
        2
    else if (first_byte & 0xF0 == 0xE0)
        3
    else if (first_byte & 0xF8 == 0xF0)
        4
    else {
        // Invalid start byte - consume only it and return replacement
        return .{ .codepoint = 0xFFFD, .bytes_consumed = 1 };
    };

    // ASCII is always valid
    if (seq_len == 1) {
        return .{ .codepoint = first_byte, .bytes_consumed = 1 };
    }

    // Check if we have enough bytes and if continuation bytes are valid
    // Valid continuation bytes are 0x80-0xBF (10xxxxxx pattern)
    if (bytes.len < seq_len) {
        // Truncated sequence at end of input - consume remaining bytes
        return .{ .codepoint = 0xFFFD, .bytes_consumed = bytes.len };
    }

    // Validate continuation bytes before decoding
    for (bytes[1..seq_len]) |b| {
        if (b & 0xC0 != 0x80) {
            // Invalid continuation byte - consume only the lead byte to resync
            return .{ .codepoint = 0xFFFD, .bytes_consumed = 1 };
        }
    }

    // All continuation bytes are valid, try to decode
    const result = std.unicode.utf8Decode(bytes[0..seq_len]) catch {
        // Decode failed (e.g., overlong encoding, surrogate) - consume the sequence
        return .{ .codepoint = 0xFFFD, .bytes_consumed = seq_len };
    };

    return .{ .codepoint = result, .bytes_consumed = seq_len };
}

/// Write string starting at position, returning the number of cells consumed.
/// Similar to print() but returns the display width of the printed text.
/// Control characters are skipped, invalid UTF-8 replaced with U+FFFD.
pub fn printLen(self: *Buffer, x: u16, y: u16, str: []const u8, fg: Color, bg: Color, attrs: Attributes) u16 {
    if (y >= self.height) return 0;

    const start_x = x;
    var cur_x = x;
    var last_cell_x: ?u16 = null;
    var i: usize = 0;

    while (i < str.len) {
        if (cur_x >= self.width and last_cell_x == null) break;

        // Decode UTF-8 with error handling
        const decode_result = decodeUtf8(str[i..]);
        const cp = decode_result.codepoint;
        i += decode_result.bytes_consumed;

        const char_width = unicode.codePointWidth(cp);

        if (char_width == 0) {
            // Only attach actual combining marks, not control chars
            if (unicode.isCombiningMark(cp)) {
                if (last_cell_x) |prev_x| {
                    if (self.index(prev_x, y)) |idx| {
                        _ = self.cells[idx].addCombining(cp);
                    }
                }
            }
            continue;
        }

        if (cur_x >= self.width) break;

        if (char_width == 2) {
            if (cur_x + 1 >= self.width) {
                self.setCell(cur_x, y, Cell{
                    .char = ' ',
                    .combining = .{ 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                });
                last_cell_x = cur_x;
                cur_x += 1;
                break;
            }
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            self.setCell(cur_x + 1, y, Cell.continuation(fg, bg, attrs));
            last_cell_x = cur_x;
            cur_x += 2;
        } else {
            self.setCell(cur_x, y, Cell{
                .char = cp,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            last_cell_x = cur_x;
            cur_x += 1;
        }
    }

    return cur_x - start_x;
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

test "Buffer resizePreserving grows buffer" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 3 });
    defer buf.deinit();

    // Set some content
    buf.print(0, 0, "Hello", .default, .default, .{});
    buf.print(0, 1, "World", .default, .default, .{});

    // Grow the buffer
    try buf.resizePreserving(.{ .width = 10, .height = 5 });

    // Check dimensions
    try std.testing.expectEqual(@as(u16, 10), buf.width);
    try std.testing.expectEqual(@as(u16, 5), buf.height);

    // Check original content is preserved
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'W'), buf.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'd'), buf.getCell(4, 1).char);

    // Check new areas are default
    try std.testing.expect(buf.getCell(5, 0).eql(Cell.default));
    try std.testing.expect(buf.getCell(9, 0).eql(Cell.default));
    try std.testing.expect(buf.getCell(0, 3).eql(Cell.default));
    try std.testing.expect(buf.getCell(0, 4).eql(Cell.default));
}

test "Buffer resizePreserving shrinks buffer" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    // Set content that will be clipped
    buf.print(0, 0, "Hello World", .default, .default, .{});
    buf.print(0, 1, "Line 2", .default, .default, .{});
    buf.print(0, 2, "Line 3", .default, .default, .{});
    buf.print(0, 3, "Line 4", .default, .default, .{});
    buf.print(0, 4, "Line 5", .default, .default, .{});

    // Shrink the buffer
    try buf.resizePreserving(.{ .width = 5, .height = 2 });

    // Check dimensions
    try std.testing.expectEqual(@as(u16, 5), buf.width);
    try std.testing.expectEqual(@as(u16, 2), buf.height);

    // Check content is clipped correctly (only first 5 chars of first 2 lines)
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'L'), buf.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), buf.getCell(4, 1).char);
}

test "Buffer resizePreserving same size" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 3 });
    defer buf.deinit();

    // Set content
    buf.print(0, 0, "Test", .default, .default, .{});

    // Resize to same dimensions
    try buf.resizePreserving(.{ .width = 5, .height = 3 });

    // Content should be preserved
    try std.testing.expectEqual(@as(u21, 'T'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 's'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 't'), buf.getCell(3, 0).char);
}

test "Buffer resizePreserving mixed dimensions" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 5 });
    defer buf.deinit();

    // Set content
    buf.print(0, 0, "AAAAA", .default, .default, .{});
    buf.print(0, 1, "BBBBB", .default, .default, .{});
    buf.print(0, 2, "CCCCC", .default, .default, .{});
    buf.print(0, 3, "DDDDD", .default, .default, .{});
    buf.print(0, 4, "EEEEE", .default, .default, .{});

    // Width increases, height decreases
    try buf.resizePreserving(.{ .width = 10, .height = 3 });

    // Check dimensions
    try std.testing.expectEqual(@as(u16, 10), buf.width);
    try std.testing.expectEqual(@as(u16, 3), buf.height);

    // Check preserved content (first 3 rows, first 5 columns)
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(0, 2).char);

    // Check new width area is default
    try std.testing.expect(buf.getCell(5, 0).eql(Cell.default));
    try std.testing.expect(buf.getCell(9, 0).eql(Cell.default));
}

test "Buffer resizePreserving clips wide char at boundary" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 6, .height = 2 });
    defer buf.deinit();

    // Print wide char (width 2) at x=4, occupying x=4 and x=5 (continuation)
    buf.print(4, 0, "中", Color.red, Color.blue, .{ .bold = true });

    // Verify wide char is set correctly
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(4, 0).char);
    try std.testing.expect(buf.getCell(5, 0).isContinuation());

    // Also print a wide char on row 1 at x=3 (occupies x=3 and x=4)
    buf.print(3, 1, "日", Color.green, .default, .{});
    try std.testing.expectEqual(@as(u21, 0x65E5), buf.getCell(3, 1).char);
    try std.testing.expect(buf.getCell(4, 1).isContinuation());

    // Shrink width from 6 to 5, clipping the continuation cell at x=5
    try buf.resizePreserving(.{ .width = 5, .height = 2 });

    // The wide char at x=4 row 0 should be replaced with space (preserving styles)
    try std.testing.expectEqual(@as(u21, ' '), buf.getCell(4, 0).char);
    try std.testing.expect(buf.getCell(4, 0).fg.eql(Color.red));
    try std.testing.expect(buf.getCell(4, 0).bg.eql(Color.blue));
    try std.testing.expect(buf.getCell(4, 0).attrs.bold);
    // Should not be a continuation cell
    try std.testing.expect(!buf.getCell(4, 0).isContinuation());

    // The wide char at x=3 row 1 should still be intact (continuation at x=4)
    try std.testing.expectEqual(@as(u21, 0x65E5), buf.getCell(3, 1).char);
    try std.testing.expect(buf.getCell(4, 1).isContinuation());
}

test "Buffer resizePreserving no-op for same size" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 5, .height = 3 });
    defer buf.deinit();

    buf.print(0, 0, "Test", .default, .default, .{});

    // Get pointer to original cells
    const original_cells = buf.cells.ptr;

    // Resize to same size - should be no-op
    try buf.resizePreserving(.{ .width = 5, .height = 3 });

    // Cells pointer should be unchanged (no reallocation)
    try std.testing.expectEqual(original_cells, buf.cells.ptr);

    // Content should be preserved
    try std.testing.expectEqual(@as(u21, 'T'), buf.getCell(0, 0).char);
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

test "Buffer print attaches combining marks to base character" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print string with combining acute accent (U+0301) - zero width
    // "é" as "e" + combining acute = e + U+0301
    buf.print(0, 0, "e\xCC\x81x", .default, .default, .{}); // e + combining acute + x

    // 'e' at position 0 with combining acute attached
    try std.testing.expectEqual(@as(u21, 'e'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x0301), buf.getCell(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u21, 0), buf.getCell(0, 0).combining[1]);

    // 'x' at position 1 (combining mark didn't consume a cell)
    try std.testing.expectEqual(@as(u21, 'x'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 0), buf.getCell(1, 0).combining[0]);

    // Position 2 should still be default
    try std.testing.expect(buf.getCell(2, 0).eql(Cell.default));
}

test "Buffer print with multiple combining marks" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print "o" + combining acute (U+0301) + combining diaeresis (U+0308)
    buf.print(0, 0, "o\xCC\x81\xCC\x88", .default, .default, .{});

    // 'o' at position 0 with both combining marks
    try std.testing.expectEqual(@as(u21, 'o'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x0301), buf.getCell(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u21, 0x0308), buf.getCell(0, 0).combining[1]);
}

test "Buffer print drops excess combining marks" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print "a" with 3 combining marks (only 2 slots available)
    // U+0301 (acute), U+0308 (diaeresis), U+0327 (cedilla)
    buf.print(0, 0, "a\xCC\x81\xCC\x88\xCC\xA7x", .default, .default, .{});

    // 'a' at position 0 with first two combining marks (third dropped)
    try std.testing.expectEqual(@as(u21, 'a'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x0301), buf.getCell(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u21, 0x0308), buf.getCell(0, 0).combining[1]);

    // 'x' at position 1
    try std.testing.expectEqual(@as(u21, 'x'), buf.getCell(1, 0).char);
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

test "Buffer print skips control characters" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print string with embedded newline and tab - should be skipped
    buf.print(0, 0, "a\nb\tc", .default, .default, .{});

    // Control characters are skipped, so we get "abc" at positions 0, 1, 2
    try std.testing.expectEqual(@as(u21, 'a'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'b'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'c'), buf.getCell(2, 0).char);
    // No combining marks attached from control chars
    try std.testing.expectEqual(@as(u21, 0), buf.getCell(0, 0).combining[0]);
}

test "Buffer print handles invalid UTF-8 with replacement char" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print string with invalid UTF-8 byte (0xFF is never valid in UTF-8)
    buf.print(0, 0, "a\xFFb", .default, .default, .{});

    // 'a' at position 0
    try std.testing.expectEqual(@as(u21, 'a'), buf.getCell(0, 0).char);
    // U+FFFD (replacement char) at position 1 from invalid byte
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.getCell(1, 0).char);
    // 'b' at position 2
    try std.testing.expectEqual(@as(u21, 'b'), buf.getCell(2, 0).char);
}

test "Buffer print handles truncated UTF-8 sequence" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print string with truncated 2-byte sequence (starts with 0xC2 but no continuation)
    buf.print(0, 0, "a\xC2", .default, .default, .{});

    // 'a' at position 0
    try std.testing.expectEqual(@as(u21, 'a'), buf.getCell(0, 0).char);
    // U+FFFD at position 1 from truncated sequence
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.getCell(1, 0).char);
}

test "Buffer print resyncs after invalid continuation byte" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Print "a\xC2b" - 0xC2 expects a continuation byte (0x80-0xBF)
    // but 'b' (0x62) is not a valid continuation, so we should:
    // - Output 'a' at position 0
    // - Output U+FFFD at position 1 (for the invalid 0xC2)
    // - Resync and output 'b' at position 2
    buf.print(0, 0, "a\xC2b", .default, .default, .{});

    try std.testing.expectEqual(@as(u21, 'a'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0xFFFD), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'b'), buf.getCell(2, 0).char);
}

test "Buffer print does not panic on various invalid UTF-8" {
    var buf = try Buffer.init(std.testing.allocator, .{ .width = 20, .height = 5 });
    defer buf.deinit();

    // Various invalid UTF-8 sequences that should NOT cause a panic
    // Overlong encoding
    buf.print(0, 0, "\xC0\x80", .default, .default, .{});
    // Invalid continuation byte
    buf.print(0, 1, "\xE0\x80\x80", .default, .default, .{});
    // Surrogate halves
    buf.print(0, 2, "\xED\xA0\x80", .default, .default, .{});
    // Random invalid bytes
    buf.print(0, 3, "\xFE\xFF", .default, .default, .{});

    // If we get here without panic, the test passes
    // The exact output doesn't matter, just that we didn't crash
}

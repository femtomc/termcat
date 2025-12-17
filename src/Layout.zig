const std = @import("std");
const Cell = @import("Cell.zig");
const Buffer = @import("Buffer.zig");
const Event = @import("Event.zig");
const unicode = @import("unicode/width.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;
const Rect = Event.Rect;

/// Text alignment options
pub const Alignment = enum {
    left,
    center,
    right,
};

/// Box drawing style using Unicode box-drawing characters
pub const BoxStyle = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,

    /// Light box drawing (─ │ ┌ ┐ └ ┘)
    pub const light: BoxStyle = .{
        .horizontal = '─',
        .vertical = '│',
        .top_left = '┌',
        .top_right = '┐',
        .bottom_left = '└',
        .bottom_right = '┘',
    };

    /// Heavy box drawing (━ ┃ ┏ ┓ ┗ ┛)
    pub const heavy: BoxStyle = .{
        .horizontal = '━',
        .vertical = '┃',
        .top_left = '┏',
        .top_right = '┓',
        .bottom_left = '┗',
        .bottom_right = '┛',
    };

    /// Double-line box drawing (═ ║ ╔ ╗ ╚ ╝)
    pub const double: BoxStyle = .{
        .horizontal = '═',
        .vertical = '║',
        .top_left = '╔',
        .top_right = '╗',
        .bottom_left = '╚',
        .bottom_right = '╝',
    };

    /// Rounded corners (─ │ ╭ ╮ ╰ ╯)
    pub const rounded: BoxStyle = .{
        .horizontal = '─',
        .vertical = '│',
        .top_left = '╭',
        .top_right = '╮',
        .bottom_left = '╰',
        .bottom_right = '╯',
    };

    /// ASCII box drawing (- | + + + +)
    pub const ascii: BoxStyle = .{
        .horizontal = '-',
        .vertical = '|',
        .top_left = '+',
        .top_right = '+',
        .bottom_left = '+',
        .bottom_right = '+',
    };
};

/// Word wrapping mode
pub const WrapMode = enum {
    /// No wrapping - text is clipped at width boundary
    none,
    /// Wrap at character boundary (may break words)
    char,
    /// Wrap at word boundary (spaces) when possible
    word,
};

/// Draw a box outline on the buffer.
/// The box is drawn at the given rect with the specified style.
/// The interior of the box is NOT cleared.
pub fn drawBox(
    buffer: *Buffer,
    rect: Rect,
    style: BoxStyle,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) void {
    // Need at least 2x2 for a box
    if (rect.width < 2 or rect.height < 2) return;

    const x1 = rect.x;
    const y1 = rect.y;
    const x2 = rect.x +| rect.width -| 1;
    const y2 = rect.y +| rect.height -| 1;

    // Corners
    buffer.setCell(x1, y1, makeCell(style.top_left, fg, bg, attrs));
    buffer.setCell(x2, y1, makeCell(style.top_right, fg, bg, attrs));
    buffer.setCell(x1, y2, makeCell(style.bottom_left, fg, bg, attrs));
    buffer.setCell(x2, y2, makeCell(style.bottom_right, fg, bg, attrs));

    // Horizontal lines
    if (x2 > x1 +| 1) {
        var x = x1 +| 1;
        while (x < x2) : (x +|= 1) {
            buffer.setCell(x, y1, makeCell(style.horizontal, fg, bg, attrs));
            buffer.setCell(x, y2, makeCell(style.horizontal, fg, bg, attrs));
        }
    }

    // Vertical lines
    if (y2 > y1 +| 1) {
        var y = y1 +| 1;
        while (y < y2) : (y +|= 1) {
            buffer.setCell(x1, y, makeCell(style.vertical, fg, bg, attrs));
            buffer.setCell(x2, y, makeCell(style.vertical, fg, bg, attrs));
        }
    }
}

/// Draw a horizontal line.
pub fn drawHLine(
    buffer: *Buffer,
    x: u16,
    y: u16,
    length: u16,
    char: u21,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) void {
    const cell = makeCell(char, fg, bg, attrs);
    var i: u16 = 0;
    while (i < length) : (i +|= 1) {
        buffer.setCell(x +| i, y, cell);
    }
}

/// Draw a vertical line.
pub fn drawVLine(
    buffer: *Buffer,
    x: u16,
    y: u16,
    length: u16,
    char: u21,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) void {
    const cell = makeCell(char, fg, bg, attrs);
    var i: u16 = 0;
    while (i < length) : (i +|= 1) {
        buffer.setCell(x, y +| i, cell);
    }
}

/// Print text with alignment within a given width.
/// Returns the number of cells consumed.
pub fn printAligned(
    buffer: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    text: []const u8,
    alignment: Alignment,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) u16 {
    if (width == 0 or y >= buffer.height) return 0;

    const text_width: u16 = @intCast(@min(unicode.stringWidth(text), std.math.maxInt(u16)));

    // Calculate starting x position based on alignment
    const offset: u16 = switch (alignment) {
        .left => 0,
        .center => (width -| text_width) / 2,
        .right => width -| text_width,
    };

    buffer.print(x +| offset, y, text, fg, bg, attrs);
    return @min(text_width, width);
}

/// Print text with word wrapping, returning the number of lines used.
/// The text is wrapped to fit within the specified width.
/// Returns the number of rows consumed (useful for knowing how much space was used).
pub fn printWrapped(
    buffer: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    max_height: u16,
    text: []const u8,
    mode: WrapMode,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) u16 {
    if (width == 0 or max_height == 0) return 0;

    return switch (mode) {
        .none => blk: {
            buffer.print(x, y, text, fg, bg, attrs);
            break :blk 1;
        },
        .char => printWrapChar(buffer, x, y, width, max_height, text, fg, bg, attrs),
        .word => printWrapWord(buffer, x, y, width, max_height, text, fg, bg, attrs),
    };
}

/// Result of character wrapping with position tracking
const WrapCharResult = struct {
    rows_used: u16,
    final_col: u16,
};

/// Character-based wrapping implementation
fn printWrapChar(
    buffer: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    max_height: u16,
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) u16 {
    return printWrapCharWithPos(buffer, x, y, width, max_height, text, fg, bg, attrs).rows_used;
}

/// Character-based wrapping implementation that returns final cursor position
fn printWrapCharWithPos(
    buffer: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    max_height: u16,
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) WrapCharResult {
    var row: u16 = 0;
    var col: u16 = 0;
    var i: usize = 0;
    var lines_used: u16 = 0;
    // Track the position of the last base character for combining marks
    var last_base_x: u16 = 0;
    var last_base_y: u16 = 0;
    var has_last_base: bool = false;

    while (i < text.len and row < max_height) {
        const decode = decodeUtf8(text[i..]);
        const cp = decode.codepoint;
        i += decode.bytes_consumed;

        // Handle newlines explicitly
        if (cp == '\n') {
            if (col > 0 or lines_used > 0) lines_used = row + 1;
            row += 1;
            col = 0;
            has_last_base = false;
            continue;
        }

        // Skip other control characters
        if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) {
            continue;
        }

        const char_width: u16 = unicode.codePointWidth(cp);

        // Combining marks attach to previous base character, don't advance
        if (char_width == 0 and unicode.isCombiningMark(cp)) {
            if (has_last_base) {
                // Attach to the tracked base character position
                var prev_cell = buffer.getCell(last_base_x, last_base_y);
                if (!prev_cell.eql(Cell.default)) {
                    _ = prev_cell.addCombining(cp);
                    buffer.setCell(last_base_x, last_base_y, prev_cell);
                }
            }
            continue;
        }

        // Handle wide characters at edge - can't fit fully, put space and wrap
        // This check must come BEFORE the general wrap check to place the space
        if (char_width == 2 and col +| 1 >= width and col < width) {
            // Wide char needs 2 cells but only 1 remains - place space at edge
            buffer.setCell(x +| col, y +| row, makeCell(' ', fg, bg, attrs));
            last_base_x = x +| col;
            last_base_y = y +| row;
            has_last_base = true;
            lines_used = row +| 1;
            row +|= 1;
            col = 0;
            if (row >= max_height) break;
            // Continue to print the wide char on the new line below
        }

        // Wrap if this character doesn't fit
        if (col +| char_width > width) {
            row +|= 1;
            col = 0;
            if (row >= max_height) break;
        }

        // Print the character
        if (char_width == 2) {
            buffer.setCell(x +| col, y +| row, makeCell(cp, fg, bg, attrs));
            buffer.setCell(x +| (col +| 1), y +| row, Cell.continuation(fg, bg, attrs));
            last_base_x = x +| col;
            last_base_y = y +| row;
            has_last_base = true;
            col +|= 2;
        } else if (char_width == 1) {
            buffer.setCell(x +| col, y +| row, makeCell(cp, fg, bg, attrs));
            last_base_x = x +| col;
            last_base_y = y +| row;
            has_last_base = true;
            col +|= 1;
        }

        // Update lines_used to reflect that we wrote to this row
        lines_used = row + 1;
    }

    const final_rows = if (lines_used > 0) lines_used else 1;
    return .{ .rows_used = final_rows, .final_col = col };
}

/// Word-based wrapping implementation
fn printWrapWord(
    buffer: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    max_height: u16,
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) u16 {
    var row: u16 = 0;
    var col: u16 = 0;
    var i: usize = 0;
    var lines_used: u16 = 0;

    while (i < text.len and row < max_height) {
        // Handle newlines
        if (text[i] == '\n') {
            if (col > 0 or lines_used > 0) lines_used = row +| 1;
            row +|= 1;
            col = 0;
            i += 1;
            continue;
        }

        // Skip leading spaces at start of line (except first)
        if (col == 0 and row > 0 and text[i] == ' ') {
            i += 1;
            continue;
        }

        // Find the next word
        const word_result = findNextWord(text[i..]);
        const word = word_result.word;
        const bytes_consumed = word_result.bytes_consumed;
        const word_width: u16 = @intCast(@min(unicode.stringWidth(word), std.math.maxInt(u16)));

        // Empty word means we hit end or just newlines/spaces
        if (word.len == 0) {
            i += bytes_consumed;
            continue;
        }

        // If word doesn't fit on current line, wrap
        if (col > 0 and col +| word_width > width) {
            row +|= 1;
            col = 0;
            if (row >= max_height) break;
        }

        // If word is longer than width, use character wrapping for this word
        if (word_width > width) {
            // For long words, we always start at column 0 of current/next row
            if (col > 0) {
                row +|= 1;
                col = 0;
                if (row >= max_height) break;
            }
            // Now wrap the long word starting at full width
            const result = printWrapCharWithPos(buffer, x, y +| row, width, max_height -| row, word, fg, bg, attrs);
            row +|= result.rows_used -| 1;
            col = result.final_col;
            i += bytes_consumed;
            lines_used = row +| 1;
            continue;
        }

        // Print the word
        buffer.print(x +| col, y +| row, word, fg, bg, attrs);
        col +|= word_width;
        i += bytes_consumed;
        lines_used = row +| 1;

        // Print trailing space if there is one and room
        if (i < text.len and text[i] == ' ') {
            if (col < width) {
                buffer.setCell(x +| col, y +| row, makeCell(' ', fg, bg, attrs));
                col +|= 1;
            }
            i += 1;
        }
    }

    return if (lines_used > 0) lines_used else 1;
}

/// Find the next word (sequence of non-space characters)
/// Returns the word slice, remaining text, and total bytes consumed (including skipped spaces)
fn findNextWord(text: []const u8) struct { word: []const u8, rest: []const u8, bytes_consumed: usize } {
    // Skip leading spaces
    var start: usize = 0;
    while (start < text.len and text[start] == ' ') : (start += 1) {}

    // Find end of word (up to space or newline)
    var end = start;
    while (end < text.len and text[end] != ' ' and text[end] != '\n') : (end += 1) {}

    return .{
        .word = text[start..end],
        .rest = text[end..],
        .bytes_consumed = end,
    };
}

/// Helper to create a cell
fn makeCell(char: u21, fg: Color, bg: Color, attrs: Attributes) Cell {
    return .{
        .char = char,
        .combining = .{ 0, 0 },
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

/// Decode a single UTF-8 codepoint from a byte slice.
fn decodeUtf8(bytes: []const u8) struct { codepoint: u21, bytes_consumed: usize } {
    if (bytes.len == 0) {
        return .{ .codepoint = 0xFFFD, .bytes_consumed = 0 };
    }

    const first_byte = bytes[0];

    const seq_len: usize = if (first_byte < 0x80)
        1
    else if (first_byte & 0xE0 == 0xC0)
        2
    else if (first_byte & 0xF0 == 0xE0)
        3
    else if (first_byte & 0xF8 == 0xF0)
        4
    else {
        return .{ .codepoint = 0xFFFD, .bytes_consumed = 1 };
    };

    if (seq_len == 1) {
        return .{ .codepoint = first_byte, .bytes_consumed = 1 };
    }

    if (bytes.len < seq_len) {
        return .{ .codepoint = 0xFFFD, .bytes_consumed = bytes.len };
    }

    for (bytes[1..seq_len]) |b| {
        if (b & 0xC0 != 0x80) {
            return .{ .codepoint = 0xFFFD, .bytes_consumed = 1 };
        }
    }

    const result = std.unicode.utf8Decode(bytes[0..seq_len]) catch {
        return .{ .codepoint = 0xFFFD, .bytes_consumed = seq_len };
    };

    return .{ .codepoint = result, .bytes_consumed = seq_len };
}

// ============================================================================
// Tests
// ============================================================================

test "drawBox light style" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 5, .height = 3 }, BoxStyle.light, .default, .default, .{});

    // Check corners
    try std.testing.expectEqual(@as(u21, '┌'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '┐'), buffer.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, '└'), buffer.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, '┘'), buffer.getCell(4, 2).char);

    // Check horizontal lines
    try std.testing.expectEqual(@as(u21, '─'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '─'), buffer.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, '─'), buffer.getCell(3, 0).char);

    // Check vertical lines
    try std.testing.expectEqual(@as(u21, '│'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, '│'), buffer.getCell(4, 1).char);
}

test "drawBox heavy style" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawBox(&buffer, .{ .x = 1, .y = 1, .width = 4, .height = 3 }, BoxStyle.heavy, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, '┏'), buffer.getCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, '┓'), buffer.getCell(4, 1).char);
    try std.testing.expectEqual(@as(u21, '┗'), buffer.getCell(1, 3).char);
    try std.testing.expectEqual(@as(u21, '┛'), buffer.getCell(4, 3).char);
    try std.testing.expectEqual(@as(u21, '━'), buffer.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, '┃'), buffer.getCell(1, 2).char);
}

test "drawBox minimum size" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    // 2x2 is minimum valid box
    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, BoxStyle.light, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, '┌'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '┐'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '└'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, '┘'), buffer.getCell(1, 1).char);
}

test "drawBox too small does nothing" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    // 1x1 is too small - should do nothing
    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, BoxStyle.light, .default, .default, .{});

    try std.testing.expect(buffer.getCell(0, 0).eql(Cell.default));
}

test "drawHLine" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawHLine(&buffer, 2, 1, 5, '=', Color.red, .default, .{});

    try std.testing.expectEqual(@as(u21, '='), buffer.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, '='), buffer.getCell(6, 1).char);
    try std.testing.expect(buffer.getCell(1, 1).eql(Cell.default));
    try std.testing.expect(buffer.getCell(7, 1).eql(Cell.default));
}

test "drawVLine" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawVLine(&buffer, 3, 0, 4, '|', .default, Color.blue, .{});

    try std.testing.expectEqual(@as(u21, '|'), buffer.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, '|'), buffer.getCell(3, 3).char);
    try std.testing.expect(buffer.getCell(3, 4).eql(Cell.default));
}

test "printAligned left" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    _ = printAligned(&buffer, 0, 0, 10, "Hi", .left, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), buffer.getCell(1, 0).char);
}

test "printAligned center" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    _ = printAligned(&buffer, 0, 0, 10, "Hi", .center, .default, .default, .{});

    // "Hi" is 2 chars, centered in 10 means offset of 4
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), buffer.getCell(5, 0).char);
}

test "printAligned right" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    _ = printAligned(&buffer, 0, 0, 10, "Hi", .right, .default, .default, .{});

    // "Hi" is 2 chars, right-aligned in 10 means offset of 8
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(8, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), buffer.getCell(9, 0).char);
}

test "printWrapped no wrap" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    const lines = printWrapped(&buffer, 0, 0, 10, 5, "Hello", .none, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 1), lines);
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buffer.getCell(4, 0).char);
}

test "printWrapped char wrap" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    const lines = printWrapped(&buffer, 0, 0, 5, 5, "HelloWorld", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    // First line: "Hello"
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buffer.getCell(4, 0).char);
    // Second line: "World"
    try std.testing.expectEqual(@as(u21, 'W'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'd'), buffer.getCell(4, 1).char);
}

test "printWrapped word wrap" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    const lines = printWrapped(&buffer, 0, 0, 6, 5, "Hi there", .word, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    // First line: "Hi" (width 2)
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), buffer.getCell(1, 0).char);
    // Second line: "there" (width 5)
    try std.testing.expectEqual(@as(u21, 't'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), buffer.getCell(4, 1).char);
}

test "printWrapped respects max_height" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    const lines = printWrapped(&buffer, 0, 0, 3, 2, "ABCDEFGHI", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    // Only 2 lines should be written
    try std.testing.expectEqual(@as(u21, 'A'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), buffer.getCell(0, 1).char);
    // Third line should NOT be written
    try std.testing.expect(buffer.getCell(0, 2).eql(Cell.default));
}

test "printWrapped handles newlines" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    const lines = printWrapped(&buffer, 0, 0, 10, 5, "Hi\nWorld", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'W'), buffer.getCell(0, 1).char);
}

test "printWrapped with wide characters" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    // "中文" = 4 display cells, wrap at width 3 should split across lines
    const lines = printWrapped(&buffer, 0, 0, 3, 5, "中文", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    // First character on first line
    try std.testing.expectEqual(@as(u21, '中'), buffer.getCell(0, 0).char);
    // Second character on second line
    try std.testing.expectEqual(@as(u21, '文'), buffer.getCell(0, 1).char);
}

test "findNextWord" {
    const result1 = findNextWord("hello world");
    try std.testing.expectEqualStrings("hello", result1.word);
    try std.testing.expectEqual(@as(usize, 5), result1.bytes_consumed);

    const result2 = findNextWord("  hello");
    try std.testing.expectEqualStrings("hello", result2.word);
    // bytes_consumed includes the 2 leading spaces + 5 for "hello"
    try std.testing.expectEqual(@as(usize, 7), result2.bytes_consumed);

    const result3 = findNextWord("hello\nworld");
    try std.testing.expectEqualStrings("hello", result3.word);
    try std.testing.expectEqual(@as(usize, 5), result3.bytes_consumed);

    const result4 = findNextWord("");
    try std.testing.expectEqualStrings("", result4.word);
    try std.testing.expectEqual(@as(usize, 0), result4.bytes_consumed);
}

test "BoxStyle double" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 4, .height = 3 }, BoxStyle.double, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, '╔'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '╗'), buffer.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, '╚'), buffer.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, '╝'), buffer.getCell(3, 2).char);
    try std.testing.expectEqual(@as(u21, '═'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '║'), buffer.getCell(0, 1).char);
}

test "BoxStyle rounded" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 4, .height = 3 }, BoxStyle.rounded, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, '╭'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '╮'), buffer.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, '╰'), buffer.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, '╯'), buffer.getCell(3, 2).char);
}

test "BoxStyle ascii" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buffer.deinit();

    drawBox(&buffer, .{ .x = 0, .y = 0, .width = 4, .height = 3 }, BoxStyle.ascii, .default, .default, .{});

    try std.testing.expectEqual(@as(u21, '+'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '+'), buffer.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, '-'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '|'), buffer.getCell(0, 1).char);
}

test "printWrapped word wrap with long word" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    // Word "superlongword" is 13 chars, width is 5, should char-wrap
    const lines = printWrapped(&buffer, 0, 0, 5, 5, "Hi superlongword!", .word, .default, .default, .{});

    // "Hi" on line 0, "super" on line 1, "longw" on line 2, "ord!" on line 3
    try std.testing.expectEqual(@as(u16, 4), lines);
    try std.testing.expectEqual(@as(u21, 'H'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 's'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'l'), buffer.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'o'), buffer.getCell(0, 3).char);
}

test "printWrapped word wrap with spaces" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    // Test that leading spaces after wrap are handled correctly
    const lines = printWrapped(&buffer, 0, 0, 4, 5, "ab   cd", .word, .default, .default, .{});

    // "ab" fits, then "cd" on next line (spaces skipped after wrap)
    try std.testing.expectEqual(@as(u16, 2), lines);
    try std.testing.expectEqual(@as(u21, 'a'), buffer.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'b'), buffer.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'c'), buffer.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'd'), buffer.getCell(1, 1).char);
}

test "printWrapped combining marks after wide char" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer buffer.deinit();

    // Print wide char followed by combining mark (should attach to wide char, not continuation)
    // "中" (wide) + combining acute accent
    const lines = printWrapped(&buffer, 0, 0, 10, 5, "中\xCC\x81x", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 1), lines);
    // Wide char at position 0
    try std.testing.expectEqual(@as(u21, '中'), buffer.getCell(0, 0).char);
    // Combining mark should be attached to the wide char cell (position 0), not the continuation
    try std.testing.expectEqual(@as(u21, 0x0301), buffer.getCell(0, 0).combining[0]);
    // Continuation at position 1 should have no combining marks
    try std.testing.expect(buffer.getCell(1, 0).isContinuation());
    // 'x' at position 2
    try std.testing.expectEqual(@as(u21, 'x'), buffer.getCell(2, 0).char);
}

test "printWrapped wide char at edge wraps correctly" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .{ .width = 4, .height = 5 });
    defer buffer.deinit();

    // Width 3, with "aa中b": 'a' at col 0, 'a' at col 1, wide char at col 2 needs col 2 and 3
    // But width is only 3 so col 3 doesn't exist - should put space at col 2 and wrap
    const lines = printWrapped(&buffer, 0, 0, 3, 5, "aa中b", .char, .default, .default, .{});

    try std.testing.expectEqual(@as(u16, 2), lines);
    // 'a' at position 0
    try std.testing.expectEqual(@as(u21, 'a'), buffer.getCell(0, 0).char);
    // 'a' at position 1
    try std.testing.expectEqual(@as(u21, 'a'), buffer.getCell(1, 0).char);
    // Space at position 2 (wide char can't fit - would need col 2 AND col 3)
    try std.testing.expectEqual(@as(u21, ' '), buffer.getCell(2, 0).char);
    // Wide char wrapped to next line at position 0
    try std.testing.expectEqual(@as(u21, '中'), buffer.getCell(0, 1).char);
    // continuation at position 1
    try std.testing.expect(buffer.getCell(1, 1).isContinuation());
    // 'b' after wide char
    try std.testing.expectEqual(@as(u21, 'b'), buffer.getCell(2, 1).char);
}

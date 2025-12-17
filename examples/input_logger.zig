const std = @import("std");
const termcat = @import("termcat");

/// Input Logger Example
///
/// This example demonstrates termcat's input handling capabilities:
/// - Key press events with modifier detection
/// - Mouse events (click, wheel, motion)
/// - Terminal resize events
/// - Focus in/out events
/// - Bracketed paste events
///
/// Press 'q' or Ctrl+C to exit.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the terminal backend
    var backend = try termcat.PosixBackend.init(allocator, .{
        .enable_mouse = true,
        .enable_bracketed_paste = true,
        .enable_focus_events = true,
        .enable_signals = true,
    });
    defer backend.deinit();

    // Create a renderer for display
    const size = backend.getSize();
    var renderer = try termcat.Renderer.init(allocator, size, backend.capabilities.color_depth);
    defer renderer.deinit();

    // Display header
    const buf = renderer.buffer();
    buf.print(0, 0, "termcat Input Logger - Press 'q' or Ctrl+C to exit", termcat.Color.bright_white, termcat.Color.default, .{ .bold = true });
    buf.print(0, 1, "Terminal size: ", termcat.Color.default, termcat.Color.default, .{});
    printSize(buf, 15, 1, size);
    buf.print(0, 2, "Color depth: ", termcat.Color.default, termcat.Color.default, .{});
    buf.print(13, 2, @tagName(backend.capabilities.color_depth), termcat.Color.cyan, termcat.Color.default, .{});

    const divider = "=" ** 60;
    buf.print(0, 4, divider, termcat.Color.white, termcat.Color.default, .{});
    buf.print(0, 5, "Events:", termcat.Color.bright_yellow, termcat.Color.default, .{});

    try renderer.flush(backend.writer());
    try backend.flushOutput();

    var event_row: u16 = 6;
    var max_event_row: u16 = size.height -| 2;
    var current_size = size;

    // Event loop
    while (true) {
        const event = try backend.pollEvent(null);

        if (event) |ev| {
            // Clear event display area if we've scrolled too far
            if (event_row >= max_event_row) {
                var y: u16 = 6;
                while (y < current_size.height) : (y += 1) {
                    buf.fill(.{ .x = 0, .y = y, .width = current_size.width, .height = 1 }, termcat.Cell.default);
                }
                event_row = 6;
            }

            // Display the event
            switch (ev) {
                .key => |key| {
                    if (isQuitKey(key)) {
                        return;
                    }
                    printKeyEvent(buf, 0, event_row, key);
                },
                .mouse => |mouse| {
                    printMouseEvent(buf, 0, event_row, mouse);
                },
                .resize => |new_size| {
                    try renderer.resize(new_size);
                    current_size = new_size;
                    max_event_row = new_size.height -| 2;
                    // Reset event row if it's now past the new max
                    if (event_row >= max_event_row) {
                        event_row = 6;
                    }
                    // Redraw header
                    buf.print(0, 0, "termcat Input Logger - Press 'q' or Ctrl+C to exit", termcat.Color.bright_white, termcat.Color.default, .{ .bold = true });
                    buf.print(0, 1, "Terminal size: ", termcat.Color.default, termcat.Color.default, .{});
                    printSize(buf, 15, 1, new_size);
                    buf.print(0, 4, divider, termcat.Color.white, termcat.Color.default, .{});
                    buf.print(0, 5, "Events:", termcat.Color.bright_yellow, termcat.Color.default, .{});
                    buf.print(0, event_row, "RESIZE: ", termcat.Color.green, termcat.Color.default, .{});
                    printSize(buf, 8, event_row, new_size);
                },
                .paste => |text| {
                    buf.print(0, event_row, "PASTE: ", termcat.Color.magenta, termcat.Color.default, .{});
                    // Truncate paste text for display
                    const display_len = @min(text.len, 40);
                    buf.print(7, event_row, text[0..display_len], termcat.Color.white, termcat.Color.default, .{});
                    if (text.len > 40) {
                        buf.print(47, event_row, "...", termcat.Color.white, termcat.Color.default, .{});
                    }
                },
                .focus => |focused| {
                    buf.print(0, event_row, "FOCUS: ", termcat.Color.yellow, termcat.Color.default, .{});
                    buf.print(7, event_row, if (focused) "gained" else "lost", termcat.Color.white, termcat.Color.default, .{});
                },
            }

            event_row += 1;

            // Render
            try renderer.flush(backend.writer());
            try backend.flushOutput();
        }
    }
}

fn isQuitKey(key: termcat.Key) bool {
    // 'q' without modifiers
    if (key.codepoint) |cp| {
        if (cp == 'q' and !key.mods.ctrl and !key.mods.alt) {
            return true;
        }
        // Ctrl+C
        if (cp == 'c' and key.mods.ctrl) {
            return true;
        }
    }
    return false;
}

fn printKeyEvent(buf: *termcat.Buffer, x: u16, y: u16, key: termcat.Key) void {
    var cur_x = x;
    buf.print(cur_x, y, "KEY: ", termcat.Color.blue, termcat.Color.default, .{});
    cur_x += 5;

    // Print modifiers
    if (key.mods.ctrl) {
        buf.print(cur_x, y, "Ctrl+", termcat.Color.cyan, termcat.Color.default, .{});
        cur_x += 5;
    }
    if (key.mods.alt) {
        buf.print(cur_x, y, "Alt+", termcat.Color.cyan, termcat.Color.default, .{});
        cur_x += 4;
    }
    if (key.mods.shift) {
        buf.print(cur_x, y, "Shift+", termcat.Color.cyan, termcat.Color.default, .{});
        cur_x += 6;
    }

    // Print key
    if (key.codepoint) |cp| {
        var char_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &char_buf) catch 1;
        buf.print(cur_x, y, char_buf[0..len], termcat.Color.white, termcat.Color.default, .{});
    } else if (key.special) |sp| {
        buf.print(cur_x, y, @tagName(sp), termcat.Color.white, termcat.Color.default, .{});
    }
}

fn printMouseEvent(buf: *termcat.Buffer, x: u16, y: u16, mouse: termcat.Mouse) void {
    var cur_x = x;
    buf.print(cur_x, y, "MOUSE: ", termcat.Color.red, termcat.Color.default, .{});
    cur_x += 7;

    // Print button
    buf.print(cur_x, y, @tagName(mouse.button), termcat.Color.white, termcat.Color.default, .{});
    cur_x += @as(u16, @intCast(@tagName(mouse.button).len)) + 1;

    // Print position
    buf.print(cur_x, y, "at (", termcat.Color.default, termcat.Color.default, .{});
    cur_x += 4;

    var num_buf: [8]u8 = undefined;
    const x_str = std.fmt.bufPrint(&num_buf, "{d}", .{mouse.x}) catch "?";
    buf.print(cur_x, y, x_str, termcat.Color.yellow, termcat.Color.default, .{});
    cur_x += @as(u16, @intCast(x_str.len));

    buf.print(cur_x, y, ", ", termcat.Color.default, termcat.Color.default, .{});
    cur_x += 2;

    const y_str = std.fmt.bufPrint(&num_buf, "{d}", .{mouse.y}) catch "?";
    buf.print(cur_x, y, y_str, termcat.Color.yellow, termcat.Color.default, .{});
    cur_x += @as(u16, @intCast(y_str.len));

    buf.print(cur_x, y, ")", termcat.Color.default, termcat.Color.default, .{});
}

fn printSize(buf: *termcat.Buffer, x: u16, y: u16, size: termcat.Size) void {
    var num_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&num_buf, "{d}x{d}", .{ size.width, size.height }) catch "?x?";
    buf.print(x, y, size_str, termcat.Color.yellow, termcat.Color.default, .{});
}

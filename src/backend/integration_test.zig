const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const Decoder = @import("../input/decoder.zig");
const Input = @import("../input/Input.zig").Input;
const Event = @import("../Event.zig");
const Renderer = @import("../Renderer.zig");
const Buffer = @import("../Buffer.zig");
const Cell = @import("../Cell.zig");

// =============================================================================
// PTY Integration Tests
// =============================================================================
// These tests verify termcat components work correctly through a PTY interface,
// simulating real terminal behavior.

/// Test helper: Set PTY slave to raw mode
fn setRawMode(fd: posix.fd_t) !posix.termios {
    var attr = try posix.tcgetattr(fd);
    const orig = attr;

    // Input flags
    attr.iflag.BRKINT = false;
    attr.iflag.ICRNL = false;
    attr.iflag.INPCK = false;
    attr.iflag.ISTRIP = false;
    attr.iflag.IXON = false;

    // Output flags
    attr.oflag.OPOST = false;

    // Control flags
    attr.cflag.CSIZE = .CS8;
    attr.cflag.PARENB = false;

    // Local flags
    attr.lflag.ECHO = false;
    attr.lflag.ICANON = false;
    attr.lflag.IEXTEN = false;
    attr.lflag.ISIG = false;

    // Non-blocking read
    attr.cc[@intFromEnum(posix.V.MIN)] = 0;
    attr.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, attr);
    return orig;
}

/// Test helper: Restore terminal mode
fn restoreMode(fd: posix.fd_t, orig: posix.termios) void {
    posix.tcsetattr(fd, .FLUSH, orig) catch {};
}

/// Test helper: Write and read through PTY
fn ptyRoundtrip(pty: Pty, data: []const u8, buf: []u8) !usize {
    try pty.writeInput(data);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    return pty.readOutput(buf);
}

// =============================================================================
// Raw Mode Init/Restore Tests
// =============================================================================

test "PTY raw mode init and restore" {
    const pty = try Pty.open();
    defer pty.close();

    // Get original attributes
    const orig_attr = try posix.tcgetattr(pty.slave);

    // Enter raw mode
    const saved = try setRawMode(pty.slave);

    // Verify raw mode settings
    const raw_attr = try posix.tcgetattr(pty.slave);
    try std.testing.expect(!raw_attr.lflag.ECHO);
    try std.testing.expect(!raw_attr.lflag.ICANON);
    try std.testing.expect(!raw_attr.iflag.ICRNL);

    // Restore original mode
    restoreMode(pty.slave, saved);

    // Verify restoration
    const restored_attr = try posix.tcgetattr(pty.slave);
    try std.testing.expectEqual(orig_attr.lflag.ECHO, restored_attr.lflag.ECHO);
    try std.testing.expectEqual(orig_attr.lflag.ICANON, restored_attr.lflag.ICANON);
}

test "PTY mode survives multiple transitions" {
    const pty = try Pty.open();
    defer pty.close();

    const orig = try posix.tcgetattr(pty.slave);

    // Multiple raw/cooked cycles
    for (0..5) |_| {
        const saved = try setRawMode(pty.slave);
        restoreMode(pty.slave, saved);
    }

    // Should match original
    const final = try posix.tcgetattr(pty.slave);
    try std.testing.expectEqual(orig.lflag.ECHO, final.lflag.ECHO);
}

// =============================================================================
// Resize Propagation Tests
// =============================================================================

test "PTY resize propagation" {
    const pty = try Pty.open();
    defer pty.close();

    // Set various sizes and verify
    const test_sizes = [_]struct { w: u16, h: u16 }{
        .{ .w = 80, .h = 24 },
        .{ .w = 120, .h = 40 },
        .{ .w = 40, .h = 10 },
        .{ .w = 200, .h = 60 },
    };

    for (test_sizes) |sz| {
        try pty.setSize(sz.w, sz.h);
        const actual = try pty.getSize();
        try std.testing.expectEqual(sz.w, actual.width);
        try std.testing.expectEqual(sz.h, actual.height);
    }
}

// =============================================================================
// Input Decoding Tests (via PTY)
// =============================================================================

test "PTY decode arrow keys via escape sequences" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Write arrow key sequences to PTY master
    // Then read from slave and decode
    const sequences = [_]struct { seq: []const u8, expected: Event.Key.Special }{
        .{ .seq = "\x1b[A", .expected = .up },
        .{ .seq = "\x1b[B", .expected = .down },
        .{ .seq = "\x1b[C", .expected = .right },
        .{ .seq = "\x1b[D", .expected = .left },
    };

    for (sequences) |test_case| {
        try pty.writeInput(test_case.seq);
        std.Thread.sleep(10 * std.time.ns_per_ms);

        var buf: [64]u8 = undefined;
        const n = posix.read(pty.slave, &buf) catch 0;

        // Decode the sequence
        var last_event: ?Event.Event = null;
        for (buf[0..n]) |byte| {
            const result = try decoder.feed(byte);
            if (result == .event) {
                last_event = result.event;
            }
        }

        try std.testing.expect(last_event != null);
        try std.testing.expect(last_event.?.key.special == test_case.expected);
    }
}

test "PTY decode mouse events via SGR sequences" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // SGR mouse: ESC [ < button ; x ; y M (press) or m (release)
    // Left click at (10, 20): ESC [ < 0 ; 10 ; 20 M
    try pty.writeInput("\x1b[<0;10;20M");
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var buf: [64]u8 = undefined;
    const n = posix.read(pty.slave, &buf) catch 0;

    var mouse_event: ?Event.Mouse = null;
    for (buf[0..n]) |byte| {
        const result = try decoder.feed(byte);
        if (result == .event and result.event == .mouse) {
            mouse_event = result.event.mouse;
        }
    }

    try std.testing.expect(mouse_event != null);
    try std.testing.expectEqual(@as(u16, 9), mouse_event.?.x); // 0-indexed
    try std.testing.expectEqual(@as(u16, 19), mouse_event.?.y);
    try std.testing.expect(mouse_event.?.button == .left);
}

test "PTY decode bracketed paste" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Bracketed paste: ESC [ 200 ~ <content> ESC [ 201 ~
    const paste_content = "Hello, pasted text!";
    const paste_seq = "\x1b[200~" ++ paste_content ++ "\x1b[201~";

    try pty.writeInput(paste_seq);
    std.Thread.sleep(20 * std.time.ns_per_ms);

    var buf: [256]u8 = undefined;
    const n = posix.read(pty.slave, &buf) catch 0;

    var paste_event: ?[]const u8 = null;
    for (buf[0..n]) |byte| {
        const result = try decoder.feed(byte);
        if (result == .event and result.event == .paste) {
            paste_event = result.event.paste;
        }
    }

    try std.testing.expect(paste_event != null);
    try std.testing.expectEqualStrings(paste_content, paste_event.?);
}

test "PTY decode focus events" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Focus in: ESC [ I
    try pty.writeInput("\x1b[I");
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var buf: [64]u8 = undefined;
    var n = posix.read(pty.slave, &buf) catch 0;

    var focus_event: ?bool = null;
    for (buf[0..n]) |byte| {
        const result = try decoder.feed(byte);
        if (result == .event and result.event == .focus) {
            focus_event = result.event.focus;
        }
    }

    try std.testing.expect(focus_event != null);
    try std.testing.expect(focus_event.? == true);

    // Focus out: ESC [ O
    try pty.writeInput("\x1b[O");
    std.Thread.sleep(10 * std.time.ns_per_ms);

    n = posix.read(pty.slave, &buf) catch 0;
    focus_event = null;

    for (buf[0..n]) |byte| {
        const result = try decoder.feed(byte);
        if (result == .event and result.event == .focus) {
            focus_event = result.event.focus;
        }
    }

    try std.testing.expect(focus_event != null);
    try std.testing.expect(focus_event.? == false);
}

// =============================================================================
// Renderer Output Tests (Golden Frame Style)
// =============================================================================

/// Golden frame test helper - compare renderer output against expected output
fn assertRendererOutput(renderer: *Renderer, expected_contains: []const []const u8) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try renderer.flush(output.writer(std.testing.allocator));

    for (expected_contains) |pattern| {
        try std.testing.expect(std.mem.indexOf(u8, output.items, pattern) != null);
    }
}

test "Renderer output contains cursor positioning" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.print(0, 0, "A", .default, .default, .{});
    buf.print(5, 2, "B", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Should contain cursor positioning sequences
    // CSI row ; col H format
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "B") != null);
}

test "Renderer output contains color sequences for true color" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(0, 0, Cell{
        .char = 'X',
        .combining = .{ 0, 0 },
        .fg = Cell.Color.fromRgb(255, 0, 0),
        .bg = .default,
        .attrs = .{},
    });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // True color foreground: ESC[38;2;R;G;Bm
    try std.testing.expect(std.mem.indexOf(u8, output.items, "38;2;255;0;0") != null);
}

test "Renderer output downgrades colors for basic mode" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .basic);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(0, 0, Cell{
        .char = 'X',
        .combining = .{ 0, 0 },
        .fg = Cell.Color.fromRgb(255, 0, 0),
        .bg = .default,
        .attrs = .{},
    });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Should NOT contain true color sequence in basic mode
    try std.testing.expect(std.mem.indexOf(u8, output.items, "38;2") == null);
}

test "Renderer output contains attribute sequences" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.setCell(0, 0, Cell{
        .char = 'B',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{ .bold = true },
    });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Bold: ESC[1m
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[1m") != null);
}

test "Renderer diff output is smaller than full redraw" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 20, .height = 10 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();

    // Fill buffer with content
    for (0..10) |y| {
        buf.print(0, @intCast(y), "XXXXXXXXXXXXXXXXXXXX", .default, .default, .{});
    }

    // First flush (full redraw)
    var output1: std.ArrayList(u8) = .empty;
    defer output1.deinit(std.testing.allocator);
    try renderer.flush(output1.writer(std.testing.allocator));

    // Change just one cell
    buf.setCell(10, 5, Cell{
        .char = 'O',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    // Second flush (diff)
    var output2: std.ArrayList(u8) = .empty;
    defer output2.deinit(std.testing.allocator);
    try renderer.flush(output2.writer(std.testing.allocator));

    // Diff output should be significantly smaller
    try std.testing.expect(output2.items.len < output1.items.len / 2);
    try std.testing.expect(std.mem.indexOf(u8, output2.items, "O") != null);
}

test "Renderer handles wide characters correctly" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 20, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.print(0, 0, "中文", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Should contain the UTF-8 encoded CJK characters
    // 中 = U+4E2D = E4 B8 AD
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\xE4\xB8\xAD") != null);
}

test "Renderer handles combining marks correctly" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 20, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    // Print "e" + combining acute (U+0301)
    buf.print(0, 0, "e\xCC\x81", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Output should contain 'e' followed by combining acute
    try std.testing.expect(std.mem.indexOf(u8, output.items, "e\xCC\x81") != null);
}

// =============================================================================
// End-to-End PTY Tests
// =============================================================================

test "PTY write renderer output and verify" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    // Create renderer and generate output
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 10, .height = 5 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.print(0, 0, "Hello", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Write renderer output to PTY master (simulating terminal output)
    _ = try posix.write(pty.master, output.items);

    // In a real terminal, this would display on screen
    // For testing, we verify the data was written successfully
    try std.testing.expect(output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Hello") != null);
}

test "Full roundtrip: input -> decode -> process -> render -> output" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);
    try pty.setSize(80, 24);

    // Simulate a key press coming through PTY
    try pty.writeInput("x");
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Read the input
    var input_buf: [64]u8 = undefined;
    const n = posix.read(pty.slave, &input_buf) catch 0;
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(u8, 'x'), input_buf[0]);

    // Decode the input
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    const result = try decoder.feed(input_buf[0]);
    try std.testing.expect(result == .event);
    try std.testing.expect(result.event.key.codepoint == 'x');

    // Create renderer response
    var renderer = try Renderer.init(std.testing.allocator, .{ .width = 80, .height = 24 }, .true_color);
    defer renderer.deinit();

    const buf = renderer.buffer();
    buf.print(0, 0, "You pressed: x", .default, .default, .{});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderer.flush(output.writer(std.testing.allocator));

    // Write output to PTY
    _ = try posix.write(pty.master, output.items);

    // Verify complete roundtrip
    try std.testing.expect(output.items.len > 0);
}

// =============================================================================
// Input.pollEvent Integration Tests
// =============================================================================
// These tests verify the high-level Input.pollEvent function which combines
// polling, reading, and decoding with escape timeout handling.

test "Input.pollEvent returns simple key press" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write a simple character through PTY
    try pty.writeInput("a");

    // pollEvent should return the key event
    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expectEqual(@as(?u21, 'a'), event.?.key.codepoint);
}

test "Input.pollEvent returns arrow key events" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Test all arrow keys
    const sequences = [_]struct { seq: []const u8, expected: Event.Key.Special }{
        .{ .seq = "\x1b[A", .expected = .up },
        .{ .seq = "\x1b[B", .expected = .down },
        .{ .seq = "\x1b[C", .expected = .right },
        .{ .seq = "\x1b[D", .expected = .left },
    };

    for (sequences) |test_case| {
        try pty.writeInput(test_case.seq);

        const event = try input.pollEvent(100);
        try std.testing.expect(event != null);
        try std.testing.expect(event.? == .key);
        try std.testing.expect(event.?.key.special == test_case.expected);
    }
}

test "Input.pollEvent timeout returns null" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Don't write anything - should timeout
    const start = std.time.milliTimestamp();
    const event = try input.pollEvent(50);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(event == null);
    // Should have waited approximately 50ms (allow some variance)
    try std.testing.expect(elapsed >= 40 and elapsed < 200);
}

test "Input.pollEvent escape timeout emits bare escape" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Set a short escape timeout for faster testing
    input.setEscapeTimeout(30);

    // Write just ESC (0x1b) without any following bytes
    try pty.writeInput("\x1b");

    // pollEvent should timeout waiting for more bytes, then emit bare ESC
    const start = std.time.milliTimestamp();
    const event = try input.pollEvent(200);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expect(event.?.key.special == .escape);

    // Should have waited for escape timeout (30ms) before emitting
    try std.testing.expect(elapsed >= 20 and elapsed < 150);
}

test "Input.pollEvent escape followed by sequence produces arrow key" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write complete escape sequence for up arrow
    try pty.writeInput("\x1b[A");

    // Should get arrow key, not bare escape
    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expect(event.?.key.special == .up);
}

test "Input.pollEvent handles bracketed paste via PTY" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write bracketed paste sequence
    const paste_content = "Hello, pasted!";
    const paste_seq = "\x1b[200~" ++ paste_content ++ "\x1b[201~";
    try pty.writeInput(paste_seq);

    // Should get paste event
    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .paste);
    try std.testing.expectEqualStrings(paste_content, event.?.paste);
}

test "Input.pollEvent handles multi-line bracketed paste" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write bracketed paste with newlines
    const paste_content = "line1\nline2\nline3";
    const paste_seq = "\x1b[200~" ++ paste_content ++ "\x1b[201~";
    try pty.writeInput(paste_seq);

    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .paste);
    try std.testing.expectEqualStrings(paste_content, event.?.paste);
}

test "Input.pollEvent handles bracketed paste with special characters" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Paste content with control characters (except ESC which would be filtered by terminals)
    const paste_content = "tab:\there\r\nnewline";
    const paste_seq = "\x1b[200~" ++ paste_content ++ "\x1b[201~";
    try pty.writeInput(paste_seq);

    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .paste);
    try std.testing.expectEqualStrings(paste_content, event.?.paste);
}

test "Input.pollEvent handles focus events" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Focus in
    try pty.writeInput("\x1b[I");
    var event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .focus);
    try std.testing.expect(event.?.focus == true);

    // Focus out
    try pty.writeInput("\x1b[O");
    event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .focus);
    try std.testing.expect(event.?.focus == false);
}

test "Input.pollEvent handles mouse events" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // SGR mouse: left click at (5, 10)
    try pty.writeInput("\x1b[<0;5;10M");

    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .mouse);
    try std.testing.expectEqual(@as(u16, 4), event.?.mouse.x); // 0-indexed
    try std.testing.expectEqual(@as(u16, 9), event.?.mouse.y);
    try std.testing.expect(event.?.mouse.button == .left);
}

test "Input.pollEvent handles multiple events in sequence" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write multiple events
    try pty.writeInput("abc");

    // Should get each character as separate event
    var event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(@as(?u21, 'a'), event.?.key.codepoint);

    event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(@as(?u21, 'b'), event.?.key.codepoint);

    event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(@as(?u21, 'c'), event.?.key.codepoint);
}

test "Input.pollEvent handles interleaved events and paste" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Key, then paste, then key
    try pty.writeInput("x");
    try pty.writeInput("\x1b[200~pasted\x1b[201~");
    try pty.writeInput("y");

    // First: 'x'
    var event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expectEqual(@as(?u21, 'x'), event.?.key.codepoint);

    // Second: paste
    event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .paste);
    try std.testing.expectEqualStrings("pasted", event.?.paste);

    // Third: 'y'
    event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expectEqual(@as(?u21, 'y'), event.?.key.codepoint);
}

test "Input.pollEvent peekEvent is non-blocking" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // peekEvent with no data should return immediately
    const start = std.time.milliTimestamp();
    const event = try input.peekEvent();
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(event == null);
    // Should return very quickly (less than 20ms)
    try std.testing.expect(elapsed < 20);
}

test "Input.pollEvent peekEvent returns event if available" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write data first
    try pty.writeInput("z");
    std.Thread.sleep(10 * std.time.ns_per_ms); // Let it propagate

    // peekEvent should return the event
    const event = try input.peekEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(@as(?u21, 'z'), event.?.key.codepoint);
}

test "Input.pollEvent handles UTF-8 via PTY" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write UTF-8 encoded é (U+00E9)
    try pty.writeInput("\xC3\xA9");

    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expectEqual(@as(?u21, 0xe9), event.?.key.codepoint);
}

test "Input.pollEvent handles Alt+key via PTY" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // ESC followed by 'a' = Alt+a
    try pty.writeInput("\x1ba");

    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expectEqual(@as(?u21, 'a'), event.?.key.codepoint);
    try std.testing.expect(event.?.key.mods.alt);
}

test "Input.pollEvent reset clears pending state" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);

    var input = Input.init(std.testing.allocator, pty.slave);
    defer input.deinit();

    // Write partial escape sequence
    try pty.writeInput("\x1b[");
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Read partial data into input buffer
    _ = try input.pollEvent(20);

    // Reset should clear pending state
    input.reset();

    // Write complete new sequence
    try pty.writeInput("\x1b[A");

    // Should get arrow key, not garbage from partial sequence
    const event = try input.pollEvent(100);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .key);
    try std.testing.expect(event.?.key.special == .up);
}

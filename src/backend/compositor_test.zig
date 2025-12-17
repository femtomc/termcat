const std = @import("std");
const posix = std.posix;
const termcat = @import("../root.zig");
const Pty = termcat.backend.pty.Pty;
const Renderer = termcat.Renderer;
const Buffer = termcat.Buffer;
const Cell = termcat.Cell;
const Plane = termcat.Plane.Plane;
const Compositor = termcat.Compositor;
const Blit = termcat.Blit;
const Event = termcat.Event;
const Rect = Event.Rect;
const Color = Cell.Color;

// =============================================================================
// Compositor PTY Regression Tests
// =============================================================================
// These tests verify that the compositor correctly renders layered planes
// through a PTY interface, validating z-order, transparency, clipping,
// and dirty region optimization.

/// Test helper: Set PTY slave to raw mode
fn setRawMode(fd: posix.fd_t) !posix.termios {
    var attr = try posix.tcgetattr(fd);
    const orig = attr;

    attr.iflag.BRKINT = false;
    attr.iflag.ICRNL = false;
    attr.iflag.INPCK = false;
    attr.iflag.ISTRIP = false;
    attr.iflag.IXON = false;

    attr.oflag.OPOST = false;

    attr.cflag.CSIZE = .CS8;
    attr.cflag.PARENB = false;

    attr.lflag.ECHO = false;
    attr.lflag.ICANON = false;
    attr.lflag.IEXTEN = false;
    attr.lflag.ISIG = false;

    attr.cc[@intFromEnum(posix.V.MIN)] = 0;
    attr.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, attr);
    return orig;
}

/// Check that a cell has expected character and color
fn expectCell(buf: *const Buffer, x: u16, y: u16, char: u21, fg: Color) !void {
    const cell = buf.getCell(x, y);
    try std.testing.expectEqual(char, cell.char);
    try std.testing.expect(cell.fg.eql(fg));
}

// =============================================================================
// Z-Order Tests
// =============================================================================

test "Compositor z-order: layered planes render in correct order" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    // Create root and overlapping children
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Background plane (bottom) - fill entire width
    const bg = try Plane.initChild(root, 0, 0, .{ .width = 20, .height = 10 });
    bg.print(0, 0, "BBBBBBBBBBBBBBBBBBBB", Color.blue, Color.black, .{});

    // Middle plane (partially overlaps)
    const mid = try Plane.initChild(root, 2, 0, .{ .width = 10, .height = 5 });
    mid.print(0, 0, "MMMMMMMMMM", Color.green, Color.black, .{});

    // Top plane (on top of middle)
    const top = try Plane.initChild(root, 4, 0, .{ .width = 6, .height = 3 });
    top.print(0, 0, "TTTTTT", Color.red, Color.black, .{});

    // Compose
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Verify z-order: positions 0-1 should be B (background)
    try expectCell(&target, 0, 0, 'B', Color.blue);
    try expectCell(&target, 1, 0, 'B', Color.blue);

    // Positions 2-3 should be M (middle, not covered by top)
    try expectCell(&target, 2, 0, 'M', Color.green);
    try expectCell(&target, 3, 0, 'M', Color.green);

    // Positions 4-9 should be T (top layer)
    try expectCell(&target, 4, 0, 'T', Color.red);
    try expectCell(&target, 9, 0, 'T', Color.red);

    // Position 10-11 should be M (middle, beyond top)
    try expectCell(&target, 10, 0, 'M', Color.green);
    try expectCell(&target, 11, 0, 'M', Color.green);

    // Position 12+ should be B (background only)
    try expectCell(&target, 12, 0, 'B', Color.blue);
}

test "Compositor z-order: raise/lower changes render order" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Create two overlapping children
    const child1 = try Plane.initChild(root, 0, 0, .{ .width = 6, .height = 3 });
    child1.print(0, 0, "AAAAAA", Color.red, Color.black, .{});

    const child2 = try Plane.initChild(root, 2, 0, .{ .width = 6, .height = 3 });
    child2.print(0, 0, "BBBBBB", Color.blue, Color.black, .{});

    // Initial compose: child2 is on top (added last)
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Position 2-7 should be B (child2 on top)
    try expectCell(&target, 2, 0, 'B', Color.blue);

    // Lower child2, so child1 should be on top now
    child2.lower();
    compositor.invalidateAll();

    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Position 2-5 should now be A (child1 on top)
    try expectCell(&target, 2, 0, 'A', Color.red);

    // Position 6-7 should be B (only child2 visible there)
    try expectCell(&target, 6, 0, 'B', Color.blue);
}

// =============================================================================
// Transparency Tests
// =============================================================================

test "Compositor transparency: holes show underlying content" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Background with full content
    root.print(0, 0, "BACKGROUND", Color.white, Color.black, .{});

    // Overlay with transparency holes (only draw at positions 0, 2, 4)
    const overlay = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 1 });
    overlay.setCell(0, 0, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });
    overlay.setCell(2, 0, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });
    overlay.setCell(4, 0, Cell{ .char = 'X', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });
    // Positions 1, 3, 5-9 are default/transparent

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // X should appear at 0, 2, 4
    try expectCell(&target, 0, 0, 'X', Color.red);
    try expectCell(&target, 2, 0, 'X', Color.red);
    try expectCell(&target, 4, 0, 'X', Color.red);

    // Background should show through at 1, 3
    try expectCell(&target, 1, 0, 'A', Color.white); // 'A' from "BACKGROUND"
    try expectCell(&target, 3, 0, 'K', Color.white); // 'K' from "BACKGROUND"
}

test "Compositor transparency: opaque background blocks lower layers" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Background content
    root.print(0, 0, "BACKGROUND", Color.white, Color.black, .{});

    // Overlay with opaque background color (should block underlying content)
    const dialog = try Plane.initChild(root, 2, 0, .{ .width = 4, .height = 1 });
    // Fill with spaces but with non-default background - should be opaque
    dialog.fill(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = Color.blue, // Non-default background = opaque
        .attrs = .{},
    });

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Dialog area should have spaces with blue background (blocking content)
    const dialog_cell = target.getCell(2, 0);
    try std.testing.expectEqual(@as(u21, ' '), dialog_cell.char);
    try std.testing.expect(dialog_cell.bg.eql(Color.blue));

    // Background still visible outside dialog
    try expectCell(&target, 0, 0, 'B', Color.white);
    try expectCell(&target, 1, 0, 'A', Color.white);
    try expectCell(&target, 6, 0, 'R', Color.white);
}

// =============================================================================
// Clipping Tests
// =============================================================================

test "Compositor clipping: child clipped to parent bounds" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    // Root is 20x10
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Child extends beyond root bounds
    const child = try Plane.initChild(root, 15, 8, .{ .width = 10, .height = 5 });
    child.print(0, 0, "ABCDEFGHIJ", Color.red, Color.black, .{});

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Only first 5 characters should be visible (columns 15-19)
    try expectCell(&target, 15, 8, 'A', Color.red);
    try expectCell(&target, 16, 8, 'B', Color.red);
    try expectCell(&target, 17, 8, 'C', Color.red);
    try expectCell(&target, 18, 8, 'D', Color.red);
    try expectCell(&target, 19, 8, 'E', Color.red);

    // Row 9 should only show first 5 chars (clipped height)
    // But child only prints on row 0, so row 9 should be empty/default
}

test "Compositor clipping: negative position clips from top-left" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    // Child with negative position
    const child = try Plane.initChild(root, -3, -2, .{ .width = 10, .height = 5 });
    // Print at (0,0) of child, which is off-screen
    child.print(0, 0, "0123456789", Color.green, Color.black, .{});
    child.print(0, 1, "ABCDEFGHIJ", Color.green, Color.black, .{});
    child.print(0, 2, "----------", Color.green, Color.black, .{}); // Row 0 on screen

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Child row 2 should appear at screen row 0 (offset by -2)
    // Child column 3 should appear at screen column 0 (offset by -3)
    try expectCell(&target, 0, 0, '-', Color.green);
    try expectCell(&target, 1, 0, '-', Color.green);
}

// =============================================================================
// Dirty Region Tracking Tests
// =============================================================================

test "Compositor dirty regions: full redraw on first compose" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // First compose should return full screen as dirty
    try std.testing.expectEqual(@as(usize, 1), dirty.len);
    try std.testing.expectEqual(@as(u16, 0), dirty[0].x);
    try std.testing.expectEqual(@as(u16, 0), dirty[0].y);
    try std.testing.expectEqual(@as(u16, 20), dirty[0].width);
    try std.testing.expectEqual(@as(u16, 10), dirty[0].height);
}

test "Compositor dirty regions: no dirty regions when nothing changed" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Second compose without changes
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // No dirty regions expected
    try std.testing.expectEqual(@as(usize, 0), dirty2.len);
}

test "Compositor dirty regions: small move produces small dirty region" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 5, .{ .width = 4, .height = 2 });
    child.print(0, 0, "TEST", Color.red, Color.black, .{});

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Move the child
    const old_x = child.x;
    const old_y = child.y;
    child.move(10, 8);
    try compositor.invalidatePlaneMove(child, old_x, old_y);

    // Second compose
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Should have dirty regions (covering old and new positions)
    // but not full screen
    try std.testing.expect(dirty2.len > 0);

    // Calculate total dirty area
    var total_dirty_area: u32 = 0;
    for (dirty2) |region| {
        total_dirty_area += @as(u32, region.width) * @as(u32, region.height);
    }

    // Total screen area
    const full_screen_area: u32 = 40 * 20; // 800

    // Dirty area should be much smaller than full screen
    // Two regions of 4x2 = 16 total, but may be coalesced
    try std.testing.expect(total_dirty_area < full_screen_area / 4);
}

test "Compositor dirty regions: visibility change marks correct region" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    const child = try Plane.initChild(root, 5, 3, .{ .width = 6, .height = 2 });
    child.print(0, 0, "HIDDEN", Color.red, Color.black, .{});

    // First compose with child visible
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    try expectCell(&target, 5, 3, 'H', Color.red);

    // Invalidate before hiding (IMPORTANT: must call before setVisible(false))
    try compositor.invalidatePlane(child);
    child.setVisible(false);

    // Second compose
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Should have dirty region for where child was
    try std.testing.expect(dirty2.len > 0);

    // Child content should be gone
    try std.testing.expectEqual(@as(u21, ' '), target.getCell(5, 3).char);
}

// =============================================================================
// Wide Character Tests
// =============================================================================

test "Compositor wide characters: CJK renders correctly through compositor" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 5 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    // Print CJK characters (each takes 2 cells)
    root.print(0, 0, "A中B", Color.white, Color.black, .{});
    // Layout: A, 中, [cont], B (positions 0, 1, 2, 3)

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Verify wide character
    try std.testing.expectEqual(@as(u21, 'A'), target.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), target.getCell(1, 0).char); // 中
    try std.testing.expect(target.getCell(2, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 'B'), target.getCell(3, 0).char);
}

test "Compositor wide characters: overlay with transparency preserves wide chars" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 3 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 3 });
    defer root.deinit();

    // Background with wide characters: 中 at 0-1, 文 at 2-3, 测 at 4-5, 试 at 6-7
    root.print(0, 0, "中文测试", Color.white, Color.black, .{});

    // Transparent overlay positioned to NOT cover any wide char base positions
    // Position 8 is after all the wide chars, so it won't corrupt anything
    const overlay = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 1 });
    overlay.setCell(8, 0, Cell{ .char = '*', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Wide chars should be preserved
    try std.testing.expectEqual(@as(u21, 0x4E2D), target.getCell(0, 0).char); // 中
    try std.testing.expect(target.getCell(1, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 0x6587), target.getCell(2, 0).char); // 文
    try std.testing.expect(target.getCell(3, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 0x6D4B), target.getCell(4, 0).char); // 测
    try std.testing.expect(target.getCell(5, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 0x8BD5), target.getCell(6, 0).char); // 试
    try std.testing.expect(target.getCell(7, 0).isContinuation());

    // Overlay should be visible at position 8
    try std.testing.expectEqual(@as(u21, '*'), target.getCell(8, 0).char);
}

test "Compositor wide characters: overlay does not corrupt adjacent wide chars" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 10, .height = 3 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 3 });
    defer root.deinit();

    // Background with wide character
    root.print(2, 0, "中", Color.white, Color.black, .{}); // At positions 2-3

    // Overlay with marker at position 0 (doesn't touch wide char)
    const overlay = try Plane.initChild(root, 0, 0, .{ .width = 10, .height = 1 });
    overlay.setCell(0, 0, Cell{ .char = '*', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Position 0 should have overlay
    try std.testing.expectEqual(@as(u21, '*'), target.getCell(0, 0).char);

    // Positions 2-3 should have wide char intact
    try std.testing.expectEqual(@as(u21, 0x4E2D), target.getCell(2, 0).char);
    try std.testing.expect(target.getCell(3, 0).isContinuation());
}

// =============================================================================
// PTY Integration Tests
// =============================================================================

test "PTY compositor: render layered planes through PTY" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);
    try pty.setSize(40, 20);

    const allocator = std.testing.allocator;

    // Set up compositor pipeline
    var target = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    var renderer = try Renderer.init(allocator, .{ .width = 40, .height = 20 }, .true_color);
    defer renderer.deinit();

    // Create plane hierarchy
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    root.print(0, 0, "Background Layer", Color.white, Color.black, .{});

    const dialog = try Plane.initChild(root, 5, 5, .{ .width = 20, .height = 5 });
    dialog.fill(.{ .x = 0, .y = 0, .width = 20, .height = 5 }, Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = Color.blue,
        .attrs = .{},
    });
    dialog.print(1, 1, "Dialog Content", Color.white, .default, .{});

    // Compose
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Copy compositor output to renderer's back buffer
    @memcpy(renderer.buffer().cells, target.cells);

    // Flush renderer output
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try renderer.flush(output.writer(allocator));

    // Write to PTY master
    _ = try posix.write(pty.master, output.items);

    // Verify output contains expected content
    try std.testing.expect(output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Background") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Dialog") != null);
}

test "PTY compositor: golden frame comparison" {
    const pty = try Pty.open();
    defer pty.close();

    _ = try setRawMode(pty.slave);
    try pty.setSize(20, 10);

    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    var renderer = try Renderer.init(allocator, .{ .width = 20, .height = 10 }, .true_color);
    defer renderer.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Create a specific pattern for golden frame test
    root.print(0, 0, "AAAAAAAAAAAAAAAAAAAA", Color.red, .default, .{}); // Row 0: all A's
    root.print(0, 1, "BBBBBBBBBBBBBBBBBBBB", Color.green, .default, .{}); // Row 1: all B's

    const overlay = try Plane.initChild(root, 5, 0, .{ .width = 5, .height = 2 });
    overlay.print(0, 0, "XXXXX", Color.yellow, .default, .{});
    overlay.print(0, 1, "YYYYY", Color.cyan, .default, .{});

    // Compose and capture frame
    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Copy compositor output to renderer's back buffer
    @memcpy(renderer.buffer().cells, target.cells);

    // Flush renderer output to capture the "golden frame"
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try renderer.flush(output.writer(allocator));

    // Write the golden frame to PTY
    _ = try posix.write(pty.master, output.items);

    // Verify the expected pattern in the target buffer:
    // Row 0: AAAAAXXXXXAAAAAAAAAA
    // Row 1: BBBBBYYYYYBBBBBBBBBB

    // Before overlay (0-4)
    try expectCell(&target, 0, 0, 'A', Color.red);
    try expectCell(&target, 4, 0, 'A', Color.red);

    // Overlay area (5-9)
    try expectCell(&target, 5, 0, 'X', Color.yellow);
    try expectCell(&target, 9, 0, 'X', Color.yellow);

    // After overlay (10-19)
    try expectCell(&target, 10, 0, 'A', Color.red);
    try expectCell(&target, 19, 0, 'A', Color.red);

    // Row 1
    try expectCell(&target, 0, 1, 'B', Color.green);
    try expectCell(&target, 5, 1, 'Y', Color.cyan);
    try expectCell(&target, 10, 1, 'B', Color.green);

    // Verify the output contains the expected characters for the golden frame
    try std.testing.expect(output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "AAAAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "XXXXX") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "BBBBB") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "YYYYY") != null);
}

test "PTY compositor: diff output smaller than full redraw for small changes" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 40, .height = 20 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    var renderer = try Renderer.init(allocator, .{ .width = 40, .height = 20 }, .true_color);
    defer renderer.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 20 });
    defer root.deinit();

    // Fill screen with content
    var y: u16 = 0;
    while (y < 20) : (y += 1) {
        root.print(0, y, "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", Color.white, .default, .{});
    }

    // First compose and flush (full redraw)
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);
    @memcpy(renderer.buffer().cells, target.cells);

    var output1: std.ArrayList(u8) = .empty;
    defer output1.deinit(allocator);
    try renderer.flush(output1.writer(allocator));

    // Create small overlay
    const overlay = try Plane.initChild(root, 10, 10, .{ .width = 3, .height = 1 });
    overlay.print(0, 0, "***", Color.red, .default, .{});
    try compositor.invalidatePlane(overlay);

    // Second compose and flush (should be diff-based)
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);
    @memcpy(renderer.buffer().cells, target.cells);

    var output2: std.ArrayList(u8) = .empty;
    defer output2.deinit(allocator);
    try renderer.flush(output2.writer(allocator));

    // Diff output should be significantly smaller than full redraw
    // Full redraw: ~800 cells worth of data + escape sequences
    // Diff: only ~3 cells changed
    try std.testing.expect(output2.items.len < output1.items.len / 2);

    // But output2 should contain the changed content
    try std.testing.expect(std.mem.indexOf(u8, output2.items, "***") != null);
}

// =============================================================================
// Blit Integration Tests
// =============================================================================

test "Compositor with Blit: sprite overlay" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Background
    root.print(0, 0, "####################", Color.blue, .default, .{});

    // Create a sprite and blit to a plane
    var sprite = try Blit.Sprite.init(allocator, .{ .width = 3, .height = 1 });
    defer sprite.deinit();
    sprite.setCell(0, 0, Cell{ .char = '<', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });
    sprite.setCell(1, 0, Cell{ .char = 'o', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });
    sprite.setCell(2, 0, Cell{ .char = '>', .combining = .{ 0, 0 }, .fg = Color.red, .bg = .default, .attrs = .{} });

    // Create overlay plane and blit sprite to it
    const overlay = try Plane.initChild(root, 5, 0, .{ .width = 10, .height = 3 });
    sprite.blitTo(overlay, 2, 0); // Blit sprite at position (2,0) in overlay

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Background before sprite
    try expectCell(&target, 0, 0, '#', Color.blue);
    try expectCell(&target, 6, 0, '#', Color.blue);

    // Sprite content at (5+2, 0) = (7, 0)
    try expectCell(&target, 7, 0, '<', Color.red);
    try expectCell(&target, 8, 0, 'o', Color.red);
    try expectCell(&target, 9, 0, '>', Color.red);

    // Background after sprite
    try expectCell(&target, 10, 0, '#', Color.blue);
}

// =============================================================================
// Move/Resize Tests
// =============================================================================

test "Compositor plane move: content moves correctly" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 30, .height = 15 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 15 });
    defer root.deinit();

    const movable = try Plane.initChild(root, 5, 5, .{ .width = 6, .height = 2 });
    movable.print(0, 0, "WINDOW", Color.green, .default, .{});

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Verify initial position
    try expectCell(&target, 5, 5, 'W', Color.green);
    try expectCell(&target, 10, 5, 'W', Color.green);

    // Move the plane
    const old_x = movable.x;
    const old_y = movable.y;
    movable.move(15, 8);
    try compositor.invalidatePlaneMove(movable, old_x, old_y);

    // Second compose
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // Old position should be cleared
    try std.testing.expectEqual(@as(u21, ' '), target.getCell(5, 5).char);

    // New position should have content
    try expectCell(&target, 15, 8, 'W', Color.green);
    try expectCell(&target, 20, 8, 'W', Color.green);
}

test "Compositor plane resize: clipping updates" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 20, .height = 10 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    const resizable = try Plane.initChild(root, 2, 2, .{ .width = 10, .height = 3 });
    resizable.print(0, 0, "AAAAAAAAAA", Color.red, .default, .{});

    // First compose
    const dirty1 = try compositor.compose(root);
    defer allocator.free(dirty1);

    // Verify initial content
    try expectCell(&target, 2, 2, 'A', Color.red);
    try expectCell(&target, 11, 2, 'A', Color.red);

    // Invalidate before resize
    try compositor.invalidatePlane(resizable);

    // Resize smaller
    try resizable.resize(.{ .width = 5, .height = 2 });
    // Note: resize clears the buffer, so we need to redraw
    resizable.print(0, 0, "BBBBB", Color.blue, .default, .{});

    // Invalidate after resize
    try compositor.invalidatePlane(resizable);

    // Second compose
    const dirty2 = try compositor.compose(root);
    defer allocator.free(dirty2);

    // New content should be visible
    try expectCell(&target, 2, 2, 'B', Color.blue);
    try expectCell(&target, 6, 2, 'B', Color.blue);

    // Old area should be cleared
    try std.testing.expectEqual(@as(u21, ' '), target.getCell(7, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), target.getCell(11, 2).char);
}

// =============================================================================
// Complex Hierarchy Tests
// =============================================================================

test "Compositor nested hierarchy: grandchildren render correctly" {
    const allocator = std.testing.allocator;

    var target = try Buffer.init(allocator, .{ .width = 30, .height = 15 });
    defer target.deinit();

    var compositor = Compositor.init(allocator, &target);
    defer compositor.deinit();

    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 15 });
    defer root.deinit();

    // Create nested hierarchy: root -> window -> titlebar/content
    const window = try Plane.initChild(root, 5, 3, .{ .width = 20, .height = 10 });
    window.fill(.{ .x = 0, .y = 0, .width = 20, .height = 10 }, Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = Color.blue,
        .attrs = .{},
    });

    const titlebar = try Plane.initChild(window, 0, 0, .{ .width = 20, .height = 1 });
    titlebar.fill(.{ .x = 0, .y = 0, .width = 20, .height = 1 }, Cell{
        .char = ' ',
        .combining = .{ 0, 0 },
        .fg = .default,
        .bg = Color.cyan,
        .attrs = .{},
    });
    titlebar.print(1, 0, "Window Title", Color.white, Color.cyan, .{});

    const content = try Plane.initChild(window, 1, 2, .{ .width = 18, .height = 6 });
    content.print(0, 0, "Window Content", Color.yellow, .default, .{});

    const dirty = try compositor.compose(root);
    defer allocator.free(dirty);

    // Verify nested hierarchy rendered correctly
    // Titlebar at screen position (5, 3)
    const title_cell = target.getCell(6, 3);
    try std.testing.expectEqual(@as(u21, 'W'), title_cell.char);
    try std.testing.expect(title_cell.bg.eql(Color.cyan));

    // Content at screen position (5+1, 3+2) = (6, 5)
    const content_cell = target.getCell(6, 5);
    try std.testing.expectEqual(@as(u21, 'W'), content_cell.char);
    try std.testing.expect(content_cell.fg.eql(Color.yellow));

    // Window background at (5, 4) - between titlebar and content
    const bg_cell = target.getCell(5, 4);
    try std.testing.expect(bg_cell.bg.eql(Color.blue));
}

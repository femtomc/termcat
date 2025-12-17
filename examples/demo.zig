const std = @import("std");
const termcat = @import("termcat");
const Terminal = termcat.Terminal;
const Plane = termcat.Plane.Plane;
const Cell = termcat.Cell;
const Color = termcat.Color;
const Rect = termcat.Rect;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal with mouse support
    var term = try Terminal.init(allocator, .{
        .backend = .{ .enable_mouse = true },
    });
    defer term.deinit();

    var size = term.size();

    // ═══════════════════════════════════════════════════════════════════
    // Create planes - each is an independent layer
    // ═══════════════════════════════════════════════════════════════════

    // Background starfield plane
    const stars = try term.createPlane(0, 0, size);
    drawStarfield(stars, size);

    // Floating window 1 - draggable info panel
    var win1_x: i32 = 5;
    var win1_y: i32 = 3;
    const win1 = try Plane.initChild(term.rootPlane(), win1_x, win1_y, .{ .width = 30, .height = 12 });
    drawWindow(win1, "[ System Info ]", Color.cyan);
    drawSystemInfo(win1);

    // Floating window 2 - color palette
    var win2_x: i32 = @intCast(size.width -| 38);
    var win2_y: i32 = 3;
    const win2 = try Plane.initChild(term.rootPlane(), win2_x, win2_y, .{ .width = 32, .height = 14 });
    drawWindow(win2, "[ Colors ]", Color.magenta);
    drawColorPalette(win2);

    // Bouncing ball plane
    var ball_x: i32 = @intCast(size.width / 2);
    var ball_y: i32 = @intCast(size.height / 2);
    var ball_dx: i32 = 1;
    var ball_dy: i32 = 1;
    const ball = try Plane.initChild(term.rootPlane(), ball_x, ball_y, .{ .width = 3, .height = 1 });
    drawBall(ball);

    // Status bar at bottom
    const status = try Plane.initChild(term.rootPlane(), 0, @intCast(size.height -| 1), .{ .width = size.width, .height = 1 });

    // Mouse cursor overlay (topmost)
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    const cursor_plane = try Plane.initChild(term.rootPlane(), 0, 0, .{ .width = 1, .height = 1 });
    cursor_plane.setCell(0, 0, .{
        .char = '+',
        .combining = .{ 0, 0 },
        .fg = Color.fromRgb(255, 255, 0),
        .bg = .default,
        .attrs = .{ .bold = true },
    });

    // ═══════════════════════════════════════════════════════════════════
    // Main loop - animation + input
    // ═══════════════════════════════════════════════════════════════════

    var frame: u32 = 0;
    var dragging: ?*Plane = null;
    var drag_offset_x: i32 = 0;
    var drag_offset_y: i32 = 0;
    var running = true;

    while (running) {
        // Drain ALL pending events before animating (mouse motion can flood the queue)
        while (try term.pollEvent(0)) |event| {
            switch (event) {
                .key => |key| {
                    if (key.special) |sp| {
                        if (sp == .escape) {
                            running = false;
                            continue;
                        }
                    }

                    if (key.codepoint) |cp| {
                        if (cp == 'q' or cp == 'Q') {
                            running = false;
                        } else if (cp == ' ') {
                            // Space: raise win1 to top
                            win1.raise();
                            try term.invalidatePlane(win1);
                        } else if (cp == 'r' or cp == 'R') {
                            // R: randomize starfield
                            drawStarfield(stars, term.size());
                        }
                    }
                },
                .mouse => |m| {
                    mouse_x = @intCast(m.x);
                    mouse_y = @intCast(m.y);
                    cursor_plane.move(mouse_x, mouse_y);

                    switch (m.button) {
                        .left => {
                            // Left button pressed - start dragging if on a window
                            if (isInWindow(win1, win1_x, win1_y, mouse_x, mouse_y)) {
                                dragging = win1;
                                drag_offset_x = mouse_x - win1_x;
                                drag_offset_y = mouse_y - win1_y;
                                win1.raise();
                                try term.invalidatePlane(win1);
                            } else if (isInWindow(win2, win2_x, win2_y, mouse_x, mouse_y)) {
                                dragging = win2;
                                drag_offset_x = mouse_x - win2_x;
                                drag_offset_y = mouse_y - win2_y;
                                win2.raise();
                                try term.invalidatePlane(win2);
                            }
                        },
                        .release => {
                            dragging = null;
                        },
                        .move => {
                            // Mouse move while dragging
                            if (dragging) |plane| {
                                const new_x = mouse_x - drag_offset_x;
                                const new_y = mouse_y - drag_offset_y;
                                const old_x = plane.x;
                                const old_y = plane.y;
                                plane.move(new_x, new_y);
                                try term.invalidatePlaneMove(plane, old_x, old_y);

                                if (plane == win1) {
                                    win1_x = new_x;
                                    win1_y = new_y;
                                } else {
                                    win2_x = new_x;
                                    win2_y = new_y;
                                }
                            }
                        },
                        else => {},
                    }
                },
                .resize => |new_size| {
                    // Update cached size for animation bounds
                    size = new_size;
                    // Update starfield for new size
                    try stars.resize(new_size);
                    drawStarfield(stars, new_size);
                    // Move status bar
                    status.move(0, @intCast(new_size.height -| 1));
                    try status.resize(.{ .width = new_size.width, .height = 1 });
                },
                else => {},
            }
        }

        // ═══════════════════════════════════════════════════════════════
        // Animation updates
        // ═══════════════════════════════════════════════════════════════

        // Bounce the ball
        if (frame % 3 == 0) {
            const old_x = ball.x;
            const old_y = ball.y;

            ball_x += ball_dx;
            ball_y += ball_dy;

            // Bounce off edges (use saturating subtraction to handle tiny terminals)
            const max_x: i32 = @intCast(size.width -| 3);
            const max_y: i32 = @intCast(size.height -| 2);
            if (ball_x <= 0 or ball_x >= max_x) ball_dx = -ball_dx;
            if (ball_y <= 0 or ball_y >= max_y) ball_dy = -ball_dy;

            ball_x = @max(0, @min(ball_x, max_x));
            ball_y = @max(0, @min(ball_y, max_y));

            ball.move(ball_x, ball_y);
            try term.invalidatePlaneMove(ball, old_x, old_y);

            // Change ball color based on position
            const hue: u8 = @truncate(@as(u32, @intCast(ball_x + ball_y * 3)) % 256);
            drawBallWithColor(ball, hueToRgb(hue));
        }

        // Animate starfield (twinkle effect)
        if (frame % 10 == 0) {
            twinkleStars(stars, size, frame);
        }

        // Update status bar
        drawStatusBar(status, frame, mouse_x, mouse_y, term.size());

        // Render!
        try term.present();
        frame +%= 1;

        // Small delay to control frame rate (~120fps)
        std.Thread.sleep(8 * std.time.ns_per_ms);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Drawing helpers
// ═══════════════════════════════════════════════════════════════════════════

const Rgb = struct { r: u8, g: u8, b: u8 };
const dark_bg: Color = .{ .index = 236 };

fn drawStarfield(plane: *Plane, size: termcat.Size) void {
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    const rand = prng.random();

    plane.clear();
    const star_count = @as(usize, size.width) * @as(usize, size.height) / 15;

    for (0..star_count) |_| {
        const x = rand.intRangeLessThan(u16, 0, size.width);
        const y = rand.intRangeLessThan(u16, 0, size.height);
        const brightness = rand.intRangeLessThan(u8, 100, 255);
        const char: u21 = switch (rand.intRangeLessThan(u8, 0, 4)) {
            0 => '.',
            1 => '*',
            2 => '+',
            else => 0x2219, // bullet
        };
        plane.setCell(x, y, .{
            .char = char,
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(brightness, brightness, brightness),
            .bg = .default,
            .attrs = .{},
        });
    }
}

fn twinkleStars(plane: *Plane, size: termcat.Size, frame: u32) void {
    var prng = std.Random.DefaultPrng.init(frame);
    const rand = prng.random();

    for (0..5) |_| {
        const x = rand.intRangeLessThan(u16, 0, size.width);
        const y = rand.intRangeLessThan(u16, 0, size.height);
        const brightness = rand.intRangeLessThan(u8, 150, 255);
        const blue_tint: u8 = @truncate((@as(u16, brightness) + 50) % 256);
        plane.setCell(x, y, .{
            .char = '*',
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(brightness, brightness, blue_tint),
            .bg = .default,
            .attrs = .{ .bold = rand.boolean() },
        });
    }
}

fn drawWindow(plane: *Plane, title: []const u8, color: Color) void {
    const w = plane.width;
    const h = plane.height;

    // Fill background
    for (0..h) |y| {
        for (0..w) |x| {
            plane.setCell(@intCast(x), @intCast(y), .{
                .char = ' ',
                .combining = .{ 0, 0 },
                .fg = .default,
                .bg = dark_bg,
                .attrs = .{},
            });
        }
    }

    // Draw border
    const border_color = color;
    // Top
    plane.setCell(0, 0, .{ .char = 0x256D, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ╭
    for (1..w - 1) |x| {
        plane.setCell(@intCast(x), 0, .{ .char = 0x2500, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ─
    }
    plane.setCell(w - 1, 0, .{ .char = 0x256E, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ╮

    // Sides
    for (1..h - 1) |y| {
        plane.setCell(0, @intCast(y), .{ .char = 0x2502, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // │
        plane.setCell(w - 1, @intCast(y), .{ .char = 0x2502, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // │
    }

    // Bottom
    plane.setCell(0, h - 1, .{ .char = 0x2570, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ╰
    for (1..w - 1) |x| {
        plane.setCell(@intCast(x), h - 1, .{ .char = 0x2500, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ─
    }
    plane.setCell(w - 1, h - 1, .{ .char = 0x256F, .combining = .{ 0, 0 }, .fg = border_color, .bg = dark_bg, .attrs = .{} }); // ╯

    // Title
    const title_x = (w -| @as(u16, @intCast(title.len))) / 2;
    plane.print(title_x, 0, title, border_color, dark_bg, .{ .bold = true });
}

fn drawSystemInfo(plane: *Plane) void {
    const info = [_][]const u8{
        "termcat v0.1.0",
        "",
        "Features:",
        " - Planes & Z-order",
        " - Auto dirty-track",
        " - True color",
        " - Mouse input",
        " - Diff rendering",
    };

    for (info, 0..) |line, i| {
        const color: Color = if (i == 0) Color.green else if (i == 2) Color.yellow else Color.white;
        plane.print(2, @intCast(i + 2), line, color, dark_bg, .{});
    }
}

fn drawColorPalette(plane: *Plane) void {
    plane.print(2, 2, "16 Colors:", Color.white, dark_bg, .{});

    // Basic 16 colors
    for (0..16) |i| {
        const x: u16 = @intCast(2 + (i % 8) * 3);
        const y: u16 = @intCast(3 + i / 8);
        plane.setCell(x, y, .{ .char = 0x2588, .combining = .{ 0, 0 }, .fg = .{ .index = @intCast(i) }, .bg = dark_bg, .attrs = .{} });
        plane.setCell(x + 1, y, .{ .char = 0x2588, .combining = .{ 0, 0 }, .fg = .{ .index = @intCast(i) }, .bg = dark_bg, .attrs = .{} });
    }

    plane.print(2, 6, "RGB Gradient:", Color.white, dark_bg, .{});

    // RGB gradient
    for (0..24) |i| {
        const x: u16 = @intCast(2 + i);
        const r: u8 = @intCast(i * 10);
        const g: u8 = @intCast(255 -| i * 10);
        const b: u8 = 128;
        plane.setCell(x, 7, .{ .char = 0x2588, .combining = .{ 0, 0 }, .fg = Color.fromRgb(r, g, b), .bg = dark_bg, .attrs = .{} });
    }

    plane.print(2, 9, "Attrs:", Color.white, dark_bg, .{});
    plane.print(9, 9, "Bold", Color.white, dark_bg, .{ .bold = true });
    plane.print(14, 9, "Italic", Color.white, dark_bg, .{ .italic = true });
    plane.print(21, 9, "Uline", Color.white, dark_bg, .{ .underline = true });

    plane.print(2, 11, "Wide: ", Color.white, dark_bg, .{});
    plane.print(8, 11, "日本語", Color.yellow, dark_bg, .{});
}

fn drawBall(plane: *Plane) void {
    drawBallWithColor(plane, Rgb{ .r = 255, .g = 100, .b = 100 });
}

fn drawBallWithColor(plane: *Plane, rgb: Rgb) void {
    const fg = Color.fromRgb(rgb.r, rgb.g, rgb.b);
    plane.setCell(0, 0, .{ .char = '(', .combining = .{ 0, 0 }, .fg = fg, .bg = .default, .attrs = .{ .bold = true } });
    plane.setCell(1, 0, .{ .char = 'o', .combining = .{ 0, 0 }, .fg = fg, .bg = .default, .attrs = .{ .bold = true } });
    plane.setCell(2, 0, .{ .char = ')', .combining = .{ 0, 0 }, .fg = fg, .bg = .default, .attrs = .{ .bold = true } });
}

fn drawStatusBar(plane: *Plane, frame: u32, mx: i32, my: i32, size: termcat.Size) void {
    // Clear status bar
    for (0..plane.width) |x| {
        plane.setCell(@intCast(x), 0, .{
            .char = ' ',
            .combining = .{ 0, 0 },
            .fg = Color.black,
            .bg = Color.white,
            .attrs = .{},
        });
    }

    var buf: [128]u8 = undefined;
    const status_text = std.fmt.bufPrint(&buf, " [Q/q]uit [Esc] [R/r]andomize [Space]Raise | Mouse: ({d},{d}) | Frame: {d} | {d}x{d} ", .{ mx, my, frame, size.width, size.height }) catch " termcat demo ";

    plane.print(0, 0, status_text, Color.black, Color.white, .{});
}

fn isInWindow(plane: *const Plane, win_x: i32, win_y: i32, mx: i32, my: i32) bool {
    return mx >= win_x and mx < win_x + @as(i32, plane.width) and
        my >= win_y and my < win_y + @as(i32, plane.height);
}

fn hueToRgb(hue: u8) Rgb {
    const h = @as(f32, @floatFromInt(hue)) / 256.0 * 6.0;
    const i = @as(u8, @intFromFloat(h)) % 6;
    const f = h - @as(f32, @floatFromInt(@as(u8, @intFromFloat(h))));
    const q = @as(u8, @intFromFloat(255.0 * (1.0 - f)));
    const t = @as(u8, @intFromFloat(255.0 * f));

    return switch (i) {
        0 => Rgb{ .r = 255, .g = t, .b = 0 },
        1 => Rgb{ .r = q, .g = 255, .b = 0 },
        2 => Rgb{ .r = 0, .g = 255, .b = t },
        3 => Rgb{ .r = 0, .g = q, .b = 255 },
        4 => Rgb{ .r = t, .g = 0, .b = 255 },
        else => Rgb{ .r = 255, .g = 0, .b = q },
    };
}

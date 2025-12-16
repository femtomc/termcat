const std = @import("std");
const termcat = @import("termcat");

/// Color Grid Example
///
/// This example demonstrates termcat's color and rendering capabilities:
/// - 16 basic ANSI colors
/// - 256-color palette visualization
/// - True color gradients
/// - Text attributes (bold, italic, underline, etc.)
/// - Color downgrade fallback
///
/// Press 'q' to exit, arrow keys to switch pages.
const Page = enum {
    basic_colors,
    color_256,
    true_color_gradient,
    attributes,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal
    var backend = try termcat.PosixBackend.init(allocator, .{
        .enable_mouse = false,
    });
    defer backend.deinit();

    const size = backend.getSize();
    var renderer = try termcat.Renderer.init(allocator, size, backend.capabilities.color_depth);
    defer renderer.deinit();

    var current_page: Page = .basic_colors;

    while (true) {
        const buf = renderer.buffer();
        buf.clear();

        // Draw header
        drawHeader(buf, current_page, backend.capabilities.color_depth);

        // Draw current page
        switch (current_page) {
            .basic_colors => drawBasicColors(buf),
            .color_256 => draw256Colors(buf),
            .true_color_gradient => drawTrueColorGradient(buf),
            .attributes => drawAttributes(buf),
        }

        // Draw footer (use current renderer size)
        drawFooter(buf, renderer.size().height);

        // Render
        try renderer.flush(backend.writer());
        try backend.flushOutput();

        // Wait for input
        const event = try backend.pollEvent(null);
        if (event) |ev| {
            switch (ev) {
                .key => |key| {
                    if (key.codepoint) |cp| {
                        if (cp == 'q') return;
                    }
                    if (key.special) |sp| {
                        switch (sp) {
                            .left, .up => {
                                current_page = switch (current_page) {
                                    .basic_colors => .attributes,
                                    .color_256 => .basic_colors,
                                    .true_color_gradient => .color_256,
                                    .attributes => .true_color_gradient,
                                };
                            },
                            .right, .down => {
                                current_page = switch (current_page) {
                                    .basic_colors => .color_256,
                                    .color_256 => .true_color_gradient,
                                    .true_color_gradient => .attributes,
                                    .attributes => .basic_colors,
                                };
                            },
                            else => {},
                        }
                    }
                },
                .resize => |new_size| {
                    try renderer.resize(new_size);
                },
                else => {},
            }
        }
    }
}

fn drawHeader(buf: *termcat.Buffer, page: Page, depth: termcat.ColorDepth) void {
    buf.print(0, 0, "termcat Color Grid Demo", termcat.Color.bright_white, termcat.Color.default, .{ .bold = true });

    buf.print(0, 1, "Color depth: ", termcat.Color.default, termcat.Color.default, .{});
    buf.print(13, 1, @tagName(depth), termcat.Color.cyan, termcat.Color.default, .{});

    buf.print(0, 2, "Page: ", termcat.Color.default, termcat.Color.default, .{});
    const page_name = switch (page) {
        .basic_colors => "Basic Colors (16)",
        .color_256 => "256 Colors",
        .true_color_gradient => "True Color Gradient",
        .attributes => "Text Attributes",
    };
    buf.print(6, 2, page_name, termcat.Color.yellow, termcat.Color.default, .{});

    buf.print(0, 3, "=" ** 50, termcat.Color.white, termcat.Color.default, .{});
}

fn drawBasicColors(buf: *termcat.Buffer) void {
    const start_y: u16 = 5;

    // Draw standard 8 colors
    buf.print(0, start_y, "Standard colors (0-7):", termcat.Color.default, termcat.Color.default, .{});
    var x: u16 = 0;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        const color: termcat.Color = .{ .index = i };
        buf.fill(.{ .x = x, .y = start_y + 1, .width = 4, .height = 2 }, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 5;
    }

    // Draw bright 8 colors
    buf.print(0, start_y + 4, "Bright colors (8-15):", termcat.Color.default, termcat.Color.default, .{});
    x = 0;
    i = 8;
    while (i < 16) : (i += 1) {
        const color: termcat.Color = .{ .index = i };
        buf.fill(.{ .x = x, .y = start_y + 5, .width = 4, .height = 2 }, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 5;
    }

    // Draw color names with foreground
    buf.print(0, start_y + 8, "Foreground colors:", termcat.Color.default, termcat.Color.default, .{});

    const color_names = [_]struct { name: []const u8, color: termcat.Color }{
        .{ .name = "black", .color = termcat.Color.black },
        .{ .name = "red", .color = termcat.Color.red },
        .{ .name = "green", .color = termcat.Color.green },
        .{ .name = "yellow", .color = termcat.Color.yellow },
        .{ .name = "blue", .color = termcat.Color.blue },
        .{ .name = "magenta", .color = termcat.Color.magenta },
        .{ .name = "cyan", .color = termcat.Color.cyan },
        .{ .name = "white", .color = termcat.Color.white },
    };

    var row: u16 = start_y + 9;
    for (color_names) |item| {
        buf.print(2, row, item.name, item.color, termcat.Color.default, .{});
        row += 1;
    }
}

fn draw256Colors(buf: *termcat.Buffer) void {
    const start_y: u16 = 5;

    buf.print(0, start_y, "6x6x6 Color Cube (16-231):", termcat.Color.default, termcat.Color.default, .{});

    // Draw 6x6x6 color cube
    var idx: u8 = 16;
    var row: u16 = start_y + 1;
    var cube_z: u8 = 0;
    while (cube_z < 6) : (cube_z += 1) {
        var cube_y: u8 = 0;
        while (cube_y < 6) : (cube_y += 1) {
            var x: u16 = cube_z * 7;
            var cube_x: u8 = 0;
            while (cube_x < 6) : (cube_x += 1) {
                const color: termcat.Color = .{ .index = idx };
                buf.setCell(x, row, .{
                    .char = ' ',
                    .fg = termcat.Color.default,
                    .bg = color,
                    .attrs = .{},
                });
                x += 1;
                idx +|= 1;
            }
            row += 1;
        }
        row = start_y + 1;
    }

    // Draw grayscale ramp
    buf.print(0, start_y + 8, "Grayscale (232-255):", termcat.Color.default, termcat.Color.default, .{});
    var x: u16 = 0;
    var gray_idx: u8 = 232;
    while (gray_idx <= 255) : (gray_idx +|= 1) {
        const color: termcat.Color = .{ .index = gray_idx };
        buf.setCell(x, start_y + 9, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
        if (gray_idx == 255) break;
    }
}

fn drawTrueColorGradient(buf: *termcat.Buffer) void {
    const start_y: u16 = 5;

    buf.print(0, start_y, "RGB Gradients (24-bit):", termcat.Color.default, termcat.Color.default, .{});

    // Red gradient
    buf.print(0, start_y + 2, "R:", termcat.Color.red, termcat.Color.default, .{});
    var x: u16 = 3;
    var val: u16 = 0;
    while (val < 256) : (val += 8) {
        const color = termcat.Color.fromRgb(@intCast(val), 0, 0);
        buf.setCell(x, start_y + 2, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
    }

    // Green gradient
    buf.print(0, start_y + 3, "G:", termcat.Color.green, termcat.Color.default, .{});
    x = 3;
    val = 0;
    while (val < 256) : (val += 8) {
        const color = termcat.Color.fromRgb(0, @intCast(val), 0);
        buf.setCell(x, start_y + 3, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
    }

    // Blue gradient
    buf.print(0, start_y + 4, "B:", termcat.Color.blue, termcat.Color.default, .{});
    x = 3;
    val = 0;
    while (val < 256) : (val += 8) {
        const color = termcat.Color.fromRgb(0, 0, @intCast(val));
        buf.setCell(x, start_y + 4, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
    }

    // Rainbow gradient (HSL)
    buf.print(0, start_y + 6, "HSL Rainbow:", termcat.Color.default, termcat.Color.default, .{});
    x = 0;
    var hue: u16 = 0;
    while (hue < 360) : (hue += 6) {
        const color = termcat.Color.fromHsl(hue, 100, 50);
        buf.setCell(x, start_y + 7, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        buf.setCell(x, start_y + 8, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
    }

    // Grayscale using fromGray
    buf.print(0, start_y + 10, "Grayscale:", termcat.Color.default, termcat.Color.default, .{});
    x = 0;
    var gray: u16 = 0;
    while (gray < 256) : (gray += 4) {
        const color = termcat.Color.fromGray(@intCast(gray));
        buf.setCell(x, start_y + 11, .{
            .char = ' ',
            .fg = termcat.Color.default,
            .bg = color,
            .attrs = .{},
        });
        x += 1;
    }
}

fn drawAttributes(buf: *termcat.Buffer) void {
    const start_y: u16 = 5;

    buf.print(0, start_y, "Text Attributes:", termcat.Color.default, termcat.Color.default, .{});

    buf.print(2, start_y + 2, "Normal text", termcat.Color.white, termcat.Color.default, .{});
    buf.print(2, start_y + 3, "Bold text", termcat.Color.white, termcat.Color.default, .{ .bold = true });
    buf.print(2, start_y + 4, "Italic text", termcat.Color.white, termcat.Color.default, .{ .italic = true });
    buf.print(2, start_y + 5, "Underline text", termcat.Color.white, termcat.Color.default, .{ .underline = true });
    buf.print(2, start_y + 6, "Dim text", termcat.Color.white, termcat.Color.default, .{ .dim = true });
    buf.print(2, start_y + 7, "Reverse text", termcat.Color.white, termcat.Color.default, .{ .reverse = true });
    buf.print(2, start_y + 8, "Strikethrough", termcat.Color.white, termcat.Color.default, .{ .strikethrough = true });
    buf.print(2, start_y + 9, "Blink text", termcat.Color.white, termcat.Color.default, .{ .blink = true });

    buf.print(0, start_y + 11, "Combined Attributes:", termcat.Color.default, termcat.Color.default, .{});
    buf.print(2, start_y + 12, "Bold + Italic", termcat.Color.cyan, termcat.Color.default, .{ .bold = true, .italic = true });
    buf.print(2, start_y + 13, "Bold + Underline", termcat.Color.green, termcat.Color.default, .{ .bold = true, .underline = true });
    buf.print(2, start_y + 14, "Italic + Dim", termcat.Color.yellow, termcat.Color.default, .{ .italic = true, .dim = true });

    buf.print(0, start_y + 16, "Colors with Attributes:", termcat.Color.default, termcat.Color.default, .{});
    buf.print(2, start_y + 17, "Red Bold", termcat.Color.red, termcat.Color.default, .{ .bold = true });
    buf.print(2, start_y + 18, "Green Italic", termcat.Color.green, termcat.Color.default, .{ .italic = true });
    buf.print(2, start_y + 19, "Blue Underline", termcat.Color.blue, termcat.Color.default, .{ .underline = true });
    buf.print(2, start_y + 20, "Magenta on Cyan", termcat.Color.magenta, termcat.Color.cyan, .{});
}

fn drawFooter(buf: *termcat.Buffer, height: u16) void {
    buf.print(0, height -| 1, "Arrow keys: switch pages | q: quit", termcat.Color.bright_black, termcat.Color.default, .{});
}

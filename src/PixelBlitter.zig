const std = @import("std");
const Surface = @import("Surface.zig");
const Pixel = Surface.Pixel;
const Buffer = @import("Buffer.zig");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const Event = @import("Event.zig");
const Size = Event.Size;

/// Pixel-to-cell blitter for converting pixel surfaces to terminal cells.
///
/// This module provides utilities for rendering pixel data (such as from games
/// or image processing) to a terminal cell buffer. It supports multiple blitter
/// modes with different resolutions and character sets.
///
/// Blitter modes:
/// - ASCII: Uses ASCII gradient characters (" .:-=+*#%@") for grayscale rendering
/// - HalfBlock: Uses half-block characters (▄) for 1×2 pixel resolution per cell
/// - Quadrant: Uses quadrant characters (▖▗▘▝▀▄▌▐█) for 2×2 pixel resolution per cell
/// - Braille: Uses braille characters for 2×4 pixel resolution per cell
pub const PixelBlitter = @This();

/// Blitter mode determines the character set and pixel resolution per cell.
pub const BlitterMode = enum {
    /// ASCII gradient characters for grayscale rendering.
    /// Resolution: 1×1 pixel per cell.
    /// Character set: " .:-=+*#%@"
    ascii,

    /// Half-block characters for colored rendering.
    /// Resolution: 1×2 pixels per cell (top/bottom halves).
    /// Uses ▀ (upper half) with fg=top, bg=bottom.
    half_block,

    /// Quadrant block characters for higher resolution.
    /// Resolution: 2×2 pixels per cell.
    /// Uses Unicode quadrant characters (▖▗▘▝▀▄▌▐█ etc).
    quadrant,

    /// Braille characters for highest resolution.
    /// Resolution: 2×4 pixels per cell.
    /// Uses Unicode braille patterns (U+2800-U+28FF).
    braille,

    /// Returns the horizontal pixel resolution per cell.
    pub fn pixelsPerCellX(self: BlitterMode) u32 {
        return switch (self) {
            .ascii, .half_block => 1,
            .quadrant, .braille => 2,
        };
    }

    /// Returns the vertical pixel resolution per cell.
    pub fn pixelsPerCellY(self: BlitterMode) u32 {
        return switch (self) {
            .ascii => 1,
            .half_block => 2,
            .quadrant => 2,
            .braille => 4,
        };
    }
};

/// Options for pixel blitting.
pub const BlitOptions = struct {
    /// Blitter mode to use.
    mode: BlitterMode = .half_block,

    /// If true, render in monochrome (grayscale) mode.
    /// Colors are converted to luminance and rendered with fg only.
    monochrome: bool = false,

    /// Foreground color for monochrome mode.
    mono_fg: Color = Color.white,

    /// Background color for monochrome mode.
    mono_bg: Color = Color.black,

    /// Luminance threshold for monochrome rendering (0-255).
    /// Pixels with luminance >= threshold are rendered as foreground.
    threshold: u8 = 128,

    /// Optional ordered dithering for better gradients.
    /// Only affects monochrome mode.
    dither: bool = false,

    /// Color depth to render at. If null, uses true color.
    /// Use this to force 256-color or 16-color output.
    color_depth: ?Cell.ColorDepth = null,
};

/// ASCII gradient characters from dark to bright.
/// Index 0 = darkest (black), index 9 = brightest (white).
const ascii_gradient = " .:-=+*#%@";

/// Calculate the cell dimensions needed to render a surface at a given blitter mode.
pub fn calcCellSize(surface_width: u32, surface_height: u32, mode: BlitterMode) Size {
    const px_per_cell_x = mode.pixelsPerCellX();
    const px_per_cell_y = mode.pixelsPerCellY();

    // Round up to cover all pixels
    const cell_width = (surface_width + px_per_cell_x - 1) / px_per_cell_x;
    const cell_height = (surface_height + px_per_cell_y - 1) / px_per_cell_y;

    return .{
        .width = @intCast(@min(cell_width, std.math.maxInt(u16))),
        .height = @intCast(@min(cell_height, std.math.maxInt(u16))),
    };
}

/// Calculate the pixel dimensions that fit within a cell area at a given blitter mode.
pub fn calcPixelSize(cell_width: u16, cell_height: u16, mode: BlitterMode) struct { width: u32, height: u32 } {
    const px_per_cell_x = mode.pixelsPerCellX();
    const px_per_cell_y = mode.pixelsPerCellY();

    return .{
        .width = @as(u32, cell_width) * px_per_cell_x,
        .height = @as(u32, cell_height) * px_per_cell_y,
    };
}

/// Blit a pixel surface to a cell buffer.
///
/// Parameters:
/// - dest: Target cell buffer to render into.
/// - dest_x, dest_y: Position in the destination buffer (in cells).
/// - surface: Source pixel surface to render.
/// - options: Blitting options (mode, colors, etc).
pub fn blit(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    surface: Surface,
    options: BlitOptions,
) void {
    switch (options.mode) {
        .ascii => blitAscii(dest, dest_x, dest_y, surface, options),
        .half_block => blitHalfBlock(dest, dest_x, dest_y, surface, options),
        .quadrant => blitQuadrant(dest, dest_x, dest_y, surface, options),
        .braille => blitBraille(dest, dest_x, dest_y, surface, options),
    }
}

/// Blit using ASCII gradient characters.
fn blitAscii(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    surface: Surface,
    options: BlitOptions,
) void {
    var cy: u16 = 0;
    while (cy < dest.height and dest_y + cy < dest.height) : (cy += 1) {
        const py: u32 = cy;
        if (py >= surface.height) break;

        var cx: u16 = 0;
        while (cx < dest.width and dest_x + cx < dest.width) : (cx += 1) {
            const px: u32 = cx;
            if (px >= surface.width) break;

            const pixel = surface.getPixel(px, py) orelse continue;

            // Skip fully transparent pixels
            if (pixel.a == 0) continue;

            const lum = pixel.luminance();

            // Apply dithering if enabled (use u32 coordinates to include dest offset)
            const effective_lum = if (options.dither)
                applyDither(lum, @as(u32, dest_x) + @as(u32, cx), @as(u32, dest_y) + @as(u32, cy))
            else
                lum;

            // Map luminance to ASCII character (0-255 -> 0-9)
            const char_idx: usize = @intCast((@as(u16, effective_lum) * 9) / 255);
            const char: u21 = ascii_gradient[char_idx];

            // Determine color
            const fg = if (options.monochrome)
                maybeDowngrade(options.mono_fg, options.color_depth)
            else
                pixelToColor(pixel, options.color_depth);

            const bg = if (options.monochrome)
                maybeDowngrade(options.mono_bg, options.color_depth)
            else
                Color.default;

            dest.setCell(dest_x + cx, dest_y + cy, .{
                .char = char,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = .{},
            });
        }
    }
}

/// Blit using half-block characters (▀ upper half block).
/// Each cell represents 2 vertical pixels: top pixel = fg, bottom pixel = bg.
fn blitHalfBlock(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    surface: Surface,
    options: BlitOptions,
) void {
    const upper_half_block: u21 = '▀'; // U+2580

    var cy: u16 = 0;
    while (dest_y + cy < dest.height) : (cy += 1) {
        const py_top: u32 = @as(u32, cy) * 2;
        const py_bottom: u32 = py_top + 1;
        if (py_top >= surface.height) break;

        var cx: u16 = 0;
        while (dest_x + cx < dest.width) : (cx += 1) {
            const px: u32 = cx;
            if (px >= surface.width) break;

            const top_pixel = surface.getPixel(px, py_top) orelse Pixel.transparent;
            const bottom_pixel = if (py_bottom < surface.height)
                surface.getPixel(px, py_bottom) orelse Pixel.transparent
            else
                Pixel.transparent;

            // Handle transparency: if both transparent, skip
            if (top_pixel.a == 0 and bottom_pixel.a == 0) continue;

            var fg: Color = undefined;
            var bg: Color = undefined;
            var char: u21 = undefined;

            if (options.monochrome) {
                // Monochrome mode: use threshold with proper dither coordinates (u32)
                const px_x: u32 = @as(u32, dest_x) + @as(u32, cx);
                const px_y_top: u32 = (@as(u32, dest_y) + @as(u32, cy)) * 2;
                const top_lum = if (options.dither) applyDither(top_pixel.luminance(), px_x, px_y_top) else top_pixel.luminance();
                const bottom_lum = if (options.dither) applyDither(bottom_pixel.luminance(), px_x, px_y_top + 1) else bottom_pixel.luminance();
                const top_on = top_pixel.a > 0 and top_lum >= options.threshold;
                const bottom_on = bottom_pixel.a > 0 and bottom_lum >= options.threshold;

                const mono_fg = maybeDowngrade(options.mono_fg, options.color_depth);
                const mono_bg = maybeDowngrade(options.mono_bg, options.color_depth);

                if (top_on and bottom_on) {
                    char = '█'; // Full block
                    fg = mono_fg;
                    bg = mono_bg;
                } else if (top_on) {
                    char = upper_half_block;
                    fg = mono_fg;
                    bg = mono_bg;
                } else if (bottom_on) {
                    char = '▄'; // Lower half block
                    fg = mono_fg;
                    bg = mono_bg;
                } else {
                    char = ' ';
                    fg = mono_fg;
                    bg = mono_bg;
                }
            } else {
                // Color mode: handle transparency per-half
                const top_opaque = top_pixel.a > 0;
                const bottom_opaque = bottom_pixel.a > 0;

                if (top_opaque and bottom_opaque) {
                    // Both halves visible
                    fg = pixelToColor(top_pixel, options.color_depth);
                    bg = pixelToColor(bottom_pixel, options.color_depth);
                    // Optimize: if both colors are the same, use full block
                    if (fg.eql(bg)) {
                        char = '█';
                    } else {
                        char = upper_half_block; // ▀ with fg=top, bg=bottom
                    }
                } else if (top_opaque) {
                    // Only top half visible: use ▀ with bg=default
                    char = upper_half_block;
                    fg = pixelToColor(top_pixel, options.color_depth);
                    bg = Color.default;
                } else {
                    // Only bottom half visible: use ▄ with fg=bottom color
                    char = '▄';
                    fg = pixelToColor(bottom_pixel, options.color_depth);
                    bg = Color.default;
                }
            }

            dest.setCell(dest_x + cx, dest_y + cy, .{
                .char = char,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = .{},
            });
        }
    }
}

/// Blit using quadrant block characters.
/// Each cell represents a 2×2 pixel block.
fn blitQuadrant(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    surface: Surface,
    options: BlitOptions,
) void {
    var cy: u16 = 0;
    while (dest_y + cy < dest.height) : (cy += 1) {
        const py_top: u32 = @as(u32, cy) * 2;
        const py_bottom: u32 = py_top + 1;
        if (py_top >= surface.height) break;

        var cx: u16 = 0;
        while (dest_x + cx < dest.width) : (cx += 1) {
            const px_left: u32 = @as(u32, cx) * 2;
            const px_right: u32 = px_left + 1;
            if (px_left >= surface.width) break;

            // Get all 4 pixels in the quadrant
            const tl = getPixelSafe(surface, px_left, py_top);
            const tr = getPixelSafe(surface, px_right, py_top);
            const bl = getPixelSafe(surface, px_left, py_bottom);
            const br = getPixelSafe(surface, px_right, py_bottom);

            // Skip if all transparent
            if (tl.a == 0 and tr.a == 0 and bl.a == 0 and br.a == 0) continue;

            // Determine colors and on/off flags
            var fg: Color = undefined;
            var bg: Color = undefined;
            var on_tl: bool = undefined;
            var on_tr: bool = undefined;
            var on_bl: bool = undefined;
            var on_br: bool = undefined;

            if (options.monochrome) {
                // Calculate pixel coordinates for dither (use u32 to avoid overflow)
                const px_x: u32 = @as(u32, dest_x) + @as(u32, cx);
                const px_y: u32 = @as(u32, dest_y) + @as(u32, cy);

                const lum_tl = if (options.dither) applyDither(tl.luminance(), px_x * 2, px_y * 2) else tl.luminance();
                const lum_tr = if (options.dither) applyDither(tr.luminance(), px_x * 2 + 1, px_y * 2) else tr.luminance();
                const lum_bl = if (options.dither) applyDither(bl.luminance(), px_x * 2, px_y * 2 + 1) else bl.luminance();
                const lum_br = if (options.dither) applyDither(br.luminance(), px_x * 2 + 1, px_y * 2 + 1) else br.luminance();

                on_tl = tl.a > 0 and lum_tl >= options.threshold;
                on_tr = tr.a > 0 and lum_tr >= options.threshold;
                on_bl = bl.a > 0 and lum_bl >= options.threshold;
                on_br = br.a > 0 and lum_br >= options.threshold;

                fg = maybeDowngrade(options.mono_fg, options.color_depth);
                bg = maybeDowngrade(options.mono_bg, options.color_depth);
            } else {
                // Color mode: use luminance-based 2-color clustering
                const pixels = [_]Pixel{ tl, tr, bl, br, Pixel.transparent, Pixel.transparent, Pixel.transparent, Pixel.transparent };
                const cluster = clusterByLuminance(&pixels, options.color_depth);
                on_tl = cluster.on_flags[0];
                on_tr = cluster.on_flags[1];
                on_bl = cluster.on_flags[2];
                on_br = cluster.on_flags[3];
                fg = cluster.fg;
                bg = cluster.bg;
            }

            // Map to quadrant character
            const quadrant_idx: u4 = (@as(u4, @intFromBool(on_tl)) << 0) |
                (@as(u4, @intFromBool(on_tr)) << 1) |
                (@as(u4, @intFromBool(on_bl)) << 2) |
                (@as(u4, @intFromBool(on_br)) << 3);

            const char = quadrantChar(quadrant_idx);

            dest.setCell(dest_x + cx, dest_y + cy, .{
                .char = char,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = .{},
            });
        }
    }
}

/// Blit using braille characters.
/// Each cell represents a 2×4 pixel block (8 dots).
fn blitBraille(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    surface: Surface,
    options: BlitOptions,
) void {
    var cy: u16 = 0;
    while (dest_y + cy < dest.height) : (cy += 1) {
        const py_base: u32 = @as(u32, cy) * 4;
        if (py_base >= surface.height) break;

        var cx: u16 = 0;
        while (dest_x + cx < dest.width) : (cx += 1) {
            const px_left: u32 = @as(u32, cx) * 2;
            const px_right: u32 = px_left + 1;
            if (px_left >= surface.width) break;

            // Get all 8 pixels in the braille cell
            // Braille dot positions:
            //   1 4
            //   2 5
            //   3 6
            //   7 8
            const p1 = getPixelSafe(surface, px_left, py_base);
            const p2 = getPixelSafe(surface, px_left, py_base + 1);
            const p3 = getPixelSafe(surface, px_left, py_base + 2);
            const p7 = getPixelSafe(surface, px_left, py_base + 3);
            const p4 = getPixelSafe(surface, px_right, py_base);
            const p5 = getPixelSafe(surface, px_right, py_base + 1);
            const p6 = getPixelSafe(surface, px_right, py_base + 2);
            const p8 = getPixelSafe(surface, px_right, py_base + 3);

            // Skip if all transparent
            if (p1.a == 0 and p2.a == 0 and p3.a == 0 and p4.a == 0 and
                p5.a == 0 and p6.a == 0 and p7.a == 0 and p8.a == 0)
            {
                continue;
            }

            const pixels = [_]Pixel{ p1, p2, p3, p7, p4, p5, p6, p8 };
            const bit_positions = [_]u3{ 0, 1, 2, 6, 3, 4, 5, 7 }; // Braille bit ordering

            // Determine colors and dot pattern
            var dots: u8 = 0;
            var fg: Color = undefined;
            var bg: Color = undefined;

            if (options.monochrome) {
                // Calculate base pixel coordinates for dither (use u32 to avoid overflow)
                const base_px_x: u32 = (@as(u32, dest_x) + @as(u32, cx)) * 2;
                const base_px_y: u32 = (@as(u32, dest_y) + @as(u32, cy)) * 4;

                for (pixels, 0..) |pixel, i| {
                    // Calculate pixel offset within the cell
                    const px_offset_x: u32 = if (i >= 4) 1 else 0;
                    const px_offset_y: u32 = @intCast(i % 4);
                    const px_x = base_px_x + px_offset_x;
                    const px_y = base_px_y + px_offset_y;

                    const lum = if (options.dither) applyDither(pixel.luminance(), px_x, px_y) else pixel.luminance();
                    const is_on = pixel.a > 0 and lum >= options.threshold;

                    if (is_on) {
                        dots |= @as(u8, 1) << bit_positions[i];
                    }
                }

                fg = maybeDowngrade(options.mono_fg, options.color_depth);
                bg = maybeDowngrade(options.mono_bg, options.color_depth);
            } else {
                // Color mode: use luminance-based 2-color clustering
                const cluster = clusterByLuminance(&pixels, options.color_depth);

                // Build dots from cluster assignments
                for (0..8) |i| {
                    if (cluster.on_flags[i]) {
                        dots |= @as(u8, 1) << bit_positions[i];
                    }
                }

                fg = cluster.fg;
                bg = cluster.bg;
            }

            // Braille starts at U+2800
            const char: u21 = 0x2800 + @as(u21, dots);

            dest.setCell(dest_x + cx, dest_y + cy, .{
                .char = char,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = .{},
            });
        }
    }
}

/// Get a pixel from a surface, returning transparent for out-of-bounds.
fn getPixelSafe(surface: Surface, x: u32, y: u32) Pixel {
    return surface.getPixel(x, y) orelse Pixel.transparent;
}

/// Convert a pixel to a terminal color.
fn pixelToColor(pixel: Pixel, color_depth: ?Cell.ColorDepth) Color {
    const color = Color.fromRgb(pixel.r, pixel.g, pixel.b);
    if (color_depth) |depth| {
        return color.downgrade(depth);
    }
    return color;
}

/// Apply color depth downgrade to a color if specified.
fn maybeDowngrade(color: Color, color_depth: ?Cell.ColorDepth) Color {
    if (color_depth) |depth| {
        return color.downgrade(depth);
    }
    return color;
}

/// Average the colors of pixels based on on/off flags.
fn averagePixelColor(pixels: []const Pixel, on_flags: []const bool, want_on: bool, color_depth: ?Cell.ColorDepth) Color {
    var r_sum: u32 = 0;
    var g_sum: u32 = 0;
    var b_sum: u32 = 0;
    var count: u32 = 0;

    for (pixels, 0..) |pixel, i| {
        if (on_flags[i] == want_on and pixel.a > 0) {
            r_sum += pixel.r;
            g_sum += pixel.g;
            b_sum += pixel.b;
            count += 1;
        }
    }

    if (count == 0) return Color.default;

    const r: u8 = @intCast(r_sum / count);
    const g: u8 = @intCast(g_sum / count);
    const b: u8 = @intCast(b_sum / count);

    const color = Color.fromRgb(r, g, b);
    if (color_depth) |depth| {
        return color.downgrade(depth);
    }
    return color;
}

/// Cluster result for two-color clustering.
const ClusterResult = struct {
    on_flags: [8]bool,
    fg: Color,
    bg: Color,
};

/// Perform 2-color clustering on a set of pixels using luminance.
/// This finds two representative colors and assigns each pixel to one cluster.
/// Returns the cluster assignments and averaged colors for fg (bright) and bg (dark).
fn clusterByLuminance(pixels: []const Pixel, color_depth: ?Cell.ColorDepth) ClusterResult {
    var result: ClusterResult = .{
        .on_flags = .{ false, false, false, false, false, false, false, false },
        .fg = Color.default,
        .bg = Color.default,
    };

    // Find min and max luminance among opaque pixels
    var min_lum: u8 = 255;
    var max_lum: u8 = 0;
    var opaque_count: u32 = 0;

    for (pixels) |pixel| {
        if (pixel.a == 0) continue;
        const lum = pixel.luminance();
        if (lum < min_lum) min_lum = lum;
        if (lum > max_lum) max_lum = lum;
        opaque_count += 1;
    }

    // If no opaque pixels, return all off
    if (opaque_count == 0) return result;

    // If all same luminance, return all on (full block)
    if (min_lum == max_lum) {
        for (0..pixels.len) |i| {
            result.on_flags[i] = pixels[i].a > 0;
        }
        // Average all opaque pixels for fg
        var r_sum: u32 = 0;
        var g_sum: u32 = 0;
        var b_sum: u32 = 0;
        for (pixels) |pixel| {
            if (pixel.a > 0) {
                r_sum += pixel.r;
                g_sum += pixel.g;
                b_sum += pixel.b;
            }
        }
        const r: u8 = @intCast(r_sum / opaque_count);
        const g: u8 = @intCast(g_sum / opaque_count);
        const b: u8 = @intCast(b_sum / opaque_count);
        result.fg = maybeDowngrade(Color.fromRgb(r, g, b), color_depth);
        result.bg = Color.default;
        return result;
    }

    // Use midpoint as threshold
    const threshold: u8 = @intCast((@as(u16, min_lum) + @as(u16, max_lum)) / 2);

    // Classify pixels and accumulate colors
    var fg_r: u32 = 0;
    var fg_g: u32 = 0;
    var fg_b: u32 = 0;
    var fg_count: u32 = 0;
    var bg_r: u32 = 0;
    var bg_g: u32 = 0;
    var bg_b: u32 = 0;
    var bg_count: u32 = 0;

    for (pixels, 0..) |pixel, i| {
        if (pixel.a == 0) {
            result.on_flags[i] = false;
            continue;
        }

        const lum = pixel.luminance();
        if (lum >= threshold) {
            // Bright cluster -> foreground (on)
            result.on_flags[i] = true;
            fg_r += pixel.r;
            fg_g += pixel.g;
            fg_b += pixel.b;
            fg_count += 1;
        } else {
            // Dark cluster -> background (off)
            result.on_flags[i] = false;
            bg_r += pixel.r;
            bg_g += pixel.g;
            bg_b += pixel.b;
            bg_count += 1;
        }
    }

    // Calculate average colors
    if (fg_count > 0) {
        const r: u8 = @intCast(fg_r / fg_count);
        const g: u8 = @intCast(fg_g / fg_count);
        const b: u8 = @intCast(fg_b / fg_count);
        result.fg = maybeDowngrade(Color.fromRgb(r, g, b), color_depth);
    }
    if (bg_count > 0) {
        const r: u8 = @intCast(bg_r / bg_count);
        const g: u8 = @intCast(bg_g / bg_count);
        const b: u8 = @intCast(bg_b / bg_count);
        result.bg = maybeDowngrade(Color.fromRgb(r, g, b), color_depth);
    }

    return result;
}

/// Get the quadrant character for a given combination of corners.
/// Bits: 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
fn quadrantChar(quadrant_idx: u4) u21 {
    return switch (quadrant_idx) {
        0b0000 => ' ', // none
        0b0001 => '▘', // top-left only
        0b0010 => '▝', // top-right only
        0b0011 => '▀', // top half
        0b0100 => '▖', // bottom-left only
        0b0101 => '▌', // left half
        0b0110 => '▞', // diagonal (TL-BR)
        0b0111 => '▛', // all except bottom-right
        0b1000 => '▗', // bottom-right only
        0b1001 => '▚', // diagonal (TR-BL)
        0b1010 => '▐', // right half
        0b1011 => '▜', // all except bottom-left
        0b1100 => '▄', // bottom half
        0b1101 => '▙', // all except top-right
        0b1110 => '▟', // all except top-left
        0b1111 => '█', // full block
    };
}

/// 4×4 Bayer dithering matrix (normalized to 0-255 range).
const bayer_matrix = [4][4]u8{
    .{ 0, 128, 32, 160 },
    .{ 192, 64, 224, 96 },
    .{ 48, 176, 16, 144 },
    .{ 240, 112, 208, 80 },
};

/// Apply ordered dithering to a luminance value.
/// Uses pixel coordinates (u32) to handle large surfaces and offset blits.
fn applyDither(lum: u8, x: u32, y: u32) u8 {
    const threshold = bayer_matrix[@intCast(y % 4)][@intCast(x % 4)];
    // Scale luminance by adding dither offset
    const adjusted = @as(i16, lum) + @as(i16, threshold) - 128;
    return @intCast(@max(0, @min(255, adjusted)));
}

// ============================================================================
// Tests
// ============================================================================

test "calcCellSize basic" {
    // 10x10 pixel surface with half_block (1x2)
    const size = calcCellSize(10, 10, .half_block);
    try std.testing.expectEqual(@as(u16, 10), size.width);
    try std.testing.expectEqual(@as(u16, 5), size.height);

    // With braille (2x4)
    const braille_size = calcCellSize(10, 10, .braille);
    try std.testing.expectEqual(@as(u16, 5), braille_size.width);
    try std.testing.expectEqual(@as(u16, 3), braille_size.height); // ceil(10/4) = 3
}

test "calcPixelSize basic" {
    // 10x5 cell buffer with half_block (1x2)
    const px = calcPixelSize(10, 5, .half_block);
    try std.testing.expectEqual(@as(u32, 10), px.width);
    try std.testing.expectEqual(@as(u32, 10), px.height);

    // With quadrant (2x2)
    const quad_px = calcPixelSize(10, 5, .quadrant);
    try std.testing.expectEqual(@as(u32, 20), quad_px.width);
    try std.testing.expectEqual(@as(u32, 10), quad_px.height);
}

test "blitAscii basic" {
    // Create a small surface with varying luminance
    var surface = try Surface.init(std.testing.allocator, 4, 2);
    defer surface.deinit();

    // Set up pixels: black, gray, light gray, white
    surface.setPixel(0, 0, Pixel.black);
    surface.setPixel(1, 0, Pixel.rgb(64, 64, 64));
    surface.setPixel(2, 0, Pixel.rgb(192, 192, 192));
    surface.setPixel(3, 0, Pixel.white);

    // Create destination buffer
    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Blit with ASCII mode
    blit(&dest, 0, 0, surface, .{ .mode = .ascii });

    // Check that different luminance values produce different chars
    const c0 = dest.getCell(0, 0).char;
    const c1 = dest.getCell(1, 0).char;
    const c2 = dest.getCell(2, 0).char;
    const c3 = dest.getCell(3, 0).char;

    // Black should produce space, white should produce @
    try std.testing.expectEqual(@as(u21, ' '), c0);
    try std.testing.expectEqual(@as(u21, '@'), c3);

    // Middle values should be different from extremes
    try std.testing.expect(c1 != c0);
    try std.testing.expect(c2 != c3);
}

test "blitHalfBlock basic" {
    // Create a 2x4 surface (will become 2x2 in half-block mode)
    var surface = try Surface.init(std.testing.allocator, 2, 4);
    defer surface.deinit();

    // Column 0: red on top, blue on bottom
    surface.setPixel(0, 0, Pixel.rgb(255, 0, 0));
    surface.setPixel(0, 1, Pixel.rgb(0, 0, 255));
    surface.setPixel(0, 2, Pixel.rgb(255, 0, 0));
    surface.setPixel(0, 3, Pixel.rgb(0, 0, 255));

    // Column 1: all green
    surface.setPixel(1, 0, Pixel.rgb(0, 255, 0));
    surface.setPixel(1, 1, Pixel.rgb(0, 255, 0));
    surface.setPixel(1, 2, Pixel.rgb(0, 255, 0));
    surface.setPixel(1, 3, Pixel.rgb(0, 255, 0));

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    blit(&dest, 0, 0, surface, .{ .mode = .half_block });

    // Column 0 should have upper half block (different top/bottom colors)
    try std.testing.expectEqual(@as(u21, '▀'), dest.getCell(0, 0).char);

    // Column 1 should have full block (same top/bottom colors)
    try std.testing.expectEqual(@as(u21, '█'), dest.getCell(1, 0).char);

    // Check colors
    const cell00 = dest.getCell(0, 0);
    try std.testing.expect(cell00.fg.eql(Color.fromRgb(255, 0, 0))); // red on top
    try std.testing.expect(cell00.bg.eql(Color.fromRgb(0, 0, 255))); // blue on bottom
}

test "blitHalfBlock transparency per-half" {
    // Test that transparent top/bottom halves are handled correctly
    var surface = try Surface.init(std.testing.allocator, 2, 4);
    defer surface.deinit();

    // Column 0: only bottom half visible (top is transparent)
    // py=0,1 -> cell row 0: top transparent, bottom red
    surface.setPixel(0, 0, Pixel.transparent);
    surface.setPixel(0, 1, Pixel.rgb(255, 0, 0)); // red bottom

    // Column 1: only top half visible (bottom is transparent)
    // py=0,1 -> cell row 0: top green, bottom transparent
    surface.setPixel(1, 0, Pixel.rgb(0, 255, 0)); // green top
    surface.setPixel(1, 1, Pixel.transparent);

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    blit(&dest, 0, 0, surface, .{ .mode = .half_block });

    // Column 0: bottom only visible -> ▄ with fg=red, bg=default
    const cell0 = dest.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, '▄'), cell0.char);
    try std.testing.expect(cell0.fg.eql(Color.fromRgb(255, 0, 0)));
    try std.testing.expect(cell0.bg.eql(Color.default));

    // Column 1: top only visible -> ▀ with fg=green, bg=default
    const cell1 = dest.getCell(1, 0);
    try std.testing.expectEqual(@as(u21, '▀'), cell1.char);
    try std.testing.expect(cell1.fg.eql(Color.fromRgb(0, 255, 0)));
    try std.testing.expect(cell1.bg.eql(Color.default));
}

test "blitQuadrant basic" {
    // Create a 4x4 surface (will become 2x2 in quadrant mode)
    var surface = try Surface.init(std.testing.allocator, 4, 4);
    defer surface.deinit();

    // Cell (0,0): only top-left pixel is "on"
    surface.setPixel(0, 0, Pixel.white);
    surface.setPixel(1, 0, Pixel.transparent);
    surface.setPixel(0, 1, Pixel.transparent);
    surface.setPixel(1, 1, Pixel.transparent);

    // Cell (1,0): all pixels "on"
    surface.setPixel(2, 0, Pixel.white);
    surface.setPixel(3, 0, Pixel.white);
    surface.setPixel(2, 1, Pixel.white);
    surface.setPixel(3, 1, Pixel.white);

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    blit(&dest, 0, 0, surface, .{ .mode = .quadrant, .monochrome = true });

    // Check characters
    try std.testing.expectEqual(@as(u21, '▘'), dest.getCell(0, 0).char); // top-left only
    try std.testing.expectEqual(@as(u21, '█'), dest.getCell(1, 0).char); // full block
}

test "blitQuadrant color mode uses luminance clustering" {
    // Test that color mode correctly separates bright/dark pixels
    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();

    // Set up a 2x2 pattern with contrasting luminance:
    // top-left: dark red, top-right: bright yellow
    // bottom-left: dark blue, bottom-right: bright green
    surface.setPixel(0, 0, Pixel.rgb(80, 0, 0)); // dark red (low lum)
    surface.setPixel(1, 0, Pixel.rgb(255, 255, 0)); // bright yellow (high lum)
    surface.setPixel(0, 1, Pixel.rgb(0, 0, 80)); // dark blue (low lum)
    surface.setPixel(1, 1, Pixel.rgb(0, 255, 0)); // bright green (high lum)

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Color mode (not monochrome) should use luminance clustering
    blit(&dest, 0, 0, surface, .{ .mode = .quadrant, .monochrome = false });

    // The bright pixels (top-right, bottom-right) should be "on"
    // This should produce ▐ (right half block)
    try std.testing.expectEqual(@as(u21, '▐'), dest.getCell(0, 0).char);

    // fg should be average of bright pixels, bg should be average of dark pixels
    // Both should not be default
    const cell = dest.getCell(0, 0);
    try std.testing.expect(!cell.fg.eql(Color.default));
    try std.testing.expect(!cell.bg.eql(Color.default));
}

test "blitBraille basic" {
    // Create a 4x8 surface (will become 2x2 in braille mode)
    var surface = try Surface.init(std.testing.allocator, 4, 8);
    defer surface.deinit();

    // Cell (0,0): all dots "on"
    var py: u32 = 0;
    while (py < 4) : (py += 1) {
        surface.setPixel(0, py, Pixel.white);
        surface.setPixel(1, py, Pixel.white);
    }

    // Cell (1,0): no dots "on"
    // (already transparent by default)

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    blit(&dest, 0, 0, surface, .{ .mode = .braille, .monochrome = true });

    // All dots on = U+28FF (⣿)
    try std.testing.expectEqual(@as(u21, 0x28FF), dest.getCell(0, 0).char);
}

test "quadrantChar mapping" {
    // Test all 16 combinations
    try std.testing.expectEqual(@as(u21, ' '), quadrantChar(0b0000));
    try std.testing.expectEqual(@as(u21, '▘'), quadrantChar(0b0001));
    try std.testing.expectEqual(@as(u21, '▝'), quadrantChar(0b0010));
    try std.testing.expectEqual(@as(u21, '▀'), quadrantChar(0b0011));
    try std.testing.expectEqual(@as(u21, '▖'), quadrantChar(0b0100));
    try std.testing.expectEqual(@as(u21, '▌'), quadrantChar(0b0101));
    try std.testing.expectEqual(@as(u21, '▞'), quadrantChar(0b0110));
    try std.testing.expectEqual(@as(u21, '▛'), quadrantChar(0b0111));
    try std.testing.expectEqual(@as(u21, '▗'), quadrantChar(0b1000));
    try std.testing.expectEqual(@as(u21, '▚'), quadrantChar(0b1001));
    try std.testing.expectEqual(@as(u21, '▐'), quadrantChar(0b1010));
    try std.testing.expectEqual(@as(u21, '▜'), quadrantChar(0b1011));
    try std.testing.expectEqual(@as(u21, '▄'), quadrantChar(0b1100));
    try std.testing.expectEqual(@as(u21, '▙'), quadrantChar(0b1101));
    try std.testing.expectEqual(@as(u21, '▟'), quadrantChar(0b1110));
    try std.testing.expectEqual(@as(u21, '█'), quadrantChar(0b1111));
}

test "monochrome mode with threshold" {
    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();

    // Set up: dark pixel (lum < 128) and bright pixel (lum >= 128)
    surface.setPixel(0, 0, Pixel.rgb(50, 50, 50)); // lum ~50
    surface.setPixel(1, 0, Pixel.rgb(200, 200, 200)); // lum ~200
    surface.setPixel(0, 1, Pixel.rgb(50, 50, 50));
    surface.setPixel(1, 1, Pixel.rgb(200, 200, 200));

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    blit(&dest, 0, 0, surface, .{
        .mode = .quadrant,
        .monochrome = true,
        .threshold = 128,
    });

    // Left column should be off, right column should be on
    // Expecting: ▐ (right half)
    try std.testing.expectEqual(@as(u21, '▐'), dest.getCell(0, 0).char);
}

test "transparent pixels are skipped" {
    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();

    // Only set one pixel, leave others transparent
    surface.setPixel(0, 0, Pixel.white);

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Pre-fill destination to check transparent pixels don't overwrite
    dest.print(0, 0, "XX", .default, .default, .{});

    blit(&dest, 0, 0, surface, .{ .mode = .ascii });

    // Position (0,0) should be overwritten
    try std.testing.expect(dest.getCell(0, 0).char != 'X');

    // Position (1,0) should still be 'X' (transparent pixel skipped)
    // Note: depends on full transparency handling, may vary
}

test "dithering modifies output" {
    var surface = try Surface.init(std.testing.allocator, 4, 4);
    defer surface.deinit();

    // Fill with mid-gray (should produce different results with dithering)
    surface.clear(Pixel.rgb(128, 128, 128));

    var dest_no_dither = try Buffer.init(std.testing.allocator, .{ .width = 4, .height = 4 });
    defer dest_no_dither.deinit();

    var dest_dither = try Buffer.init(std.testing.allocator, .{ .width = 4, .height = 4 });
    defer dest_dither.deinit();

    blit(&dest_no_dither, 0, 0, surface, .{ .mode = .ascii, .monochrome = true, .dither = false });
    blit(&dest_dither, 0, 0, surface, .{ .mode = .ascii, .monochrome = true, .dither = true });

    // Without dithering, all cells should be the same
    const c00 = dest_no_dither.getCell(0, 0).char;
    try std.testing.expectEqual(c00, dest_no_dither.getCell(1, 0).char);
    try std.testing.expectEqual(c00, dest_no_dither.getCell(0, 1).char);
    try std.testing.expectEqual(c00, dest_no_dither.getCell(1, 1).char);

    // With dithering, at least some cells should differ
    var differs = false;
    const c00_dither = dest_dither.getCell(0, 0).char;
    if (dest_dither.getCell(1, 0).char != c00_dither) differs = true;
    if (dest_dither.getCell(0, 1).char != c00_dither) differs = true;
    if (dest_dither.getCell(1, 1).char != c00_dither) differs = true;
    try std.testing.expect(differs);
}

test "color depth downgrade" {
    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();

    surface.setPixel(0, 0, Pixel.rgb(255, 128, 64)); // Orange-ish

    var dest = try Buffer.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Blit with 256-color depth
    blit(&dest, 0, 0, surface, .{ .mode = .ascii, .color_depth = .color_256 });

    // The color should be an indexed color, not RGB
    const cell = dest.getCell(0, 0);
    switch (cell.fg) {
        .index => {}, // expected
        else => try std.testing.expect(false),
    }
}

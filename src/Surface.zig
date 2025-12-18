const std = @import("std");

/// A pixel surface for RGBA image data.
///
/// Surfaces represent pixel data that can be used for graphics operations like
/// scaling, blitting, and conversion to terminal cells. They support both owned
/// memory (allocated via init) and borrowed memory (wrapped via wrap).
///
/// Pixel format is RGBA8888: each pixel is 4 bytes (R, G, B, A) in that order.
/// Stride is the number of bytes between the start of consecutive rows.
pub const Surface = @This();

/// Single RGBA pixel (8 bits per channel)
pub const Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Pixel = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    /// Create a pixel from RGB values (fully opaque)
    pub fn rgb(r: u8, g: u8, b: u8) Pixel {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Create a pixel from RGBA values
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Pixel {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Blend this pixel over another using alpha compositing (src-over)
    pub fn blend(self: Pixel, dst: Pixel) Pixel {
        if (self.a == 255) return self;
        if (self.a == 0) return dst;

        const src_a: u32 = self.a;
        const dst_a: u32 = dst.a;
        const inv_src_a: u32 = 255 - src_a;

        // out_a = src_a + dst_a * (1 - src_a) / 255
        const out_a: u32 = src_a + (dst_a * inv_src_a) / 255;
        if (out_a == 0) return Pixel.transparent;

        // out_rgb = (src_rgb * src_a + dst_rgb * dst_a * (1 - src_a) / 255) / out_a
        // Use u32 to avoid overflow: max value is 255 * 255 * 255 / 255 = 65025
        const r: u32 = (@as(u32, self.r) * src_a + @as(u32, dst.r) * dst_a * inv_src_a / 255) / out_a;
        const g: u32 = (@as(u32, self.g) * src_a + @as(u32, dst.g) * dst_a * inv_src_a / 255) / out_a;
        const b: u32 = (@as(u32, self.b) * src_a + @as(u32, dst.b) * dst_a * inv_src_a / 255) / out_a;

        return .{
            .r = @intCast(@min(r, 255)),
            .g = @intCast(@min(g, 255)),
            .b = @intCast(@min(b, 255)),
            .a = @intCast(@min(out_a, 255)),
        };
    }

    /// Check if two pixels are equal
    pub fn eql(self: Pixel, other: Pixel) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }

    /// Convert to grayscale using luminance formula
    pub fn luminance(self: Pixel) u8 {
        // ITU-R BT.601 luma coefficients: Y = 0.299*R + 0.587*G + 0.114*B
        const lum: u32 = @as(u32, self.r) * 77 + @as(u32, self.g) * 150 + @as(u32, self.b) * 29;
        return @intCast(lum >> 8);
    }
};

/// Maximum dimension to prevent integer overflow in stride/size calculations.
/// With RGBA (4 bytes per pixel), width*4 must fit in u32 (max 2^32-1).
/// Using 2^30 - 1 ensures width*4 = (2^30-1)*4 < 2^32.
pub const max_dimension: u32 = (1 << 30) - 1; // ~1 billion pixels per dimension

/// Rectangle for blit operations.
/// Uses u32 for pixel coordinates (surfaces can be larger than terminal dimensions).
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Width in pixels
width: u32,
/// Height in pixels
height: u32,
/// Bytes between row starts (must be >= width * 4)
stride: u32,
/// Pixel data (RGBA8888 format)
pixels: []u8,
/// Allocator if owned, null if wrapped
allocator: ?std.mem.Allocator,

/// Create a new surface with allocated memory
pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Surface {
    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Prevent integer overflow: width * 4 must fit in u32, and stride * height in usize
    if (width > max_dimension or height > max_dimension) {
        return error.InvalidDimensions;
    }

    const stride = width * 4;
    const total_bytes = @as(usize, stride) * @as(usize, height);
    const pixels = try allocator.alloc(u8, total_bytes);
    @memset(pixels, 0);

    return Surface{
        .width = width,
        .height = height,
        .stride = stride,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Wrap an existing pixel buffer without copying.
/// Caller retains ownership of the underlying memory.
/// The buffer must remain valid for the lifetime of this Surface.
pub fn wrap(pixels: []u8, width: u32, height: u32, stride: ?u32) !Surface {
    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Prevent integer overflow in stride/size calculations
    if (width > max_dimension or height > max_dimension) {
        return error.InvalidDimensions;
    }

    const actual_stride = stride orelse width * 4;
    if (actual_stride < width * 4) {
        return error.InvalidStride;
    }

    const required = @as(usize, actual_stride) * @as(usize, height - 1) + @as(usize, width) * 4;
    if (pixels.len < required) {
        return error.BufferTooSmall;
    }

    return Surface{
        .width = width,
        .height = height,
        .stride = actual_stride,
        .pixels = pixels,
        .allocator = null,
    };
}

/// Free surface resources (only if owned)
pub fn deinit(self: *Surface) void {
    if (self.allocator) |alloc| {
        alloc.free(self.pixels);
    }
    self.* = undefined;
}

/// Get pixel at (x, y). Returns null if out of bounds.
pub fn getPixel(self: Surface, x: u32, y: u32) ?Pixel {
    if (x >= self.width or y >= self.height) return null;
    const offset = @as(usize, y) * @as(usize, self.stride) + @as(usize, x) * 4;
    return .{
        .r = self.pixels[offset],
        .g = self.pixels[offset + 1],
        .b = self.pixels[offset + 2],
        .a = self.pixels[offset + 3],
    };
}

/// Set pixel at (x, y). Out-of-bounds writes are silently ignored.
pub fn setPixel(self: *Surface, x: u32, y: u32, pixel: Pixel) void {
    if (x >= self.width or y >= self.height) return;
    const offset = @as(usize, y) * @as(usize, self.stride) + @as(usize, x) * 4;
    self.pixels[offset] = pixel.r;
    self.pixels[offset + 1] = pixel.g;
    self.pixels[offset + 2] = pixel.b;
    self.pixels[offset + 3] = pixel.a;
}

/// Clear surface to a solid color
pub fn clear(self: *Surface, pixel: Pixel) void {
    var y: u32 = 0;
    while (y < self.height) : (y += 1) {
        const row_start = @as(usize, y) * @as(usize, self.stride);
        var x: u32 = 0;
        while (x < self.width) : (x += 1) {
            const offset = row_start + @as(usize, x) * 4;
            self.pixels[offset] = pixel.r;
            self.pixels[offset + 1] = pixel.g;
            self.pixels[offset + 2] = pixel.b;
            self.pixels[offset + 3] = pixel.a;
        }
    }
}

/// Fill a rectangular region with a solid color
pub fn fill(self: *Surface, rect: Rect, pixel: Pixel) void {
    const x_start = rect.x;
    const y_start = rect.y;
    const x_end = @min(rect.x + rect.width, self.width);
    const y_end = @min(rect.y + rect.height, self.height);

    if (x_start >= self.width or y_start >= self.height) return;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            self.setPixel(x, y, pixel);
        }
    }
}

/// Blit options for copy operations
pub const BlitOptions = struct {
    /// Source region to copy (null = entire source)
    src_rect: ?Rect = null,
    /// Use alpha blending (false = direct copy)
    blend: bool = false,
};

/// Blit (copy) pixels from another surface to this one.
/// Destination position is (dst_x, dst_y). Source region is clipped to fit.
pub fn blit(self: *Surface, src: Surface, dst_x: u32, dst_y: u32, options: BlitOptions) void {
    const src_rect = options.src_rect orelse Rect{
        .x = 0,
        .y = 0,
        .width = src.width,
        .height = src.height,
    };

    // Clip source rect to source surface bounds
    const src_x_start = @min(src_rect.x, src.width);
    const src_y_start = @min(src_rect.y, src.height);
    const src_x_end = @min(src_rect.x + src_rect.width, src.width);
    const src_y_end = @min(src_rect.y + src_rect.height, src.height);

    if (src_x_start >= src_x_end or src_y_start >= src_y_end) return;

    // Calculate clipped width/height
    var copy_width = src_x_end - src_x_start;
    var copy_height = src_y_end - src_y_start;

    // Clip to destination bounds
    if (dst_x >= self.width or dst_y >= self.height) return;
    copy_width = @min(copy_width, self.width - dst_x);
    copy_height = @min(copy_height, self.height - dst_y);

    // Copy row by row
    var sy = src_y_start;
    var dy = dst_y;
    while (sy < src_y_start + copy_height) : ({
        sy += 1;
        dy += 1;
    }) {
        var sx = src_x_start;
        var dx = dst_x;
        while (sx < src_x_start + copy_width) : ({
            sx += 1;
            dx += 1;
        }) {
            const src_pixel = src.getPixel(sx, sy) orelse continue;
            if (options.blend) {
                const dst_pixel = self.getPixel(dx, dy) orelse Pixel.transparent;
                self.setPixel(dx, dy, src_pixel.blend(dst_pixel));
            } else {
                self.setPixel(dx, dy, src_pixel);
            }
        }
    }
}

/// Scale this surface to a new size using nearest-neighbor interpolation.
/// Returns a new allocated surface. Caller owns the returned surface.
pub fn scale(self: Surface, allocator: std.mem.Allocator, new_width: u32, new_height: u32) !Surface {
    if (new_width == 0 or new_height == 0) {
        return error.InvalidDimensions;
    }

    var result = try Surface.init(allocator, new_width, new_height);
    errdefer result.deinit();

    // Use fixed-point arithmetic for better precision
    const x_ratio: u64 = (@as(u64, self.width) << 16) / @as(u64, new_width);
    const y_ratio: u64 = (@as(u64, self.height) << 16) / @as(u64, new_height);

    var dy: u32 = 0;
    while (dy < new_height) : (dy += 1) {
        const sy: u32 = @intCast((@as(u64, dy) * y_ratio) >> 16);
        var dx: u32 = 0;
        while (dx < new_width) : (dx += 1) {
            const sx: u32 = @intCast((@as(u64, dx) * x_ratio) >> 16);
            if (self.getPixel(sx, sy)) |pixel| {
                result.setPixel(dx, dy, pixel);
            }
        }
    }

    return result;
}

/// Scale to fit within max dimensions while preserving aspect ratio.
/// Returns a new allocated surface. Caller owns the returned surface.
pub fn scaleToFit(self: Surface, allocator: std.mem.Allocator, max_width: u32, max_height: u32) !Surface {
    if (max_width == 0 or max_height == 0) {
        return error.InvalidDimensions;
    }

    // Calculate scale factor to fit within bounds
    const width_ratio: f64 = @as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(self.width));
    const height_ratio: f64 = @as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(self.height));
    const scale_factor = @min(width_ratio, height_ratio);

    const new_width: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.width)) * scale_factor)));
    const new_height: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.height)) * scale_factor)));

    return self.scale(allocator, new_width, new_height);
}

/// Get raw row pointer for direct access
pub fn getRow(self: Surface, y: u32) ?[]u8 {
    if (y >= self.height) return null;
    const row_start = @as(usize, y) * @as(usize, self.stride);
    return self.pixels[row_start..][0 .. self.width * 4];
}

/// Error set for surface operations
pub const Error = error{
    InvalidDimensions,
    InvalidStride,
    BufferTooSmall,
    OutOfMemory,
};

// ============================================================================
// Tests
// ============================================================================

test "Surface init and deinit" {
    var surface = try Surface.init(std.testing.allocator, 10, 8);
    defer surface.deinit();

    try std.testing.expectEqual(@as(u32, 10), surface.width);
    try std.testing.expectEqual(@as(u32, 8), surface.height);
    try std.testing.expectEqual(@as(u32, 40), surface.stride); // 10 * 4
    try std.testing.expectEqual(@as(usize, 320), surface.pixels.len); // 10 * 8 * 4
}

test "Surface init zero dimensions fails" {
    try std.testing.expectError(error.InvalidDimensions, Surface.init(std.testing.allocator, 0, 10));
    try std.testing.expectError(error.InvalidDimensions, Surface.init(std.testing.allocator, 10, 0));
}

test "Surface wrap existing buffer" {
    var buffer: [160]u8 = undefined;
    @memset(&buffer, 0);

    var surface = try Surface.wrap(&buffer, 10, 4, null);

    try std.testing.expectEqual(@as(u32, 10), surface.width);
    try std.testing.expectEqual(@as(u32, 4), surface.height);
    try std.testing.expectEqual(@as(u32, 40), surface.stride);
    try std.testing.expect(surface.allocator == null); // Not owned

    // Modifications to surface should affect original buffer
    surface.setPixel(0, 0, Pixel.white);
    try std.testing.expectEqual(@as(u8, 255), buffer[0]); // R
    try std.testing.expectEqual(@as(u8, 255), buffer[1]); // G
    try std.testing.expectEqual(@as(u8, 255), buffer[2]); // B
    try std.testing.expectEqual(@as(u8, 255), buffer[3]); // A
}

test "Surface wrap with custom stride" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    // Use stride of 64 bytes (16 pixels worth) for a 10-pixel wide surface
    var surface = try Surface.wrap(&buffer, 10, 4, 64);

    try std.testing.expectEqual(@as(u32, 64), surface.stride);

    // Set pixel in second row
    surface.setPixel(0, 1, Pixel.rgb(100, 150, 200));

    // Should be at offset 64 (stride), not 40 (width * 4)
    try std.testing.expectEqual(@as(u8, 100), buffer[64]);
    try std.testing.expectEqual(@as(u8, 150), buffer[65]);
    try std.testing.expectEqual(@as(u8, 200), buffer[66]);
}

test "Surface wrap buffer too small" {
    var buffer: [100]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, Surface.wrap(&buffer, 10, 4, null));
}

test "Surface wrap invalid stride" {
    var buffer: [160]u8 = undefined;
    // Stride of 20 is less than width * 4 = 40
    try std.testing.expectError(error.InvalidStride, Surface.wrap(&buffer, 10, 4, 20));
}

test "Surface init rejects dimensions exceeding max" {
    // Width exceeding max_dimension should fail
    try std.testing.expectError(error.InvalidDimensions, Surface.init(std.testing.allocator, max_dimension + 1, 10));
    // Height exceeding max_dimension should fail
    try std.testing.expectError(error.InvalidDimensions, Surface.init(std.testing.allocator, 10, max_dimension + 1));
    // Both exceeding should fail
    try std.testing.expectError(error.InvalidDimensions, Surface.init(std.testing.allocator, max_dimension + 1, max_dimension + 1));
}

test "Surface wrap rejects dimensions exceeding max" {
    var buffer: [160]u8 = undefined;
    // Width exceeding max_dimension should fail
    try std.testing.expectError(error.InvalidDimensions, Surface.wrap(&buffer, max_dimension + 1, 1, null));
    // Height exceeding max_dimension should fail
    try std.testing.expectError(error.InvalidDimensions, Surface.wrap(&buffer, 1, max_dimension + 1, null));
}

test "Surface getPixel and setPixel" {
    var surface = try Surface.init(std.testing.allocator, 10, 10);
    defer surface.deinit();

    const test_pixel = Pixel.rgb(100, 150, 200);
    surface.setPixel(5, 3, test_pixel);

    const got = surface.getPixel(5, 3);
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.eql(test_pixel));
}

test "Surface getPixel out of bounds returns null" {
    var surface = try Surface.init(std.testing.allocator, 10, 10);
    defer surface.deinit();

    try std.testing.expect(surface.getPixel(10, 0) == null);
    try std.testing.expect(surface.getPixel(0, 10) == null);
    try std.testing.expect(surface.getPixel(100, 100) == null);
}

test "Surface setPixel out of bounds is ignored" {
    var surface = try Surface.init(std.testing.allocator, 10, 10);
    defer surface.deinit();

    // These should not crash
    surface.setPixel(100, 100, Pixel.white);
    surface.setPixel(10, 0, Pixel.white);
    surface.setPixel(0, 10, Pixel.white);
}

test "Surface clear" {
    var surface = try Surface.init(std.testing.allocator, 4, 4);
    defer surface.deinit();

    const red = Pixel.rgb(255, 0, 0);
    surface.clear(red);

    // Check all pixels are red
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const pixel = surface.getPixel(x, y);
            try std.testing.expect(pixel != null);
            try std.testing.expect(pixel.?.eql(red));
        }
    }
}

test "Surface fill" {
    var surface = try Surface.init(std.testing.allocator, 10, 10);
    defer surface.deinit();

    surface.clear(Pixel.black);

    const blue = Pixel.rgb(0, 0, 255);
    surface.fill(.{ .x = 2, .y = 3, .width = 4, .height = 3 }, blue);

    // Check filled region
    try std.testing.expect(surface.getPixel(2, 3).?.eql(blue));
    try std.testing.expect(surface.getPixel(5, 5).?.eql(blue));

    // Check outside region
    try std.testing.expect(surface.getPixel(0, 0).?.eql(Pixel.black));
    try std.testing.expect(surface.getPixel(1, 3).?.eql(Pixel.black));
    try std.testing.expect(surface.getPixel(6, 3).?.eql(Pixel.black));
}

test "Surface fill clips to bounds" {
    var surface = try Surface.init(std.testing.allocator, 10, 10);
    defer surface.deinit();

    surface.clear(Pixel.black);

    // Fill extending beyond bounds
    surface.fill(.{ .x = 8, .y = 8, .width = 10, .height = 10 }, Pixel.white);

    // Should only affect valid region
    try std.testing.expect(surface.getPixel(8, 8).?.eql(Pixel.white));
    try std.testing.expect(surface.getPixel(9, 9).?.eql(Pixel.white));
    try std.testing.expect(surface.getPixel(7, 7).?.eql(Pixel.black));
}

test "Surface blit basic" {
    var dst = try Surface.init(std.testing.allocator, 10, 10);
    defer dst.deinit();
    dst.clear(Pixel.black);

    var src = try Surface.init(std.testing.allocator, 4, 4);
    defer src.deinit();
    src.clear(Pixel.rgb(255, 0, 0));

    dst.blit(src, 2, 3, .{});

    // Check blitted region
    try std.testing.expect(dst.getPixel(2, 3).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(dst.getPixel(5, 6).?.eql(Pixel.rgb(255, 0, 0)));

    // Check outside region
    try std.testing.expect(dst.getPixel(0, 0).?.eql(Pixel.black));
    try std.testing.expect(dst.getPixel(1, 3).?.eql(Pixel.black));
    try std.testing.expect(dst.getPixel(6, 3).?.eql(Pixel.black));
}

test "Surface blit with source rect" {
    var dst = try Surface.init(std.testing.allocator, 10, 10);
    defer dst.deinit();
    dst.clear(Pixel.black);

    var src = try Surface.init(std.testing.allocator, 8, 8);
    defer src.deinit();
    src.clear(Pixel.transparent);
    // Create a 2x2 red square in the middle of src
    src.fill(.{ .x = 3, .y = 3, .width = 2, .height = 2 }, Pixel.rgb(255, 0, 0));

    // Blit only the 2x2 region
    dst.blit(src, 0, 0, .{ .src_rect = .{ .x = 3, .y = 3, .width = 2, .height = 2 } });

    // Should have 2x2 red at (0,0)
    try std.testing.expect(dst.getPixel(0, 0).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(dst.getPixel(1, 1).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(dst.getPixel(2, 0).?.eql(Pixel.black));
}

test "Surface blit clips to destination" {
    var dst = try Surface.init(std.testing.allocator, 5, 5);
    defer dst.deinit();
    dst.clear(Pixel.black);

    var src = try Surface.init(std.testing.allocator, 10, 10);
    defer src.deinit();
    src.clear(Pixel.rgb(0, 255, 0));

    // Blit 10x10 source at position (3, 3) - should clip to 2x2
    dst.blit(src, 3, 3, .{});

    // Should have green at (3,3) and (4,4)
    try std.testing.expect(dst.getPixel(3, 3).?.eql(Pixel.rgb(0, 255, 0)));
    try std.testing.expect(dst.getPixel(4, 4).?.eql(Pixel.rgb(0, 255, 0)));
    // But not outside destination
    try std.testing.expect(dst.getPixel(2, 2).?.eql(Pixel.black));
}

test "Surface scale nearest neighbor" {
    var src = try Surface.init(std.testing.allocator, 2, 2);
    defer src.deinit();

    // Create 2x2 checkerboard pattern
    src.setPixel(0, 0, Pixel.rgb(255, 0, 0)); // Red top-left
    src.setPixel(1, 0, Pixel.rgb(0, 255, 0)); // Green top-right
    src.setPixel(0, 1, Pixel.rgb(0, 0, 255)); // Blue bottom-left
    src.setPixel(1, 1, Pixel.rgb(255, 255, 0)); // Yellow bottom-right

    // Scale up to 4x4
    var scaled = try src.scale(std.testing.allocator, 4, 4);
    defer scaled.deinit();

    try std.testing.expectEqual(@as(u32, 4), scaled.width);
    try std.testing.expectEqual(@as(u32, 4), scaled.height);

    // Each original pixel should become a 2x2 block
    // Top-left 2x2 should be red
    try std.testing.expect(scaled.getPixel(0, 0).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(scaled.getPixel(1, 0).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(scaled.getPixel(0, 1).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(scaled.getPixel(1, 1).?.eql(Pixel.rgb(255, 0, 0)));

    // Top-right 2x2 should be green
    try std.testing.expect(scaled.getPixel(2, 0).?.eql(Pixel.rgb(0, 255, 0)));
    try std.testing.expect(scaled.getPixel(3, 0).?.eql(Pixel.rgb(0, 255, 0)));

    // Bottom-left 2x2 should be blue
    try std.testing.expect(scaled.getPixel(0, 2).?.eql(Pixel.rgb(0, 0, 255)));
    try std.testing.expect(scaled.getPixel(1, 3).?.eql(Pixel.rgb(0, 0, 255)));

    // Bottom-right 2x2 should be yellow
    try std.testing.expect(scaled.getPixel(2, 2).?.eql(Pixel.rgb(255, 255, 0)));
    try std.testing.expect(scaled.getPixel(3, 3).?.eql(Pixel.rgb(255, 255, 0)));
}

test "Surface scale down" {
    var src = try Surface.init(std.testing.allocator, 4, 4);
    defer src.deinit();

    // Fill with pattern
    src.fill(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, Pixel.rgb(255, 0, 0));
    src.fill(.{ .x = 2, .y = 0, .width = 2, .height = 2 }, Pixel.rgb(0, 255, 0));
    src.fill(.{ .x = 0, .y = 2, .width = 2, .height = 2 }, Pixel.rgb(0, 0, 255));
    src.fill(.{ .x = 2, .y = 2, .width = 2, .height = 2 }, Pixel.rgb(255, 255, 0));

    // Scale down to 2x2
    var scaled = try src.scale(std.testing.allocator, 2, 2);
    defer scaled.deinit();

    // Each 2x2 block should become 1 pixel (nearest neighbor picks (0,0) of each)
    try std.testing.expect(scaled.getPixel(0, 0).?.eql(Pixel.rgb(255, 0, 0)));
    try std.testing.expect(scaled.getPixel(1, 0).?.eql(Pixel.rgb(0, 255, 0)));
    try std.testing.expect(scaled.getPixel(0, 1).?.eql(Pixel.rgb(0, 0, 255)));
    try std.testing.expect(scaled.getPixel(1, 1).?.eql(Pixel.rgb(255, 255, 0)));
}

test "Surface scaleToFit preserves aspect ratio" {
    var src = try Surface.init(std.testing.allocator, 100, 50);
    defer src.deinit();

    // Scale to fit in 20x20 box
    var scaled = try src.scaleToFit(std.testing.allocator, 20, 20);
    defer scaled.deinit();

    // Should scale to 20x10 (width is limiting factor)
    try std.testing.expectEqual(@as(u32, 20), scaled.width);
    try std.testing.expectEqual(@as(u32, 10), scaled.height);
}

test "Surface scaleToFit height limited" {
    var src = try Surface.init(std.testing.allocator, 50, 100);
    defer src.deinit();

    // Scale to fit in 20x20 box
    var scaled = try src.scaleToFit(std.testing.allocator, 20, 20);
    defer scaled.deinit();

    // Should scale to 10x20 (height is limiting factor)
    try std.testing.expectEqual(@as(u32, 10), scaled.width);
    try std.testing.expectEqual(@as(u32, 20), scaled.height);
}

test "Pixel blend fully opaque" {
    const src = Pixel.rgb(255, 0, 0);
    const dst = Pixel.rgb(0, 255, 0);

    const result = src.blend(dst);
    try std.testing.expect(result.eql(src)); // Fully opaque src replaces dst
}

test "Pixel blend fully transparent" {
    const src = Pixel.transparent;
    const dst = Pixel.rgb(0, 255, 0);

    const result = src.blend(dst);
    try std.testing.expect(result.eql(dst)); // Fully transparent src keeps dst
}

test "Pixel blend semi-transparent" {
    const src = Pixel.rgba(255, 0, 0, 128); // 50% red
    const dst = Pixel.rgb(0, 0, 255); // Blue

    const result = src.blend(dst);

    // Result should be a purple-ish color
    try std.testing.expect(result.r > 100);
    try std.testing.expect(result.b > 100);
    try std.testing.expectEqual(@as(u8, 255), result.a); // Blended onto opaque = opaque
}

test "Surface blit with blending" {
    var dst = try Surface.init(std.testing.allocator, 4, 4);
    defer dst.deinit();
    dst.clear(Pixel.rgb(0, 0, 255)); // Blue background

    var src = try Surface.init(std.testing.allocator, 2, 2);
    defer src.deinit();
    src.clear(Pixel.rgba(255, 0, 0, 128)); // 50% red

    dst.blit(src, 1, 1, .{ .blend = true });

    // Blitted region should be blended
    const blitted = dst.getPixel(1, 1).?;
    try std.testing.expect(blitted.r > 100);
    try std.testing.expect(blitted.b > 100);

    // Outside region should still be blue
    try std.testing.expect(dst.getPixel(0, 0).?.eql(Pixel.rgb(0, 0, 255)));
}

test "Pixel luminance" {
    try std.testing.expectEqual(@as(u8, 0), Pixel.black.luminance());
    try std.testing.expectEqual(@as(u8, 255), Pixel.white.luminance());

    // Red should be darker than green (green has highest luminance coefficient)
    const red = Pixel.rgb(255, 0, 0);
    const green = Pixel.rgb(0, 255, 0);
    try std.testing.expect(red.luminance() < green.luminance());
}

test "Surface getRow" {
    var surface = try Surface.init(std.testing.allocator, 4, 3);
    defer surface.deinit();

    // Set pixel in row 1
    surface.setPixel(2, 1, Pixel.rgb(100, 150, 200));

    const row = surface.getRow(1);
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(usize, 16), row.?.len); // 4 pixels * 4 bytes

    // Check the pixel at x=2 in the row
    try std.testing.expectEqual(@as(u8, 100), row.?[8]); // x=2, offset=8
    try std.testing.expectEqual(@as(u8, 150), row.?[9]);
    try std.testing.expectEqual(@as(u8, 200), row.?[10]);
}

test "Surface getRow out of bounds" {
    var surface = try Surface.init(std.testing.allocator, 4, 3);
    defer surface.deinit();

    try std.testing.expect(surface.getRow(3) == null);
    try std.testing.expect(surface.getRow(100) == null);
}

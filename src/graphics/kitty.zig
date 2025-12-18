//! Kitty Graphics Protocol implementation for pixel-perfect terminal images.
//!
//! This module provides an API for displaying RGBA images on terminals that support
//! the Kitty graphics protocol (Kitty, Ghostty, WezTerm, and others).
//!
//! The protocol uses APC (Application Programming Command) escape sequences to
//! transmit base64-encoded image data, with support for chunking large images
//! and various placement options.
//!
//! Usage:
//! ```zig
//! var kitty = KittyGraphics.init(allocator);
//! defer kitty.deinit();
//!
//! // Draw an image at cell position (10, 5)
//! try kitty.draw(writer, surface, .{
//!     .image_id = 1,
//!     .position = .{ .x = 10, .y = 5 },
//! });
//!
//! // Delete the image when done
//! try kitty.delete(writer, .{ .image_id = 1 });
//! ```
//!
//! References:
//! - https://sw.kovidgoyal.net/kitty/graphics-protocol/

const std = @import("std");
const Surface = @import("../Surface.zig");
const Pixel = Surface.Pixel;

/// Kitty graphics protocol handler.
pub const KittyGraphics = @This();

/// Allocator for internal buffers.
allocator: std.mem.Allocator,

/// Temporary buffer for base64 encoding.
encode_buffer: std.ArrayList(u8),

/// Maximum payload size per chunk (bytes before base64 encoding).
/// Kitty recommends 4096 bytes max encoded payload for remote connections.
/// 3072 raw bytes encodes to exactly 4096 base64 bytes.
pub const max_chunk_size: usize = 3072;

/// Maximum payload size after base64 encoding.
const max_encoded_chunk_size: usize = 4096;

/// Image format codes for the 'f' parameter.
pub const Format = enum(u8) {
    /// 24-bit RGB (3 bytes per pixel)
    rgb = 24,
    /// 32-bit RGBA (4 bytes per pixel, default)
    rgba = 32,
    /// PNG compressed data
    png = 100,
};

/// Transmission mode for the 'a' parameter.
pub const TransmitMode = enum {
    /// Transmit and display immediately (a=T)
    transmit_and_display,
    /// Transmit only, display later with placement command (a=t)
    transmit_only,
};

/// Deletion scope for the 'd' parameter.
pub const DeleteScope = enum {
    /// Delete all images visible on screen (d=a)
    all_visible,
    /// Delete all images visible on screen and free stored data (d=A)
    all_visible_and_free,
    /// Delete image by ID (d=i)
    by_id,
    /// Delete image by ID and free stored data (d=I)
    by_id_and_free,
    /// Delete all images at current cursor position (d=c)
    at_cursor,
    /// Delete all images at current cursor position and free (d=C)
    at_cursor_and_free,
    /// Delete all images intersecting specified cell (d=p)
    at_cell,
    /// Delete all images intersecting specified cell and free (d=P)
    at_cell_and_free,
    /// Delete all images with specified z-index (d=z)
    by_zindex,
    /// Delete all images with specified z-index and free (d=Z)
    by_zindex_and_free,
};

/// Cell position for image placement.
pub const CellPosition = struct {
    x: u16,
    y: u16,
};

/// Options for drawing an image.
pub const DrawOptions = struct {
    /// Image ID for later reference (0 = auto-assign).
    image_id: u32 = 0,

    /// Cell position to place image at. If null, uses current cursor position.
    position: ?CellPosition = null,

    /// Number of columns to scale image to (0 = auto from image width).
    columns: u16 = 0,

    /// Number of rows to scale image to (0 = auto from image height).
    rows: u16 = 0,

    /// Z-index for layering (negative = behind text, positive = in front).
    z_index: i32 = 0,

    /// If true, transmit but don't display (use placement command later).
    transmit_only: bool = false,

    /// If true, don't move cursor after placement.
    no_cursor_move: bool = false,

    /// Source rectangle within the image (null = entire image).
    src_rect: ?SrcRect = null,
};

/// Source rectangle for partial image display.
pub const SrcRect = struct {
    /// X offset in pixels.
    x: u32 = 0,
    /// Y offset in pixels.
    y: u32 = 0,
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
};

/// Options for deleting images.
pub const DeleteOptions = struct {
    /// Deletion scope.
    scope: DeleteScope = .by_id_and_free,

    /// Image ID (for by_id scopes).
    image_id: u32 = 0,

    /// Cell position (for at_cell scopes).
    x: u16 = 0,
    y: u16 = 0,

    /// Z-index (for by_zindex scopes).
    z_index: i32 = 0,
};

/// Initialize a Kitty graphics handler.
pub fn init(allocator: std.mem.Allocator) KittyGraphics {
    return .{
        .allocator = allocator,
        .encode_buffer = std.ArrayList(u8).init(allocator),
    };
}

/// Free resources.
pub fn deinit(self: *KittyGraphics) void {
    self.encode_buffer.deinit();
    self.* = undefined;
}

/// Draw a surface to the terminal using the Kitty graphics protocol.
///
/// The image is transmitted as base64-encoded RGBA data, chunked if necessary
/// to stay within protocol limits. If options.position is set, the cursor is
/// moved to that position before transmission; otherwise the current cursor
/// position is used.
pub fn draw(self: *KittyGraphics, writer: anytype, surface: Surface, options: DrawOptions) !void {
    if (surface.width == 0 or surface.height == 0) return;

    // Move cursor to placement position if specified (only when displaying)
    if (options.position) |pos| {
        if (!options.transmit_only) {
            try moveCursor(writer, pos.x, pos.y);
        }
    }

    // Determine source rectangle
    const src_x = if (options.src_rect) |r| r.x else 0;
    const src_y = if (options.src_rect) |r| r.y else 0;
    const src_w = if (options.src_rect) |r| r.width else surface.width;
    const src_h = if (options.src_rect) |r| r.height else surface.height;

    // Validate source rectangle
    if (src_x >= surface.width or src_y >= surface.height) return;
    const actual_w = @min(src_w, surface.width - src_x);
    const actual_h = @min(src_h, surface.height - src_y);
    if (actual_w == 0 or actual_h == 0) return;

    // Calculate total raw data size
    const bytes_per_pixel: usize = 4; // RGBA
    const total_size = @as(usize, actual_w) * @as(usize, actual_h) * bytes_per_pixel;

    // Prepare pixel data (may need to extract rows if stride != width*4 or src_rect is set)
    const pixel_data = try self.preparePixelData(surface, src_x, src_y, actual_w, actual_h);
    defer if (pixel_data.owned) self.allocator.free(pixel_data.data);

    // Encode and transmit in chunks
    try self.transmitImage(writer, pixel_data.data, actual_w, actual_h, total_size, options);
}

/// Prepared pixel data for transmission.
const PreparedData = struct {
    data: []const u8,
    owned: bool,
};

/// Prepare pixel data for transmission, extracting if necessary.
fn preparePixelData(
    self: *KittyGraphics,
    surface: Surface,
    src_x: u32,
    src_y: u32,
    width: u32,
    height: u32,
) !PreparedData {
    const bytes_per_pixel: usize = 4;
    const row_bytes = @as(usize, width) * bytes_per_pixel;

    // Check if we can use the raw data directly
    const can_use_direct = src_x == 0 and
        src_y == 0 and
        width == surface.width and
        height == surface.height and
        surface.stride == surface.width * 4;

    if (can_use_direct) {
        return .{
            .data = surface.pixels[0 .. row_bytes * @as(usize, height)],
            .owned = false,
        };
    }

    // Need to extract rows into contiguous buffer
    const total_size = row_bytes * @as(usize, height);
    const buffer = try self.allocator.alloc(u8, total_size);
    errdefer self.allocator.free(buffer);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_offset = @as(usize, src_y + y) * @as(usize, surface.stride) +
            @as(usize, src_x) * bytes_per_pixel;
        const dst_offset = @as(usize, y) * row_bytes;
        @memcpy(buffer[dst_offset..][0..row_bytes], surface.pixels[src_offset..][0..row_bytes]);
    }

    return .{
        .data = buffer,
        .owned = true,
    };
}

/// Transmit image data in chunks.
fn transmitImage(
    self: *KittyGraphics,
    writer: anytype,
    pixel_data: []const u8,
    width: u32,
    height: u32,
    total_size: usize,
    options: DrawOptions,
) !void {
    // Ensure encode buffer is large enough for one chunk
    self.encode_buffer.clearRetainingCapacity();
    try self.encode_buffer.ensureTotalCapacity(max_encoded_chunk_size + 256);

    var offset: usize = 0;
    var is_first_chunk = true;

    while (offset < total_size) {
        const remaining = total_size - offset;
        const chunk_size = @min(remaining, max_chunk_size);
        const is_last_chunk = (offset + chunk_size >= total_size);

        // Encode chunk to base64
        self.encode_buffer.clearRetainingCapacity();
        const chunk_data = pixel_data[offset..][0..chunk_size];
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk_size);
        try self.encode_buffer.resize(encoded_len);
        _ = std.base64.standard.Encoder.encode(self.encode_buffer.items, chunk_data);

        // Write APC sequence
        try writer.writeAll("\x1b_G");

        // Write control data (only full params on first chunk)
        if (is_first_chunk) {
            // Action: transmit (t) or transmit+display (T)
            const action: u8 = if (options.transmit_only) 't' else 'T';
            try writer.print("a={c},f=32,s={d},v={d}", .{ action, width, height });

            // Image ID
            if (options.image_id != 0) {
                try writer.print(",i={d}", .{options.image_id});
            }

            // Placement options (only if displaying)
            if (!options.transmit_only) {
                // Display dimensions
                if (options.columns != 0) {
                    try writer.print(",c={d}", .{options.columns});
                }
                if (options.rows != 0) {
                    try writer.print(",r={d}", .{options.rows});
                }

                // Z-index
                if (options.z_index != 0) {
                    try writer.print(",z={d}", .{options.z_index});
                }

                // Cursor movement
                if (options.no_cursor_move) {
                    try writer.writeAll(",C=1");
                }
            }
        }

        // Chunking indicator
        // For first chunk: append with comma if multi-chunk image
        // For continuation chunks: m= is the only param, no leading comma
        if (!is_last_chunk) {
            if (is_first_chunk) {
                try writer.writeAll(",m=1");
            } else {
                try writer.writeAll("m=1");
            }
        } else if (!is_first_chunk) {
            // Final chunk of multi-chunk: m=0 is the only param
            try writer.writeAll("m=0");
        }

        // Payload separator and data
        try writer.writeAll(";");
        try writer.writeAll(self.encode_buffer.items);

        // End APC sequence
        try writer.writeAll("\x1b\\");

        offset += chunk_size;
        is_first_chunk = false;
    }
}

/// Delete images from the terminal.
pub fn delete(self: *KittyGraphics, writer: anytype, options: DeleteOptions) !void {
    _ = self;

    try writer.writeAll("\x1b_Ga=d");

    // Deletion scope
    const scope_char: u8 = switch (options.scope) {
        .all_visible => 'a',
        .all_visible_and_free => 'A',
        .by_id => 'i',
        .by_id_and_free => 'I',
        .at_cursor => 'c',
        .at_cursor_and_free => 'C',
        .at_cell => 'p',
        .at_cell_and_free => 'P',
        .by_zindex => 'z',
        .by_zindex_and_free => 'Z',
    };
    try writer.print(",d={c}", .{scope_char});

    // Additional parameters based on scope
    switch (options.scope) {
        .by_id, .by_id_and_free => {
            // Always emit image_id for by_id scopes (required parameter)
            try writer.print(",i={d}", .{options.image_id});
        },
        .at_cell, .at_cell_and_free => {
            try writer.print(",x={d},y={d}", .{ options.x + 1, options.y + 1 });
        },
        .by_zindex, .by_zindex_and_free => {
            try writer.print(",z={d}", .{options.z_index});
        },
        else => {},
    }

    // Kitty graphics sequences require semicolon before terminator even with empty payload
    try writer.writeAll(";\x1b\\");
}

/// Move cursor to specified cell position (helper for positioning before draw).
pub fn moveCursor(writer: anytype, x: u16, y: u16) !void {
    // ANSI cursor position (1-indexed)
    try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

/// Send a Kitty graphics query to the terminal.
///
/// This writes a query command that the terminal will respond to if it supports
/// the Kitty graphics protocol. The caller is responsible for reading and parsing
/// the response (typically a `\x1b_G...` sequence with `OK` or error info).
///
/// Use this with a terminal input reader to detect Kitty graphics support at runtime.
/// Example response parsing is terminal-specific and left to the caller.
pub fn querySupport(writer: anytype) !void {
    // Send a query transmission (a=q) with minimal data
    // The response will contain i=31415926 if supported
    // f=32 means RGBA (4 bytes per pixel), s=1 v=1 means 1x1 pixel = 4 bytes
    // "AAAAAA==" is base64 for 4 zero bytes (transparent black pixel)
    try writer.writeAll("\x1b_Gi=31415926,a=q,s=1,v=1,f=32;AAAAAA==\x1b\\");
}

// ============================================================================
// Tests
// ============================================================================

test "KittyGraphics init and deinit" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    try std.testing.expect(kitty.encode_buffer.items.len == 0);
}

test "KittyGraphics draw small image" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    // Create a tiny 2x2 surface
    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.rgb(255, 0, 0));
    surface.setPixel(1, 0, Pixel.rgb(0, 255, 0));
    surface.setPixel(0, 1, Pixel.rgb(0, 0, 255));
    surface.setPixel(1, 1, Pixel.rgb(255, 255, 255));

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.draw(output.writer(), surface, .{ .image_id = 42 });

    // Verify output starts with APC and contains expected params
    try std.testing.expect(std.mem.startsWith(u8, output.items, "\x1b_G"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "a=T") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "f=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "s=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "v=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "i=42") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.items, "\x1b\\"));
}

test "KittyGraphics draw at position zero zero" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    // Explicitly place at (0, 0) - should emit cursor move sequence
    try kitty.draw(output.writer(), surface, .{
        .position = .{ .x = 0, .y = 0 },
    });

    // Should start with cursor position sequence (row 1, col 1 in ANSI)
    try std.testing.expect(std.mem.startsWith(u8, output.items, "\x1b[1;1H"));
}

test "KittyGraphics draw with options" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.draw(output.writer(), surface, .{
        .image_id = 1,
        .columns = 10,
        .rows = 5,
        .z_index = -1,
        .no_cursor_move = true,
    });

    try std.testing.expect(std.mem.indexOf(u8, output.items, "c=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "r=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "z=-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "C=1") != null);
}

test "KittyGraphics transmit only mode" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.draw(output.writer(), surface, .{
        .image_id = 1,
        .transmit_only = true,
    });

    // Should use a=t instead of a=T
    try std.testing.expect(std.mem.indexOf(u8, output.items, "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "a=T") == null);
}

test "KittyGraphics delete by id" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.delete(output.writer(), .{
        .scope = .by_id_and_free,
        .image_id = 42,
    });

    try std.testing.expect(std.mem.startsWith(u8, output.items, "\x1b_G"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "d=I") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "i=42") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.items, "\x1b\\"));
}

test "KittyGraphics delete all" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.delete(output.writer(), .{
        .scope = .all_visible_and_free,
    });

    try std.testing.expect(std.mem.indexOf(u8, output.items, "d=A") != null);
}

test "KittyGraphics chunking large images" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    // Create an image large enough to require chunking
    // max_chunk_size is 3072 raw bytes (encodes to 4096 base64 bytes)
    // Each pixel is 4 bytes, so 3072 / 4 = 768 pixels per chunk
    // A 64x64 image = 4096 pixels = 16384 bytes
    // 16384 / 3072 = 5.33, so 6 chunks needed
    var surface = try Surface.init(std.testing.allocator, 64, 64);
    defer surface.deinit();
    surface.clear(Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.draw(output.writer(), surface, .{ .image_id = 1 });

    // Count APC sequences (should be 6 for chunking)
    var apc_count: usize = 0;
    var i: usize = 0;
    while (i < output.items.len) : (i += 1) {
        if (std.mem.startsWith(u8, output.items[i..], "\x1b_G")) {
            apc_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), apc_count);

    // First chunk should have m=1, last should have m=0 or no m
    try std.testing.expect(std.mem.indexOf(u8, output.items, "m=1") != null);
}

test "KittyGraphics empty surface" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    // Empty surface should produce no output
    var surface = try Surface.init(std.testing.allocator, 0, 0) catch {
        // Surface.init rejects zero dimensions, which is expected
        return;
    };
    defer surface.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try kitty.draw(output.writer(), surface, .{});

    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "KittyGraphics source rectangle" {
    var kitty = KittyGraphics.init(std.testing.allocator);
    defer kitty.deinit();

    // Create a 4x4 surface with distinct quadrants
    var surface = try Surface.init(std.testing.allocator, 4, 4);
    defer surface.deinit();
    surface.fill(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, Pixel.rgb(255, 0, 0));
    surface.fill(.{ .x = 2, .y = 0, .width = 2, .height = 2 }, Pixel.rgb(0, 255, 0));
    surface.fill(.{ .x = 0, .y = 2, .width = 2, .height = 2 }, Pixel.rgb(0, 0, 255));
    surface.fill(.{ .x = 2, .y = 2, .width = 2, .height = 2 }, Pixel.rgb(255, 255, 0));

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    // Draw only the top-right 2x2 quadrant
    try kitty.draw(output.writer(), surface, .{
        .src_rect = .{ .x = 2, .y = 0, .width = 2, .height = 2 },
    });

    // Output should specify 2x2 dimensions
    try std.testing.expect(std.mem.indexOf(u8, output.items, "s=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "v=2") != null);
}

test "base64 encoding correctness" {
    // Test that base64 encoding produces expected output
    const input = [_]u8{ 255, 0, 0, 255 }; // Red pixel RGBA
    var output: [8]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&output, &input);

    // Expected base64 for [255, 0, 0, 255] is "/wAA/w=="
    try std.testing.expectEqualSlices(u8, "/wAA/w==", &output);
}

test "moveCursor helper" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try moveCursor(output.writer(), 10, 5);

    // Should produce ANSI cursor position (1-indexed)
    try std.testing.expectEqualSlices(u8, "\x1b[6;11H", output.items);
}

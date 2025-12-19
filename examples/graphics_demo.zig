const std = @import("std");
const termcat = @import("termcat");

const PixelBlitter = termcat.PixelBlitter;
const Surface = termcat.Surface;
const Pixel = Surface.Pixel;

const Mode = enum {
    cell,
    kitty,
};

const image_id: u32 = 1;
const header_rows: u16 = 4;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var backend = try termcat.Backend.init(allocator, .{ .enable_synchronized_output = true });
    defer backend.deinit();

    var renderer = try termcat.Renderer.init(allocator, backend.getSize(), backend.capabilities.color_depth);
    defer renderer.deinit();

    var kitty = termcat.graphics.KittyGraphics.init(allocator);
    defer kitty.deinit();

    var surface = try Surface.init(allocator, 40, 20);
    defer surface.deinit();
    drawSurface(&surface);

    const supports_kitty = backend.capabilities.kitty_graphics;

    var mode: Mode = .cell;
    var blit_mode: PixelBlitter.BlitterMode = .half_block;
    var kitty_visible = false;
    defer if (supports_kitty and kitty_visible) {
        kitty.delete(backend.writer(), .{ .image_id = image_id }) catch {};
        backend.flushOutput() catch {};
    };

    try renderFrame(&backend, &renderer, &kitty, &surface, mode, blit_mode, &kitty_visible);

    while (true) {
        const event = try backend.pollEvent(null);
        if (event == null) continue;

        var dirty = false;
        switch (event.?) {
            .key => |key| {
                if (key.special) |sp| {
                    if (sp == .escape) return;
                }
                if (key.codepoint) |cp| {
                    if (cp == 'q' or cp == 'Q') return;
                    if (cp == 'm' or cp == 'M') {
                        blit_mode = nextBlitMode(blit_mode);
                        dirty = true;
                    }
                    if (cp == 'k' or cp == 'K') {
                        if (supports_kitty) {
                            mode = if (mode == .cell) .kitty else .cell;
                            dirty = true;
                        }
                    }
                }
            },
            .resize => |new_size| {
                try renderer.resize(new_size);
                dirty = true;
            },
            else => {},
        }

        if (dirty) {
            try renderFrame(&backend, &renderer, &kitty, &surface, mode, blit_mode, &kitty_visible);
        }
    }
}

fn renderFrame(
    backend: *termcat.Backend,
    renderer: *termcat.Renderer,
    kitty: *termcat.graphics.KittyGraphics,
    surface: *const Surface,
    mode: Mode,
    blit_mode: PixelBlitter.BlitterMode,
    kitty_visible: *bool,
) !void {
    const caps = backend.capabilities;
    const buf = renderer.buffer();
    buf.clear();

    drawHeader(buf, caps, mode, blit_mode, surface);

    const content_y: u16 = header_rows;

    if (mode == .cell) {
        PixelBlitter.blit(buf, 0, content_y, surface.*, .{
            .mode = blit_mode,
            .color_depth = caps.color_depth,
        });
    } else if (!caps.kitty_graphics) {
        buf.print(0, content_y, "Kitty graphics not supported in this terminal.", termcat.Color.red, termcat.Color.default, .{});
    }

    try backend.beginSynchronizedOutput();
    errdefer backend.endSynchronizedOutput() catch {};

    try renderer.flush(backend.writer());
    try backend.endSynchronizedOutput();
    try backend.flushOutput();

    if (mode == .kitty and caps.kitty_graphics) {
        const cell_size = PixelBlitter.calcCellSize(surface.width, surface.height, blit_mode);
        try kitty.draw(backend.writer(), surface.*, .{
            .image_id = image_id,
            .position = .{ .x = 0, .y = content_y },
            .columns = cell_size.width,
            .rows = cell_size.height,
            .z_index = 1,
        });
        try backend.flushOutput();
        kitty_visible.* = true;
    } else if (kitty_visible.* and caps.kitty_graphics) {
        try kitty.delete(backend.writer(), .{ .image_id = image_id });
        try backend.flushOutput();
        kitty_visible.* = false;
    }
}

fn drawHeader(
    buf: *termcat.Buffer,
    caps: termcat.Capabilities,
    mode: Mode,
    blit_mode: PixelBlitter.BlitterMode,
    surface: *const Surface,
) void {
    buf.print(0, 0, "termcat Graphics Demo", termcat.Color.bright_white, termcat.Color.default, .{ .bold = true });
    buf.print(0, 1, "m: cycle blitter | k: toggle kitty (if supported) | q: quit", termcat.Color.bright_black, termcat.Color.default, .{});

    var line_buf: [128]u8 = undefined;
    const mode_name = if (mode == .cell) "cell" else "kitty";
    const status_line = std.fmt.bufPrint(&line_buf, "Mode: {s} ({s}) | Kitty: {s} | Sync: {s}", .{
        mode_name,
        @tagName(blit_mode),
        boolLabel(caps.kitty_graphics),
        boolLabel(caps.synchronized_output),
    }) catch "Mode: ...";
    buf.print(0, 2, status_line, termcat.Color.cyan, termcat.Color.default, .{});

    const size_line = std.fmt.bufPrint(&line_buf, "Surface: {d}x{d} px", .{ surface.width, surface.height }) catch "Surface: ...";
    buf.print(0, 3, size_line, termcat.Color.default, termcat.Color.default, .{});
}

fn drawSurface(surface: *Surface) void {
    surface.clear(Pixel.black);

    const w = surface.width;
    const h = surface.height;
    const w_max = if (w > 1) w - 1 else 1;
    const h_max = if (h > 1) h - 1 else 1;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const r: u8 = @intCast((x * 255) / w_max);
            const g: u8 = @intCast((y * 255) / h_max);
            const b: u8 = @intCast(255 - ((x + y) * 255) / (w_max + h_max));
            surface.setPixel(x, y, Pixel.rgb(r, g, b));
        }
    }

    surface.fill(.{ .x = 2, .y = 2, .width = 8, .height = 4 }, Pixel.rgba(255, 255, 255, 200));

    const cx: i32 = @intCast(w / 2);
    const cy: i32 = @intCast(h / 2);
    const radius: i32 = @intCast(@max(2, @min(w, h) / 3));
    const radius_sq: i32 = radius * radius;

    var iy: i32 = 0;
    while (iy < @as(i32, @intCast(h))) : (iy += 1) {
        var ix: i32 = 0;
        while (ix < @as(i32, @intCast(w))) : (ix += 1) {
            const dx = ix - cx;
            const dy = iy - cy;
            if (dx * dx + dy * dy <= radius_sq) {
                const base = surface.getPixel(@intCast(ix), @intCast(iy)) orelse Pixel.black;
                const overlay = Pixel.rgba(255, 255, 255, 140);
                surface.setPixel(@intCast(ix), @intCast(iy), overlay.blend(base));
            }
        }
    }
}

fn nextBlitMode(mode: PixelBlitter.BlitterMode) PixelBlitter.BlitterMode {
    return switch (mode) {
        .ascii => .half_block,
        .half_block => .quadrant,
        .quadrant => .braille,
        .braille => .ascii,
    };
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "on" else "off";
}

# termcat

A minimal, fast cell-based terminal I/O library for Zig in the style of [termbox2](https://github.com/termbox/termbox2).

## Features

- **Cell-based rendering**: Efficient diff-based updates that minimize terminal output
- **Input handling**: Keyboard, mouse, bracketed paste, and focus events
- **Color support**: Automatic fallback from true color to 256 to 16 colors based on terminal capabilities
- **Unicode support**: Wide characters (CJK, emoji) and combining marks
- **Text attributes**: Bold, italic, underline, strikethrough, dim, reverse, blink

## Platform Support

Currently supports POSIX systems (Linux, macOS, BSD). Windows support (ConPTY/Win32) is planned.

## Installation

Add termcat as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .termcat = .{
        .url = "https://github.com/yourusername/termcat/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const termcat = b.dependency("termcat", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("termcat", termcat.module("termcat"));
```

## Quick Start

```zig
const std = @import("std");
const termcat = @import("termcat");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal backend
    var backend = try termcat.PosixBackend.init(allocator, .{});
    defer backend.deinit();

    // Create renderer
    const size = backend.getSize();
    var renderer = try termcat.Renderer.init(allocator, size, backend.capabilities.color_depth);
    defer renderer.deinit();

    // Draw to buffer
    const buf = renderer.buffer();
    buf.print(0, 0, "Hello, termcat!", termcat.Color.green, termcat.Color.default, .{ .bold = true });

    // Flush to terminal
    try renderer.flush(backend.writer());
    try backend.flushOutput();

    // Event loop
    while (true) {
        if (try backend.pollEvent(null)) |event| {
            switch (event) {
                .key => |key| {
                    if (key.codepoint == 'q') return;
                },
                .resize => |new_size| {
                    try renderer.resize(new_size);
                },
                else => {},
            }
        }
    }
}
```

## API Overview

### Backend

`PosixBackend` handles terminal setup, capability detection, and I/O:

```zig
var backend = try termcat.PosixBackend.init(allocator, .{
    .enable_mouse = true,           // Enable mouse events
    .enable_bracketed_paste = true, // Enable paste detection
    .enable_focus_events = true,    // Enable focus in/out events
    .install_sigwinch = true,       // Handle terminal resize
});
defer backend.deinit();

// Get terminal size
const size = backend.getSize();

// Poll for events (blocking)
if (try backend.pollEvent(null)) |event| { ... }

// Poll with timeout (milliseconds)
if (try backend.pollEvent(100)) |event| { ... }
```

### Renderer

`Renderer` provides double-buffered, diff-based rendering:

```zig
var renderer = try termcat.Renderer.init(allocator, size, color_depth);
defer renderer.deinit();

// Get buffer for drawing
const buf = renderer.buffer();

// Flush changes to terminal
try renderer.flush(backend.writer());

// Handle resize
try renderer.resize(new_size);

// Set cursor position (or null to hide)
renderer.setCursor(.{ .x = 10, .y = 5 });
```

### Buffer

`Buffer` is the drawing surface:

```zig
// Print text with colors and attributes
buf.print(x, y, "text", fg_color, bg_color, .{ .bold = true });

// Set individual cell
buf.setCell(x, y, cell);

// Fill rectangle
buf.fill(.{ .x = 0, .y = 0, .width = 10, .height = 5 }, cell);

// Clear buffer
buf.clear();
```

### Colors

```zig
// Named colors (indices 0-15)
const red = termcat.Color.red;
const bright_green = termcat.Color.bright_green;

// 256-color palette
const color: termcat.Color = .{ .index = 196 };

// True color (24-bit RGB)
const purple = termcat.Color.fromRgb(128, 0, 255);

// HSL color
const orange = termcat.Color.fromHsl(30, 100, 50);

// Grayscale
const gray = termcat.Color.fromGray(128);

// Default terminal color
const default_color: termcat.Color = .default;
```

Colors are automatically downgraded based on terminal capabilities.

### Attributes

```zig
const attrs: termcat.Attributes = .{
    .bold = true,
    .italic = true,
    .underline = false,
    .strikethrough = false,
    .reverse = false,
    .dim = false,
    .blink = false,
};
```

### Events

```zig
switch (event) {
    .key => |key| {
        if (key.codepoint) |cp| {
            // Regular character (e.g., 'a', 'Z', space)
        }
        if (key.special) |sp| {
            // Special key (e.g., .enter, .escape, .up, .f1)
        }
        // Modifiers
        if (key.mods.ctrl) { ... }
        if (key.mods.alt) { ... }
        if (key.mods.shift) { ... }
    },
    .mouse => |mouse| {
        // mouse.x, mouse.y - position
        // mouse.button - .left, .right, .middle, .wheel_up, .wheel_down, .move, .release
        // mouse.mods - modifier keys
    },
    .resize => |new_size| {
        // new_size.width, new_size.height
    },
    .paste => |text| {
        // Bracketed paste content (valid until next pollEvent)
    },
    .focus => |focused| {
        // true = gained focus, false = lost focus
    },
}
```

### Capability Detection

```zig
const caps = termcat.detectCapabilities();
// caps.color_depth: .mono, .basic, .color_256, or .true_color
// caps.mouse: bool
// caps.bracketed_paste: bool
// caps.focus_events: bool
```

### Unicode Utilities

```zig
// Get display width of a codepoint
const width = termcat.unicode.codePointWidth(cp); // 0, 1, or 2

// Get display width of a string
const str_width = termcat.unicode.stringWidth("Hello");
```

## Examples

Build and run examples:

```bash
# Input event logger
zig build input_logger

# Color grid demo
zig build color_grid
```

## Building

```bash
# Build library and examples
zig build

# Run tests
zig build test

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Known Limitations

- POSIX only (Windows planned)
- Maximum 2 combining marks per cell
- No sixel/image support
- No synchronized output (CSI ? 2026)

## License

MIT

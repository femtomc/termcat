# Termcat Design Document

Termcat is a minimal, fast cell-based terminal I/O library for Zig in the style of [termbox2](https://github.com/termbox/termbox2).

## Goals

1. **Minimal** - Small API surface, no unnecessary features
2. **Fast** - Diff-based rendering, zero allocations in hot paths
3. **Portable** - POSIX first, Windows as follow-up
4. **Correct** - Proper Unicode handling, robust input decoding

## Target Platforms

| Platform | Priority | Backend |
|----------|----------|---------|
| Linux | MVP | POSIX termios + escape sequences |
| macOS | MVP | POSIX termios + escape sequences |
| FreeBSD | MVP | POSIX termios + escape sequences |
| Windows | Follow-up | ConPTY / Win32 Console API |

## API Surface

### Core Types

```zig
/// Terminal instance - manages state and I/O
pub const Terminal = struct {
    pub const InitOptions = struct {
        install_sigwinch: bool = true,  // Install SIGWINCH handler
    };

    pub fn init(allocator: Allocator) !Terminal;
    pub fn initWithOptions(allocator: Allocator, options: InitOptions) !Terminal;
    pub fn deinit(self: *Terminal) void;

    /// Notify terminal of resize (for apps managing their own signals)
    pub fn notifyResize(self: *Terminal) void;

    /// Poll for events with optional timeout (milliseconds).
    /// Returns null on timeout.
    /// IMPORTANT: Event payload data (e.g., paste slice) is only valid until
    /// the next call to pollEvent/peekEvent. Copy if needed longer.
    pub fn pollEvent(self: *Terminal, timeout_ms: ?u32) !?Event;

    /// Non-blocking event check. Same lifetime rules as pollEvent.
    pub fn peekEvent(self: *Terminal) !?Event;

    /// Get current terminal dimensions.
    /// After a resize event, this returns the new size.
    pub fn size(self: *Terminal) Size;

    /// Access the cell buffer for drawing.
    /// WARNING: The returned pointer is invalidated on resize events.
    /// After receiving Event.resize, call buffer() again to get the new buffer.
    pub fn buffer(self: *Terminal) *Buffer;

    /// Flush buffer changes to terminal (diff-based).
    /// NOTE: Does NOT handle resizes. Always call pollEvent() to process
    /// resize events before flush(). Flushing without processing resize
    /// events may produce incorrect output.
    pub fn flush(self: *Terminal) !void;

    /// Clear screen and reset buffer.
    /// Deferred write - actual I/O happens on next flush().
    pub fn clear(self: *Terminal) void;

    /// Set cursor position (or hide with null).
    /// Deferred write - actual I/O happens on next flush().
    pub fn setCursor(self: *Terminal, pos: ?Position) void;
};

/// Single terminal cell
pub const Cell = struct {
    char: u21,        // Unicode codepoint (or first codepoint of grapheme)
    fg: Color,        // Foreground color
    bg: Color,        // Background color
    attrs: Attributes, // Bold, italic, underline, etc.
};

/// The default cell used for clear() and out-of-bounds reads.
pub const default_cell = Cell{
    .char = ' ',           // Space character
    .fg = .default,        // Terminal default foreground
    .bg = .default,        // Terminal default background
    .attrs = .{},          // No attributes
};

/// Cell buffer for drawing.
/// All coordinates are bounds-checked: out-of-range writes are silently ignored,
/// out-of-range reads return default_cell. This allows safe clipping without
/// explicit bounds checks at every call site.
pub const Buffer = struct {
    width: u16,
    height: u16,
    cells: []Cell,

    /// Set cell at position. Out-of-bounds coordinates are silently ignored.
    pub fn setCell(self: *Buffer, x: u16, y: u16, cell: Cell) void;

    /// Get cell at position. Out-of-bounds returns default_cell.
    pub fn getCell(self: *Buffer, x: u16, y: u16) Cell;

    /// Write string starting at position (handles wide chars).
    /// Characters that extend beyond the right edge are clipped.
    /// Wide characters at the final column are replaced with a space.
    pub fn print(self: *Buffer, x: u16, y: u16, str: []const u8, fg: Color, bg: Color) void;

    /// Fill rectangle with cell. Rectangle is clipped to buffer bounds.
    pub fn fill(self: *Buffer, rect: Rect, cell: Cell) void;

    /// Clear buffer to default_cell.
    pub fn clear(self: *Buffer) void;
};

/// Terminal dimensions
pub const Size = struct {
    width: u16,
    height: u16,
};

/// Position in terminal
pub const Position = struct {
    x: u16,
    y: u16,
};

/// Rectangle region
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};
```

### Colors

```zig
pub const Color = union(enum) {
    default,                    // Terminal default color
    index: u8,                  // 256-color palette index (0-255)
    rgb: struct { r: u8, g: u8, b: u8 }, // True color (24-bit)

    // Named colors (map to indices 0-15)
    pub const black: Color = .{ .index = 0 };
    pub const red: Color = .{ .index = 1 };
    pub const green: Color = .{ .index = 2 };
    pub const yellow: Color = .{ .index = 3 };
    pub const blue: Color = .{ .index = 4 };
    pub const magenta: Color = .{ .index = 5 };
    pub const cyan: Color = .{ .index = 6 };
    pub const white: Color = .{ .index = 7 };
    // ... bright variants 8-15
};
```

### Attributes

```zig
pub const Attributes = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reverse: bool = false,
    dim: bool = false,
    blink: bool = false,
    _padding: u1 = 0,
};
```

### Events

```zig
pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    resize: Size,
    paste: []const u8,  // Bracketed paste content
    focus: bool,        // Focus in/out
};

/// Key event. Invariants:
/// - Exactly one of `codepoint` or `special` is non-null (mutually exclusive)
/// - For regular characters: codepoint is set, special is null
/// - For special keys: special is set, codepoint is null
/// - Modifiers apply to both types
///
/// Canonicalization rules:
/// - Enter key → special=.enter (not codepoint=13)
/// - Tab key → special=.tab (not codepoint=9)
/// - Escape key → special=.escape (not codepoint=27)
/// - Backspace → special=.backspace (not codepoint=127 or 8)
/// - Ctrl+letter → codepoint='a'-'z' with mods.ctrl=true (not codepoint=1-26)
/// - Alt+key → codepoint/special with mods.alt=true (not ESC prefix)
pub const Key = struct {
    codepoint: ?u21,    // Unicode codepoint for regular keys, null for special
    special: ?Special,  // Special key (arrows, function keys, etc.)
    mods: Modifiers,    // Ctrl, Alt, Shift

    pub const Special = enum {
        escape,
        enter,
        tab,
        backspace,
        delete,
        insert,
        home,
        end,
        page_up,
        page_down,
        up,
        down,
        left,
        right,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    };
};

pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _padding: u5 = 0,
};

pub const Mouse = struct {
    x: u16,
    y: u16,
    button: Button,
    mods: Modifiers,

    pub const Button = enum {
        left,
        middle,
        right,
        release,
        wheel_up,
        wheel_down,
        move,  // Motion with button held
    };
};
```

## Buffer Model

### Double Buffering with Diff

Termcat uses double buffering to minimize terminal output:

1. **Front buffer** - Current state of the terminal
2. **Back buffer** - Desired state (user draws here via `buffer()`)

On `flush()`:
- Compare back buffer to front buffer cell-by-cell
- Emit escape sequences only for changed cells
- Update front buffer to match back buffer

This minimizes flicker and bandwidth, especially over SSH.

### Cell Representation

Each cell stores:
- One Unicode codepoint (u21 covers all of Unicode scalar values)
- Foreground and background colors
- Text attributes

**Limitation**: A cell holds exactly one codepoint. Complex grapheme clusters
(emoji ZWJ sequences, combining characters) cannot be fully represented.
The first codepoint is stored; subsequent codepoints are dropped. This is
an intentional MVP simplification. Future grapheme support would require
a different cell layout (e.g., grapheme index into a string table).

**Wide characters** (CJK, emoji) span two cells:
- First cell stores the character with `char` set to the codepoint
- Second cell is a **continuation marker**: `char = 0` (null codepoint)

The renderer skips continuation cells. When diff-comparing, a continuation
cell only matches another continuation cell.

**Wide char at final column**: If a double-width character would start at
`x = width - 1`, it cannot fit. The cell is filled with a space instead,
and the wide character is not rendered (clipped).

### Memory Layout

```
cells: [height * width]Cell
```

Row-major order. Position (x, y) maps to index `y * width + x`.

## Input Model

### Input Decoding Pipeline

```
TTY fd → read() → byte buffer → decoder → Event queue
```

1. **Read**: Non-blocking read from TTY file descriptor
2. **Buffer**: Accumulate bytes (escape sequences can span reads)
3. **Decode**: State machine parses:
   - UTF-8 sequences → Unicode codepoints
   - Escape sequences → Special keys, mouse, etc.
   - CSI sequences → Extended input (modifiers, mouse coords)
4. **Queue**: Events delivered via `pollEvent()`

### Supported Input Protocols

| Protocol | Description | Detection |
|----------|-------------|-----------|
| Standard | Basic keys, limited modifiers | Always |
| xterm mouse | SGR 1006 mouse reporting | Query + enable |
| Bracketed paste | Paste detection | Query + enable |
| Focus events | Window focus | Query + enable |
| Kitty keyboard | Full modifier support | Query |

### Timeout Handling

`pollEvent(timeout_ms)` uses `poll()` on POSIX:
- `null` timeout = block forever
- `0` = non-blocking (same as `peekEvent`)
- `N` = wait up to N milliseconds

### Event Data Lifetime

Event payload data has limited lifetime:

- **`Event.paste` slice**: Points to internal ring buffer. Valid only until the
  next call to `pollEvent()` or `peekEvent()`. If the application needs to
  retain paste data, it must copy it.

- **Other events**: `Key`, `Mouse`, `Size`, `bool` are value types with no
  lifetime concerns.

Example:
```zig
const event = try term.pollEvent(100);
if (event) |e| {
    switch (e) {
        .paste => |data| {
            // data is only valid here!
            const copy = try allocator.dupe(u8, data);
            defer allocator.free(copy);
            // ... use copy ...
        },
        else => {},
    }
}
// data is invalid after this point
```

## Color/Attribute Pipeline

### Capability Detection

On init, detect terminal capabilities:

1. **TERM environment** - Base capability set
2. **COLORTERM** - True color hint
3. **Terminfo/hardcoded** - Known terminal behavior
4. **Query sequences** - Runtime capability queries (DA1, etc.)

### Color Depth Levels

| Level | Colors | Detection |
|-------|--------|-----------|
| Mono | 2 | TERM contains "mono" |
| Basic | 8 | Default fallback |
| 256 | 256 | TERM contains "256color" |
| True | 16M | COLORTERM=truecolor/24bit |

### Fallback Strategy

When requested color depth exceeds terminal capability:
- True color → nearest 256-color
- 256-color → nearest 16-color
- 16-color → nearest 8-color

Use color distance (e.g., weighted RGB distance) for approximation.

## Unicode Handling

### Display Width

Use Unicode East Asian Width property:
- Narrow (N, Na, H): width 1
- Wide (W, F): width 2
- Ambiguous (A): configurable (default 1)

Implementation options:
1. **Lookup table** - Generated from Unicode data
2. **wcwidth** - Link to system libc (less portable)
3. **Hardcoded ranges** - Approximate but fast

MVP: Hardcoded ranges for common cases (CJK, emoji).
Follow-up: Full Unicode 15.0 table generation.

### Grapheme Clusters

For MVP, handle single codepoints. Complex grapheme clusters (emoji ZWJ sequences, combining marks) treated as:
- First codepoint rendered
- Subsequent codepoints in cluster ignored

Follow-up: Proper grapheme segmentation.

## Backend Architecture

### POSIX Backend

```
src/
  backend/
    posix.zig       # POSIX implementation
    termios.zig     # Terminal mode setup
    input.zig       # Input decoder
    output.zig      # Output/escape sequences
    capabilities.zig # Capability detection
```

Key operations:
- **init**: Save terminal state, set raw mode, enable protocols
- **deinit**: Restore terminal state, disable protocols
- **read**: Non-blocking read from stdin fd
- **write**: Buffered write to stdout fd
- **poll**: Wait for input with timeout

### Windows Backend (Follow-up)

```
src/
  backend/
    windows.zig     # Windows implementation
    console.zig     # Win32 Console API
    conpty.zig      # ConPTY for modern terminals
```

## Signal Handling

### SIGWINCH (Terminal Resize)

Termcat installs a SIGWINCH handler during `init()` to detect terminal resizes.

**Signal handler behavior:**
- Sets an internal atomic flag indicating resize occurred
- Does NOT allocate memory or perform I/O in the handler
- The actual resize is processed lazily on next `pollEvent()` or `peekEvent()`

**Application integration:**
- If the application has its own SIGWINCH handler, it can call `Terminal.notifyResize()`
  instead of relying on termcat's handler
- Call `Terminal.initWithOptions()` with `.install_sigwinch = false` to disable auto-install

```zig
// Option 1: Let termcat handle SIGWINCH (default)
var term = try Terminal.init(allocator);

// Option 2: Application manages signals
var term = try Terminal.initWithOptions(allocator, .{ .install_sigwinch = false });
// In your signal handler:
term.notifyResize();
```

### Resize Event Flow

Resizes are ONLY processed by `pollEvent()` / `peekEvent()`. The `flush()` function
does NOT process or emit resize events.

**Flow:**
1. SIGWINCH received → internal atomic flag set
2. On next `pollEvent()` / `peekEvent()`:
   - Check atomic flag
   - If set: query actual terminal size via `ioctl(TIOCGWINSZ)`
   - Reallocate front/back buffers to new size
   - Clear atomic flag
   - Return `Event.resize` with new dimensions
3. Application receives resize event
4. Application MUST call `buffer()` again (old pointer is now invalid)
5. Application redraws to new buffer
6. Application calls `flush()`

**Buffer invalidation**: After receiving `Event.resize`, any previously obtained
`*Buffer` pointer is INVALID and MUST NOT be used. Call `buffer()` to get the
new buffer with updated dimensions.

**Typical event loop:**
```zig
while (running) {
    // Always poll for events first - this handles resizes
    while (try term.peekEvent()) |event| {
        switch (event) {
            .resize => |new_size| {
                // Buffer was reallocated - get new pointer
                buf = term.buffer();
            },
            .key => |key| handleKey(key),
            // ...
        }
    }

    // Now safe to draw and flush
    draw(buf);
    try term.flush();
}
```

## Testing Strategy

### Unit Tests

Each module has unit tests for:
- Color conversion and fallbacks
- Input decoding (known escape sequences)
- Buffer operations
- Unicode width calculation

Run with `zig build test`.

### PTY Integration Tests

For end-to-end testing without a real terminal:

1. Create PTY pair (master/slave)
2. Initialize termcat on slave
3. Inject input via master
4. Verify output via master
5. Check state via termcat API

```zig
test "init sets raw mode" {
    const pty = try Pty.open();
    defer pty.close();

    var term = try Terminal.init(testing.allocator);
    defer term.deinit();

    // Verify raw mode escape sequences were sent
    const output = try pty.readOutput();
    try testing.expect(mem.indexOf(u8, output, "\x1b[?1049h") != null); // Alt screen
}

test "key input decoding" {
    const pty = try Pty.open();
    defer pty.close();

    var term = try Terminal.init(testing.allocator);
    defer term.deinit();

    // Inject arrow key sequence
    try pty.writeInput("\x1b[A");

    const event = try term.pollEvent(100);
    try testing.expect(event.?.key.special == .up);
}
```

### Fixture Data

Maintain test fixtures for:
- Known terminal escape sequences (xterm, VT100, etc.)
- Edge cases (malformed sequences, partial reads)
- Unicode edge cases (wide chars, combining marks)

## MVP Scope

### MVP Features

The following features are in scope for the initial release:

- POSIX backend (Linux, macOS, FreeBSD)
- Terminal init/deinit (raw mode, alternate screen)
- Cell buffer with diff-based rendering
- Basic input decoding (keys, arrows, function keys)
- Mouse support (SGR 1006)
- 8/16/256/true color with automatic fallback
- Basic Unicode width (CJK ranges, common emoji)
- Resize detection (SIGWINCH with opt-out)
- PTY-based integration tests

### Follow-up Work (Post-MVP)

The following are explicitly out of scope for MVP:

- Windows backend (ConPTY)
- Kitty keyboard protocol (full modifier detection)
- Full Unicode 15.0 width tables (generated from UCD)
- Grapheme cluster handling (requires cell layout changes)
- Synchronized output (DCS sequences)
- Clipboard integration
- Undercurl and other extended attributes
- Terminfo parsing (vs hardcoded sequences)

## File Structure

```
termcat/
├── src/
│   ├── root.zig          # Public API exports
│   ├── Terminal.zig      # Main Terminal type
│   ├── Buffer.zig        # Cell buffer implementation
│   ├── Cell.zig          # Cell, Color, Attributes types
│   ├── Event.zig         # Event types
│   ├── backend/
│   │   ├── posix.zig     # POSIX backend
│   │   └── windows.zig   # Windows backend (follow-up)
│   ├── input/
│   │   ├── decoder.zig   # Input state machine
│   │   └── sequences.zig # Known escape sequences
│   ├── output/
│   │   ├── writer.zig    # Buffered output
│   │   └── escape.zig    # Escape sequence generation
│   └── unicode/
│       └── width.zig     # Character width lookup
├── docs/
│   └── DESIGN.md         # This document
├── build.zig
└── build.zig.zon
```

## References

- [termbox2](https://github.com/termbox/termbox2) - Primary inspiration
- [XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- [ECMA-48](https://www.ecma-international.org/publications-and-standards/standards/ecma-48/) - Control functions
- [Unicode East Asian Width](https://www.unicode.org/reports/tr11/)
- [Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)

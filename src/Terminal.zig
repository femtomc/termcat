const std = @import("std");
const builtin = @import("builtin");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;
const Plane = @import("Plane.zig");
const Compositor = @import("Compositor.zig");
const Renderer = @import("Renderer.zig");
const Event = @import("Event.zig");
const Size = Event.Size;
const Position = Event.Position;
const Rect = Event.Rect;
const unicode = @import("unicode/width.zig");

// Platform-specific backend selection
const posix_backend = @import("backend/posix.zig");
const windows_backend = @import("backend/windows.zig");

const Backend = if (builtin.os.tag == .windows)
    windows_backend.WindowsBackend
else
    posix_backend.PosixBackend;

const Capabilities = if (builtin.os.tag == .windows)
    windows_backend.Capabilities
else
    posix_backend.Capabilities;

const InitOptions = if (builtin.os.tag == .windows)
    windows_backend.InitOptions
else
    posix_backend.InitOptions;

/// High-level terminal facade with auto-present.
///
/// Terminal provides a simplified API for terminal applications by coordinating:
/// - Backend: Platform-specific terminal I/O
/// - Renderer: Diff-based terminal output
/// - Compositor: Plane composition with dirty tracking
/// - Root plane: Primary drawing surface
///
/// Key features:
/// - Automatic resize handling
/// - Auto-present mode for immediate rendering
/// - Convenience drawing methods on the root plane
/// - Simplified event polling
///
/// Example usage:
/// ```zig
/// var term = try Terminal.init(allocator, .{});
/// defer term.deinit();
///
/// term.draw(10, 5, "Hello, World!", .white, .default, .{});
/// try term.present();
///
/// while (true) {
///     if (try term.pollEvent(100)) |event| {
///         switch (event) {
///             .key => |key| if (key.codepoint == 'q') break,
///             .resize => {}, // Handled automatically
///             else => {},
///         }
///     }
/// }
/// ```
pub const Terminal = @This();

/// Platform-specific backend
backend: Backend,
/// Diff-based renderer
renderer: Renderer,
/// Plane compositor
compositor: Compositor,
/// Root plane (full screen)
root: *Plane,
/// Allocator for internal operations
allocator: std.mem.Allocator,
/// Whether auto-present is enabled (present after each draw operation)
auto_present: bool,
/// Whether there are pending changes that need presenting
dirty: bool,

/// Terminal initialization options
pub const Options = struct {
    /// Backend init options (mouse, paste, focus, sigwinch)
    backend: InitOptions = .{},
    /// Enable auto-present mode (present after each draw operation)
    auto_present: bool = false,
};

/// Initialize the terminal.
///
/// This sets up the backend (raw mode, alternate screen), creates the renderer
/// and compositor, and initializes the root plane to the terminal size.
///
/// Caller must call `deinit` to restore terminal state.
pub fn init(allocator: std.mem.Allocator, options: Options) !Terminal {
    // Initialize backend first
    var bkend = try Backend.init(allocator, options.backend);
    errdefer bkend.deinit();

    const term_size = bkend.getSize();

    // Initialize renderer
    var renderer_inst = try Renderer.init(allocator, term_size, bkend.capabilities.color_depth);
    errdefer renderer_inst.deinit();

    // Initialize root plane
    const root = try Plane.initRoot(allocator, term_size);
    errdefer root.deinit();

    // Build terminal and then wire compositor to the renderer's buffer.
    var term = Terminal{
        .backend = bkend,
        .renderer = renderer_inst,
        .compositor = undefined,
        .root = root,
        .allocator = allocator,
        .auto_present = options.auto_present,
        .dirty = false,
    };

    // Important: compositor needs a pointer to the renderer's back buffer
    // after the renderer has reached its final location. Taking the pointer
    // before constructing `term` would dangle after the move.
    term.compositor = Compositor.init(allocator, term.renderer.buffer());
    return term;
}

/// Clean up and restore terminal state.
pub fn deinit(self: *Terminal) void {
    self.compositor.deinit();
    self.root.deinit();
    self.renderer.deinit();
    self.backend.deinit();
    self.* = undefined;
}

/// Get the terminal size.
pub fn size(self: *const Terminal) Size {
    return self.backend.size;
}

/// Get the terminal capabilities.
pub fn capabilities(self: *const Terminal) Capabilities {
    return self.backend.capabilities;
}

/// Get the root plane for direct manipulation.
pub fn rootPlane(self: *Terminal) *Plane {
    return self.root;
}

// ============================================================================
// Drawing operations
// ============================================================================

/// Draw text at the given position on the root plane.
pub fn draw(
    self: *Terminal,
    x: u16,
    y: u16,
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) void {
    self.root.print(x, y, text, fg, bg, attrs);
    // Use proper Unicode width calculation for dirty region
    const cell_width = unicode.stringWidth(text);
    self.markDirtyRect(.{ .x = x, .y = y, .width = @intCast(@min(cell_width, std.math.maxInt(u16))), .height = 1 });
}

/// Set a single cell on the root plane.
pub fn setCell(self: *Terminal, x: u16, y: u16, cell: Cell) void {
    self.root.setCell(x, y, cell);
    self.markDirtyRect(.{ .x = x, .y = y, .width = 1, .height = 1 });
}

/// Get a cell from the root plane.
pub fn getCell(self: *const Terminal, x: u16, y: u16) Cell {
    return self.root.getCell(x, y);
}

/// Fill a rectangle on the root plane.
pub fn fill(self: *Terminal, rect: Rect, cell: Cell) void {
    self.root.fill(rect, cell);
    self.markDirtyRect(rect);
}

/// Clear the entire root plane.
pub fn clear(self: *Terminal) void {
    self.root.clear();
    self.compositor.invalidateAll();
    self.dirty = true;
    self.maybeAutoPresent();
}

// ============================================================================
// Plane management
// ============================================================================

/// Create a child plane at the given position.
/// The plane is automatically added to the root's z-order (topmost).
pub fn createPlane(self: *Terminal, x: i32, y: i32, dimensions: Size) !*Plane {
    return Plane.initChild(self.root, x, y, dimensions);
}

/// Invalidate a plane (mark its visible area as dirty).
/// Call this after modifying a plane's content.
pub fn invalidatePlane(self: *Terminal, plane: *const Plane) !void {
    try self.compositor.invalidatePlane(plane);
    self.dirty = true;
}

/// Invalidate a plane after moving it.
/// Call this AFTER moving a plane, passing the old position.
pub fn invalidatePlaneMove(self: *Terminal, plane: *const Plane, old_x: i32, old_y: i32) !void {
    try self.compositor.invalidatePlaneMove(plane, old_x, old_y);
    self.dirty = true;
}

// ============================================================================
// Rendering
// ============================================================================

/// Present all pending changes to the terminal.
///
/// This composes all visible planes and flushes the result to the terminal.
/// Only changed regions are rendered (diff-based).
/// Uses synchronized output (DEC mode 2026) for flicker-free rendering
/// on terminals that support it.
pub fn present(self: *Terminal) !void {
    // Ensure compositor targets the current renderer buffer (Terminal can be moved).
    self.compositor.target = self.renderer.buffer();

    // Compose planes into renderer's back buffer
    const dirty_regions = try self.compositor.compose(self.root);
    defer self.allocator.free(dirty_regions);

    // Begin synchronized output for flicker-free rendering
    try self.backend.beginSynchronizedOutput();
    // Ensure sync output is disabled on error (ignore errors in cleanup)
    errdefer self.backend.endSynchronizedOutput() catch {};

    // Flush to terminal
    try self.renderer.flush(self.backend.writer());

    // End synchronized output
    try self.backend.endSynchronizedOutput();

    try self.backend.flushOutput();

    self.dirty = false;
}

/// Set the cursor position (visible cursor).
pub fn setCursor(self: *Terminal, pos: ?Position) void {
    self.renderer.setCursor(pos);
    if (self.renderer.cursor_dirty) {
        self.dirty = true;
        self.maybeAutoPresent();
    }
}

/// Show the cursor at the given position.
pub fn showCursor(self: *Terminal, x: u16, y: u16) void {
    self.setCursor(.{ .x = x, .y = y });
}

/// Hide the cursor.
pub fn hideCursor(self: *Terminal) void {
    self.setCursor(null);
}

// ============================================================================
// Events
// ============================================================================

/// Poll for an event with optional timeout (in milliseconds).
///
/// Returns null on timeout. Resize events are handled automatically,
/// resizing the root plane and renderer.
pub fn pollEvent(self: *Terminal, timeout_ms: ?u32) !?Event.Event {
    const event = try self.backend.pollEvent(timeout_ms);

    if (event) |ev| {
        switch (ev) {
            .resize => |new_size| {
                try self.handleResize(new_size);
            },
            else => {},
        }
    }

    return event;
}

/// Non-blocking event check.
pub fn peekEvent(self: *Terminal) !?Event.Event {
    return self.pollEvent(0);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Handle terminal resize.
fn handleResize(self: *Terminal, new_size: Size) !void {
    // Resize renderer
    try self.renderer.resize(new_size);

    // Resize root plane
    try self.root.resize(new_size);

    // Re-initialize compositor with new buffer
    self.compositor.deinit();
    self.compositor = Compositor.init(self.allocator, self.renderer.buffer());

    // Mark full redraw needed
    self.compositor.invalidateAll();
    self.dirty = true;
}

/// Mark a rectangle as dirty and optionally auto-present.
fn markDirtyRect(self: *Terminal, rect: Rect) void {
    self.compositor.invalidateRect(rect) catch {
        // On allocation failure, fall back to full redraw
        self.compositor.invalidateAll();
    };
    self.dirty = true;
    self.maybeAutoPresent();
}

/// Present if auto-present is enabled.
/// Note: Errors are logged but not propagated to avoid breaking the drawing API.
/// Use explicit present() calls if error handling is needed.
fn maybeAutoPresent(self: *Terminal) void {
    if (self.auto_present and self.dirty) {
        self.present() catch |err| {
            // Log error but don't propagate - auto-present is best-effort
            std.log.warn("Terminal auto-present failed: {}", .{err});
        };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Terminal struct size" {
    // Basic sanity check that struct compiles
    try std.testing.expect(@sizeOf(Terminal) > 0);
}

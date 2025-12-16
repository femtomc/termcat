//! Windows console backend for termcat
//!
//! Provides terminal I/O using Windows Console API with Virtual Terminal support.
//! Works on Windows 10 version 1511+ with VT sequences for colors/attributes.
//!
//! ## Behavioral differences from POSIX backend:
//! - Mouse coordinates are 0-based (same as POSIX after conversion)
//! - No SIGWINCH - resize is detected via console input events
//! - Focus events require explicit console mode flag
//! - Bracketed paste not natively supported (capabilities.bracketed_paste = false)
//!
//! ## Known limitations:
//! - Key repeat count (wRepeatCount) is not fully honored; applications should
//!   poll frequently to avoid missing repeated keystrokes
//! - Console code page is set to UTF-8 on init and restored on cleanup

const std = @import("std");
const windows = std.os.windows;
const Event = @import("../Event.zig");
const Size = Event.Size;
const Cell = @import("../Cell.zig");

/// Color depth capability levels (re-exported from Cell.zig)
pub const ColorDepth = Cell.ColorDepth;

/// Terminal capabilities detected at init
pub const Capabilities = struct {
    /// Detected color depth
    color_depth: ColorDepth,
    /// Whether the terminal supports mouse input
    mouse: bool,
    /// Whether the terminal supports bracketed paste
    bracketed_paste: bool,
    /// Whether the terminal supports focus events
    focus_events: bool,
};

/// Configuration options for terminal initialization
pub const InitOptions = struct {
    /// Enable mouse input
    enable_mouse: bool = true,
    /// Enable focus event reporting
    enable_focus_events: bool = true,
};

/// Windows console backend
pub const WindowsBackend = struct {
    /// Handle to the console input buffer
    stdin_handle: windows.HANDLE,
    /// Handle to the console screen buffer
    stdout_handle: windows.HANDLE,
    /// Original console input mode (for restoration)
    orig_input_mode: windows.DWORD,
    /// Original console output mode (for restoration)
    orig_output_mode: windows.DWORD,
    /// Original console output code page (for restoration)
    orig_output_cp: windows.UINT,
    /// Current terminal size
    size: Size,
    /// Detected capabilities
    capabilities: Capabilities,
    /// Configuration options used during init
    options: InitOptions,
    /// Whether terminal is currently in raw mode
    in_raw_mode: bool,
    /// Allocator used for output buffer
    allocator: std.mem.Allocator,
    /// Output buffer for batching writes
    output_buffer: std.ArrayList(u8),
    /// Pending high surrogate for UTF-16 decoding
    pending_high_surrogate: ?u16,

    const Self = @This();

    // Windows console mode flags
    const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
    const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
    const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;

    const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
    const ENABLE_QUICK_EDIT_MODE: windows.DWORD = 0x0040;

    const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
    const ENABLE_WRAP_AT_EOL_OUTPUT: windows.DWORD = 0x0002;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
    const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

    /// UTF-8 code page
    const CP_UTF8: windows.UINT = 65001;

    /// Console input event types
    const KEY_EVENT: windows.WORD = 0x0001;
    const MOUSE_EVENT: windows.WORD = 0x0002;
    const WINDOW_BUFFER_SIZE_EVENT: windows.WORD = 0x0004;
    const FOCUS_EVENT: windows.WORD = 0x0010;

    /// Initialize the Windows backend
    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Self {
        // Get console handles
        const stdin_handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch {
            return error.NotATerminal;
        };
        const stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch {
            return error.NotATerminal;
        };

        // Get original console modes for restoration
        var orig_input_mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(stdin_handle, &orig_input_mode) == 0) {
            return error.NotATerminal;
        }

        var orig_output_mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(stdout_handle, &orig_output_mode) == 0) {
            return error.NotATerminal;
        }

        // Save original code page for restoration
        const orig_output_cp = GetConsoleOutputCP();

        // Detect terminal size
        const size = try getConsoleSize(stdout_handle);

        // Detect capabilities
        const capabilities = detectCapabilities();

        var self = Self{
            .stdin_handle = stdin_handle,
            .stdout_handle = stdout_handle,
            .orig_input_mode = orig_input_mode,
            .orig_output_mode = orig_output_mode,
            .orig_output_cp = orig_output_cp,
            .size = size,
            .capabilities = capabilities,
            .options = options,
            .in_raw_mode = false,
            .allocator = allocator,
            .output_buffer = .empty,
            .pending_high_surrogate = null,
        };

        errdefer self.output_buffer.deinit(allocator);

        // Enter raw mode and set up terminal
        try self.enterRawMode();

        // If enterRawMode succeeds but subsequent operations fail,
        // we need to clean up the terminal state
        errdefer self.forceCleanup();

        return self;
    }

    /// Force cleanup of terminal state (used on error paths)
    fn forceCleanup(self: *Self) void {
        // Try to restore terminal even on error - ignore any errors
        self.writeCleanupSequencesIgnoreErrors();
        _ = windows.kernel32.SetConsoleMode(self.stdin_handle, self.orig_input_mode);
        _ = windows.kernel32.SetConsoleMode(self.stdout_handle, self.orig_output_mode);
        _ = SetConsoleOutputCP(self.orig_output_cp);
        self.in_raw_mode = false;
    }

    /// Write cleanup sequences ignoring errors (for error path cleanup)
    fn writeCleanupSequencesIgnoreErrors(self: *Self) void {
        const cleanup_seq = "\x1b[?25h\x1b[0m\x1b[?1049l";
        var written: windows.DWORD = 0;
        _ = windows.kernel32.WriteConsoleA(
            self.stdout_handle,
            cleanup_seq.ptr,
            cleanup_seq.len,
            &written,
            null,
        );
    }

    /// Clean up and restore terminal state
    pub fn deinit(self: *Self) void {
        // Exit raw mode and restore terminal
        self.exitRawMode() catch {};

        // Free output buffer
        self.output_buffer.deinit(self.allocator);
    }

    /// Enter raw terminal mode
    fn enterRawMode(self: *Self) !void {
        if (self.in_raw_mode) return;

        // Set UTF-8 code page for proper Unicode output
        if (SetConsoleOutputCP(CP_UTF8) == 0) {
            return error.SetCodePageError;
        }

        // Set raw input mode:
        // - Disable line input (no waiting for Enter)
        // - Disable echo
        // - Disable processed input (Ctrl+C not handled by system)
        // - Enable window input (for resize events)
        // - Enable mouse input if requested
        // - Enable virtual terminal input for ANSI sequences
        // - ENABLE_EXTENDED_FLAGS allows us to disable Quick Edit mode
        var input_mode: windows.DWORD = ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS;

        if (self.options.enable_mouse and self.capabilities.mouse) {
            // Enable mouse input and disable Quick Edit mode
            // Quick Edit mode must be disabled for mouse events to be delivered
            input_mode |= ENABLE_MOUSE_INPUT;
            // Note: We don't set ENABLE_QUICK_EDIT_MODE, which disables it
            // when ENABLE_EXTENDED_FLAGS is set
        }

        if (windows.kernel32.SetConsoleMode(self.stdin_handle, input_mode) == 0) {
            // Restore code page on failure
            _ = SetConsoleOutputCP(self.orig_output_cp);
            return error.SetConsoleModeError;
        }

        // Set output mode:
        // - Enable virtual terminal processing for ANSI sequences
        // - Disable auto-return after newline
        var output_mode: windows.DWORD = self.orig_output_mode;
        output_mode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        output_mode |= DISABLE_NEWLINE_AUTO_RETURN;

        if (windows.kernel32.SetConsoleMode(self.stdout_handle, output_mode) == 0) {
            // Restore input mode and code page on failure
            _ = windows.kernel32.SetConsoleMode(self.stdin_handle, self.orig_input_mode);
            _ = SetConsoleOutputCP(self.orig_output_cp);
            return error.SetConsoleModeError;
        }

        self.in_raw_mode = true;

        // Now write initialization sequences
        try self.writeInitSequences();
    }

    /// Exit raw mode and restore terminal
    fn exitRawMode(self: *Self) !void {
        if (!self.in_raw_mode) return;

        // Flush any pending output
        try self.flushOutput();

        // Write cleanup sequences
        try self.writeCleanupSequences();

        // Restore original console modes
        if (windows.kernel32.SetConsoleMode(self.stdin_handle, self.orig_input_mode) == 0) {
            return error.SetConsoleModeError;
        }
        if (windows.kernel32.SetConsoleMode(self.stdout_handle, self.orig_output_mode) == 0) {
            return error.SetConsoleModeError;
        }

        // Restore original code page
        if (SetConsoleOutputCP(self.orig_output_cp) == 0) {
            return error.SetCodePageError;
        }

        self.in_raw_mode = false;
    }

    /// Write terminal initialization escape sequences
    fn writeInitSequences(self: *Self) !void {
        const w = self.output_buffer.writer(self.allocator);

        // Enter alternate screen buffer
        try w.writeAll("\x1b[?1049h");

        // Hide cursor
        try w.writeAll("\x1b[?25l");

        // Clear screen and move to home
        try w.writeAll("\x1b[2J\x1b[H");

        try self.flushOutput();
    }

    /// Write terminal cleanup escape sequences
    fn writeCleanupSequences(self: *Self) !void {
        const w = self.output_buffer.writer(self.allocator);

        // Show cursor
        try w.writeAll("\x1b[?25h");

        // Reset attributes
        try w.writeAll("\x1b[0m");

        // Exit alternate screen buffer
        try w.writeAll("\x1b[?1049l");

        try self.flushOutput();
    }

    /// Flush the output buffer to the terminal
    pub fn flushOutput(self: *Self) !void {
        if (self.output_buffer.items.len == 0) return;

        var written: windows.DWORD = 0;
        const result = windows.kernel32.WriteConsoleA(
            self.stdout_handle,
            self.output_buffer.items.ptr,
            @intCast(self.output_buffer.items.len),
            &written,
            null,
        );

        if (result == 0) {
            return error.WriteError;
        }

        if (written != self.output_buffer.items.len) {
            return error.PartialWrite;
        }
        self.output_buffer.clearRetainingCapacity();
    }

    /// Write data to the output buffer
    pub fn write(self: *Self, data: []const u8) !void {
        try self.output_buffer.appendSlice(self.allocator, data);
    }

    /// Get a writer for the output buffer
    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.output_buffer.writer(self.allocator);
    }

    /// Update the terminal size (called after resize)
    pub fn updateSize(self: *Self) !Size {
        self.size = try getConsoleSize(self.stdout_handle);
        return self.size;
    }

    /// Get the current terminal size
    pub fn getSize(self: *Self) Size {
        return self.size;
    }

    /// Get console size from screen buffer info
    fn getConsoleSize(handle: windows.HANDLE) !Size {
        var csbi: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(handle, &csbi) == 0) {
            return error.GetConsoleSizeError;
        }

        const width: u16 = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1);
        const height: u16 = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);

        if (width == 0 or height == 0) {
            return Size{ .width = 80, .height = 24 };
        }

        return Size{ .width = width, .height = height };
    }

    /// Poll for input with optional timeout (in milliseconds)
    /// Returns number of events available, or 0 on timeout
    pub fn poll(self: *Self, timeout_ms: ?u32) !usize {
        const timeout: windows.DWORD = timeout_ms orelse windows.INFINITE;

        const wait_result = windows.kernel32.WaitForSingleObject(self.stdin_handle, timeout);

        return switch (wait_result) {
            windows.WAIT_OBJECT_0 => blk: {
                var num_events: windows.DWORD = 0;
                if (GetNumberOfConsoleInputEvents(self.stdin_handle, &num_events) == 0) {
                    break :blk error.ConsoleError;
                }
                break :blk @intCast(num_events);
            },
            windows.WAIT_TIMEOUT => 0,
            else => error.WaitError,
        };
    }

    /// Poll for an event with optional timeout (in milliseconds).
    /// Returns null on timeout.
    pub fn pollEvent(self: *Self, timeout_ms: ?u32) !?Event.Event {
        const start_time = std.time.milliTimestamp();

        while (true) {
            // Calculate remaining timeout
            const elapsed: i64 = std.time.milliTimestamp() - start_time;
            const remaining_ms: ?u32 = if (timeout_ms) |ms| blk: {
                if (elapsed >= ms) break :blk 0;
                break :blk @intCast(ms - @as(u32, @intCast(@max(0, elapsed))));
            } else null;

            // Check for available events
            const events_available = try self.poll(remaining_ms);

            if (events_available > 0) {
                // Read one event
                if (try self.readEvent()) |event| {
                    return event;
                }
                // Event was filtered (e.g., key up), try again
                continue;
            }

            // Timeout
            if (timeout_ms) |ms| {
                if (elapsed >= ms) {
                    return null;
                }
            }
        }
    }

    /// Non-blocking event check (equivalent to pollEvent(0))
    pub fn peekEvent(self: *Self) !?Event.Event {
        return self.pollEvent(0);
    }

    /// Read a single console input event
    fn readEvent(self: *Self) !?Event.Event {
        var input_record: INPUT_RECORD = undefined;
        var events_read: windows.DWORD = 0;

        if (ReadConsoleInputW(self.stdin_handle, &input_record, 1, &events_read) == 0) {
            return error.ReadError;
        }

        if (events_read == 0) {
            return null;
        }

        return self.translateEvent(&input_record);
    }

    /// Translate a Windows console event to our Event type
    fn translateEvent(self: *Self, record: *const INPUT_RECORD) ?Event.Event {
        return switch (record.EventType) {
            KEY_EVENT => self.translateKeyEvent(&record.Event.KeyEvent),
            MOUSE_EVENT => translateMouseEvent(&record.Event.MouseEvent),
            WINDOW_BUFFER_SIZE_EVENT => blk: {
                // Update our cached size
                self.size = .{
                    .width = @intCast(record.Event.WindowBufferSizeEvent.dwSize.X),
                    .height = @intCast(record.Event.WindowBufferSizeEvent.dwSize.Y),
                };
                break :blk .{ .resize = self.size };
            },
            FOCUS_EVENT => blk: {
                if (!self.options.enable_focus_events) break :blk null;
                break :blk .{ .focus = record.Event.FocusEvent.bSetFocus != 0 };
            },
            else => null,
        };
    }

    /// Translate a Windows key event to our Key type.
    ///
    /// Note: wRepeatCount is not fully honored. When keys are held, Windows may
    /// coalesce multiple key presses into a single event with repeatCount > 1.
    /// This implementation emits one event per INPUT_RECORD. Applications that
    /// need precise repeat handling should poll frequently.
    fn translateKeyEvent(self: *Self, key: *const KEY_EVENT_RECORD) ?Event.Event {
        // Only process key down events
        if (key.bKeyDown == 0) return null;

        const control_state = key.dwControlKeyState;
        const mods = Event.Modifiers{
            .ctrl = (control_state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0,
            .alt = (control_state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0,
            .shift = (control_state & SHIFT_PRESSED) != 0,
        };

        // Check for special keys first
        if (translateVirtualKey(key.wVirtualKeyCode, mods)) |event_key| {
            return .{ .key = event_key };
        }

        // Regular character - handle UTF-16 surrogate pairs
        const char = key.uChar.UnicodeChar;
        if (char != 0) {
            // Check for UTF-16 surrogate pairs (used for characters outside BMP, like emoji)
            if (char >= 0xD800 and char <= 0xDBFF) {
                // High surrogate - save it and wait for low surrogate
                self.pending_high_surrogate = char;
                return null;
            }

            var codepoint: u21 = undefined;

            if (char >= 0xDC00 and char <= 0xDFFF) {
                // Low surrogate - combine with pending high surrogate
                if (self.pending_high_surrogate) |high| {
                    // Decode surrogate pair: ((high - 0xD800) << 10) + (low - 0xDC00) + 0x10000
                    const high_val: u21 = @as(u21, high) - 0xD800;
                    const low_val: u21 = @as(u21, char) - 0xDC00;
                    codepoint = (high_val << 10) + low_val + 0x10000;
                    self.pending_high_surrogate = null;
                } else {
                    // Orphan low surrogate - invalid, skip it
                    return null;
                }
            } else {
                // Regular BMP character
                // Clear any pending high surrogate (orphaned)
                self.pending_high_surrogate = null;
                codepoint = @intCast(char);
            }

            // Handle Ctrl+letter canonicalization
            // Windows gives us the control code (1-26), we convert to letter + ctrl mod
            if (codepoint >= 1 and codepoint <= 26 and mods.ctrl) {
                return .{
                    .key = Event.Key.fromCodepoint(codepoint + 'a' - 1, mods),
                };
            }

            return .{ .key = Event.Key.fromCodepoint(codepoint, mods) };
        }

        return null;
    }

    /// Translate Windows virtual key code to our special key
    fn translateVirtualKey(vk: windows.WORD, mods: Event.Modifiers) ?Event.Key {
        const special: ?Event.Key.Special = switch (vk) {
            VK_ESCAPE => .escape,
            VK_RETURN => .enter,
            VK_TAB => .tab,
            VK_BACK => .backspace,
            VK_DELETE => .delete,
            VK_INSERT => .insert,
            VK_HOME => .home,
            VK_END => .end,
            VK_PRIOR => .page_up,
            VK_NEXT => .page_down,
            VK_UP => .up,
            VK_DOWN => .down,
            VK_LEFT => .left,
            VK_RIGHT => .right,
            VK_F1 => .f1,
            VK_F2 => .f2,
            VK_F3 => .f3,
            VK_F4 => .f4,
            VK_F5 => .f5,
            VK_F6 => .f6,
            VK_F7 => .f7,
            VK_F8 => .f8,
            VK_F9 => .f9,
            VK_F10 => .f10,
            VK_F11 => .f11,
            VK_F12 => .f12,
            else => null,
        };

        if (special) |sp| {
            return Event.Key.fromSpecial(sp, mods);
        }
        return null;
    }

    /// Translate Windows mouse event to our Mouse type
    fn translateMouseEvent(mouse: *const MOUSE_EVENT_RECORD) ?Event.Event {
        const x: u16 = @intCast(mouse.dwMousePosition.X);
        const y: u16 = @intCast(mouse.dwMousePosition.Y);

        const control_state = mouse.dwControlKeyState;
        const mods = Event.Modifiers{
            .ctrl = (control_state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0,
            .alt = (control_state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0,
            .shift = (control_state & SHIFT_PRESSED) != 0,
        };

        const button: Event.Mouse.Button = blk: {
            const flags = mouse.dwEventFlags;
            const buttons = mouse.dwButtonState;

            if (flags & MOUSE_WHEELED != 0) {
                // High word of dwButtonState contains wheel delta
                const delta: i16 = @bitCast(@as(u16, @truncate(buttons >> 16)));
                break :blk if (delta > 0) .wheel_up else .wheel_down;
            }

            if (flags & MOUSE_MOVED != 0 and buttons == 0) {
                break :blk .move;
            }

            // Check button state
            if (buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0) {
                break :blk .left;
            } else if (buttons & RIGHTMOST_BUTTON_PRESSED != 0) {
                break :blk .right;
            } else if (buttons & FROM_LEFT_2ND_BUTTON_PRESSED != 0) {
                break :blk .middle;
            }

            // No buttons pressed - release or move
            if (flags & MOUSE_MOVED != 0) {
                break :blk .move;
            }
            break :blk .release;
        };

        return .{
            .mouse = .{
                .x = x,
                .y = y,
                .button = button,
                .mods = mods,
            },
        };
    }

    /// Check and clear the resize pending flag (Windows doesn't use signals)
    pub fn checkResizePending(self: *Self) bool {
        _ = self;
        // Windows uses console input events for resize, not signals
        return false;
    }

    /// Notify that a resize occurred (for API compatibility)
    pub fn notifyResize(self: *Self) void {
        _ = self;
        // No-op on Windows - resize comes via console events
    }
};

/// Detect terminal capabilities
pub fn detectCapabilities() Capabilities {
    // Windows 10 version 1511+ supports VT sequences
    // For now, assume true color support if VT mode is available
    return Capabilities{
        .color_depth = .true_color,
        .mouse = true,
        .bracketed_paste = false, // Not natively supported
        .focus_events = true,
    };
}

// Windows console API types and functions
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const COORD = extern struct {
    X: windows.SHORT,
    Y: windows.SHORT,
};

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    _padding: windows.WORD = 0,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
    },
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: extern union {
        UnicodeChar: windows.WCHAR,
        AsciiChar: windows.CHAR,
    },
    dwControlKeyState: windows.DWORD,
};

const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: COORD,
    dwButtonState: windows.DWORD,
    dwControlKeyState: windows.DWORD,
    dwEventFlags: windows.DWORD,
};

const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: COORD,
};

const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: windows.BOOL,
};

const MENU_EVENT_RECORD = extern struct {
    dwCommandId: windows.UINT,
};

// Virtual key codes
const VK_BACK: windows.WORD = 0x08;
const VK_TAB: windows.WORD = 0x09;
const VK_RETURN: windows.WORD = 0x0D;
const VK_ESCAPE: windows.WORD = 0x1B;
const VK_PRIOR: windows.WORD = 0x21;
const VK_NEXT: windows.WORD = 0x22;
const VK_END: windows.WORD = 0x23;
const VK_HOME: windows.WORD = 0x24;
const VK_LEFT: windows.WORD = 0x25;
const VK_UP: windows.WORD = 0x26;
const VK_RIGHT: windows.WORD = 0x27;
const VK_DOWN: windows.WORD = 0x28;
const VK_INSERT: windows.WORD = 0x2D;
const VK_DELETE: windows.WORD = 0x2E;
const VK_F1: windows.WORD = 0x70;
const VK_F2: windows.WORD = 0x71;
const VK_F3: windows.WORD = 0x72;
const VK_F4: windows.WORD = 0x73;
const VK_F5: windows.WORD = 0x74;
const VK_F6: windows.WORD = 0x75;
const VK_F7: windows.WORD = 0x76;
const VK_F8: windows.WORD = 0x77;
const VK_F9: windows.WORD = 0x78;
const VK_F10: windows.WORD = 0x79;
const VK_F11: windows.WORD = 0x7A;
const VK_F12: windows.WORD = 0x7B;

// Control key state flags
const RIGHT_ALT_PRESSED: windows.DWORD = 0x0001;
const LEFT_ALT_PRESSED: windows.DWORD = 0x0002;
const RIGHT_CTRL_PRESSED: windows.DWORD = 0x0004;
const LEFT_CTRL_PRESSED: windows.DWORD = 0x0008;
const SHIFT_PRESSED: windows.DWORD = 0x0010;

// Mouse event flags
const MOUSE_MOVED: windows.DWORD = 0x0001;
const MOUSE_WHEELED: windows.DWORD = 0x0004;

// Mouse button state
const FROM_LEFT_1ST_BUTTON_PRESSED: windows.DWORD = 0x0001;
const RIGHTMOST_BUTTON_PRESSED: windows.DWORD = 0x0002;
const FROM_LEFT_2ND_BUTTON_PRESSED: windows.DWORD = 0x0004;

// External Windows API functions
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: windows.HANDLE,
    lpcNumberOfEvents: *windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: *INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn GetConsoleOutputCP() callconv(windows.WINAPI) windows.UINT;

extern "kernel32" fn SetConsoleOutputCP(
    wCodePageID: windows.UINT,
) callconv(windows.WINAPI) windows.BOOL;

// Tests (only run on Windows)
test "detectCapabilities" {
    const caps = detectCapabilities();
    try std.testing.expect(@intFromEnum(caps.color_depth) >= 0);
}

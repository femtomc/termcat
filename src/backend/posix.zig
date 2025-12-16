const std = @import("std");
const posix = std.posix;
const Event = @import("../Event.zig");
const Size = Event.Size;
const Input = @import("../input/Input.zig");
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
    /// Install SIGWINCH handler for resize detection
    install_sigwinch: bool = true,
    /// Enable mouse input
    enable_mouse: bool = true,
    /// Enable bracketed paste mode
    enable_bracketed_paste: bool = true,
    /// Enable focus event reporting
    enable_focus_events: bool = true,
};

/// POSIX terminal backend
pub const PosixBackend = struct {
    /// File descriptor for the terminal
    tty_fd: posix.fd_t,
    /// Whether we own the fd (and should close it on deinit)
    owns_fd: bool,
    /// Original terminal attributes (for restoration)
    orig_termios: posix.termios,
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
    /// Previous SIGWINCH handler (stored per instance for safe restoration)
    prev_sigaction: ?posix.Sigaction,
    /// Input handler for decoding terminal input
    input_handler: Input,

    /// Atomic flag for SIGWINCH notification
    var resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    const Self = @This();

    /// Initialize the POSIX backend
    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Self {
        // Try to open /dev/tty first for direct terminal access
        const tty_fd = posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch |err| switch (err) {
            error.FileNotFound, error.NoDevice => blk: {
                // Fall back to stdin if /dev/tty not available
                if (posix.isatty(posix.STDIN_FILENO)) {
                    break :blk posix.STDIN_FILENO;
                }
                return error.NotATerminal;
            },
            else => return err,
        };
        const owns_fd = tty_fd != posix.STDIN_FILENO;
        errdefer if (owns_fd) posix.close(tty_fd);

        // Get original terminal attributes
        const orig_termios = try posix.tcgetattr(tty_fd);

        // Detect terminal size
        const size = try getTerminalSize(tty_fd);

        // Detect capabilities
        const capabilities = detectCapabilities();

        var self = Self{
            .tty_fd = tty_fd,
            .owns_fd = owns_fd,
            .orig_termios = orig_termios,
            .size = size,
            .capabilities = capabilities,
            .options = options,
            .in_raw_mode = false,
            .allocator = allocator,
            .output_buffer = .empty,
            .prev_sigaction = null,
            .input_handler = Input.init(allocator, tty_fd),
        };

        errdefer self.output_buffer.deinit(allocator);
        errdefer self.input_handler.deinit();

        // Enter raw mode and set up terminal
        try self.enterRawMode();

        // If enterRawMode succeeds but subsequent operations fail,
        // we need to clean up the terminal state
        errdefer self.forceCleanup();

        // Install signal handler if requested
        if (options.install_sigwinch) {
            try self.installSigwinchHandler();
        }

        return self;
    }

    /// Force cleanup of terminal state (used on error paths)
    fn forceCleanup(self: *Self) void {
        // Try to restore terminal even on error - ignore any errors
        self.writeCleanupSequencesIgnoreErrors();
        posix.tcsetattr(self.tty_fd, .FLUSH, self.orig_termios) catch {};
        self.in_raw_mode = false;
    }

    /// Write cleanup sequences ignoring errors (for error path cleanup)
    fn writeCleanupSequencesIgnoreErrors(self: *Self) void {
        const cleanup_seq = "\x1b[?1004l\x1b[?2004l\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[0m\x1b[?1049l";
        _ = posix.write(self.tty_fd, cleanup_seq) catch {};
    }

    /// Clean up and restore terminal state
    pub fn deinit(self: *Self) void {
        // Restore signal handler if we installed one
        if (self.options.install_sigwinch) {
            self.restoreSigwinchHandler();
        }

        // Exit raw mode and restore terminal
        self.exitRawMode() catch {};

        // Free input handler
        self.input_handler.deinit();

        // Free output buffer
        self.output_buffer.deinit(self.allocator);

        // Close fd if we own it
        if (self.owns_fd) {
            posix.close(self.tty_fd);
        }
    }

    /// Enter raw terminal mode
    fn enterRawMode(self: *Self) !void {
        if (self.in_raw_mode) return;

        // Set raw mode termios FIRST (before writing sequences)
        // This ensures we don't leave the terminal in a mutated state on error
        var raw = self.orig_termios;

        // Input flags: disable break processing, CR-to-NL, parity check, strip 8th bit, flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output flags: disable post-processing
        raw.oflag.OPOST = false;

        // Control flags: set 8-bit chars, disable parity
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false; // Disable parity
        raw.cflag.CSTOPB = false; // Single stop bit (not 2)

        // Local flags: disable echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control chars: minimum 0 bytes, no timeout
        // Note: This makes read non-blocking - callers should use poll() first
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.tty_fd, .FLUSH, raw);
        self.in_raw_mode = true;

        // Now write initialization sequences
        // If this fails, we have errdefer in init to clean up
        try self.writeInitSequences();
    }

    /// Exit raw mode and restore terminal
    fn exitRawMode(self: *Self) !void {
        if (!self.in_raw_mode) return;

        // Flush any pending output
        try self.flushOutput();

        // Write cleanup sequences
        try self.writeCleanupSequences();

        // Restore original terminal attributes
        try posix.tcsetattr(self.tty_fd, .FLUSH, self.orig_termios);
        self.in_raw_mode = false;
    }

    /// Write terminal initialization escape sequences
    fn writeInitSequences(self: *Self) !void {
        const w = self.output_buffer.writer(self.allocator);

        // Enter alternate screen buffer
        try w.writeAll("\x1b[?1049h");

        // Hide cursor
        try w.writeAll("\x1b[?25l");

        // Enable mouse if requested and supported
        if (self.options.enable_mouse and self.capabilities.mouse) {
            // Enable SGR mouse mode (most compatible modern mode)
            try w.writeAll("\x1b[?1006h"); // SGR extended mouse mode
            try w.writeAll("\x1b[?1003h"); // All motion tracking
        }

        // Enable bracketed paste if requested and supported
        if (self.options.enable_bracketed_paste and self.capabilities.bracketed_paste) {
            try w.writeAll("\x1b[?2004h");
        }

        // Enable focus events if requested and supported
        if (self.options.enable_focus_events and self.capabilities.focus_events) {
            try w.writeAll("\x1b[?1004h");
        }

        // Clear screen and move to home
        try w.writeAll("\x1b[2J\x1b[H");

        try self.flushOutput();
    }

    /// Write terminal cleanup escape sequences
    fn writeCleanupSequences(self: *Self) !void {
        const w = self.output_buffer.writer(self.allocator);

        // Disable focus events
        if (self.options.enable_focus_events and self.capabilities.focus_events) {
            try w.writeAll("\x1b[?1004l");
        }

        // Disable bracketed paste
        if (self.options.enable_bracketed_paste and self.capabilities.bracketed_paste) {
            try w.writeAll("\x1b[?2004l");
        }

        // Disable mouse
        if (self.options.enable_mouse and self.capabilities.mouse) {
            try w.writeAll("\x1b[?1003l");
            try w.writeAll("\x1b[?1006l");
        }

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

        const written = try posix.write(self.tty_fd, self.output_buffer.items);
        if (written != self.output_buffer.items.len) {
            return error.PartialWrite;
        }
        self.output_buffer.clearRetainingCapacity();
    }

    /// Write data to the output buffer
    pub fn write(self: *Self, data: []const u8) !void {
        try self.output_buffer.appendSlice(data);
    }

    /// Get a writer for the output buffer
    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.output_buffer.writer(self.allocator);
    }

    /// Install SIGWINCH handler
    fn installSigwinchHandler(self: *Self) !void {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = sigwinchHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };

        var old_sa: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.WINCH, &sa, &old_sa);

        // Store full previous sigaction for proper restoration
        self.prev_sigaction = old_sa;
    }

    /// Restore previous SIGWINCH handler
    fn restoreSigwinchHandler(self: *Self) void {
        if (self.prev_sigaction) |old_sa| {
            // Restore the full original sigaction (handler, mask, and flags)
            var sa = old_sa;
            posix.sigaction(posix.SIG.WINCH, &sa, null);
            self.prev_sigaction = null;
        }
    }

    /// SIGWINCH signal handler
    fn sigwinchHandler(_: c_int) callconv(.c) void {
        resize_pending.store(true, .release);
    }

    /// Notify that a resize occurred (for external signal handling)
    pub fn notifyResize(self: *Self) void {
        _ = self;
        resize_pending.store(true, .release);
    }

    /// Check and clear the resize pending flag
    pub fn checkResizePending(self: *Self) bool {
        _ = self;
        return resize_pending.swap(false, .acquire);
    }

    /// Update the terminal size (called after resize)
    pub fn updateSize(self: *Self) !Size {
        self.size = try getTerminalSize(self.tty_fd);
        return self.size;
    }

    /// Get the current terminal size
    pub fn getSize(self: *Self) Size {
        return self.size;
    }

    /// Get terminal size via ioctl
    fn getTerminalSize(fd: posix.fd_t) !Size {
        var ws: posix.winsize = undefined;

        if (posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        if (ws.col == 0 or ws.row == 0) {
            // Fallback to reasonable defaults
            return Size{ .width = 80, .height = 24 };
        }

        return Size{
            .width = ws.col,
            .height = ws.row,
        };
    }

    /// Poll for input with optional timeout (in milliseconds)
    /// Returns number of bytes available to read, or 0 on timeout
    /// Note: Always call poll() before read() to avoid busy-looping
    pub fn poll(self: *Self, timeout_ms: ?u32) !usize {
        var fds = [_]posix.pollfd{
            .{
                .fd = self.tty_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;
        const result = try posix.poll(&fds, timeout);

        if (result > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
            return 1; // Data available
        }
        return 0; // Timeout or no data
    }

    /// Read available input bytes
    /// Note: This function is non-blocking. Always call poll() first to check
    /// for available data, otherwise you may get 0 bytes.
    pub fn read(self: *Self, buf: []u8) !usize {
        return posix.read(self.tty_fd, buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    /// Poll for an event with optional timeout (in milliseconds).
    /// Returns null on timeout.
    ///
    /// This handles:
    /// - SIGWINCH resize detection (returns resize event)
    /// - Input decoding (keys, mouse, paste, focus)
    /// - Escape sequence timeout for ambiguous sequences
    ///
    /// Event data lifetime: For paste events, the slice data is only valid
    /// until the next call to pollEvent/peekEvent.
    pub fn pollEvent(self: *Self, timeout_ms: ?u32) !?Event.Event {
        // Check for pending resize first
        if (self.checkResizePending()) {
            self.size = try getTerminalSize(self.tty_fd);
            return .{ .resize = self.size };
        }

        // Poll for input events
        return self.input_handler.pollEvent(timeout_ms);
    }

    /// Non-blocking event check (equivalent to pollEvent(0))
    pub fn peekEvent(self: *Self) !?Event.Event {
        return self.pollEvent(0);
    }
};

/// Detect terminal capabilities from environment
pub fn detectCapabilities() Capabilities {
    const term = std.posix.getenv("TERM") orelse "";
    const colorterm = std.posix.getenv("COLORTERM") orelse "";

    // Detect color depth
    const color_depth = detectColorDepth(term, colorterm);

    // Check if terminal is known to support advanced features
    // Default to conservative (false) for unknown terminals
    const is_modern = isModernTerminal(term);

    return Capabilities{
        .color_depth = color_depth,
        .mouse = is_modern,
        .bracketed_paste = is_modern,
        .focus_events = is_modern,
    };
}

/// Detect color depth from environment variables
fn detectColorDepth(term: []const u8, colorterm: []const u8) ColorDepth {
    // Check COLORTERM first (most reliable for true color)
    if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
        return .true_color;
    }

    // Check TERM for hints
    if (std.mem.indexOf(u8, term, "mono") != null) {
        return .mono;
    }

    if (std.mem.indexOf(u8, term, "256color") != null or
        std.mem.indexOf(u8, term, "256") != null)
    {
        return .color_256;
    }

    // Check for known true-color terminals
    if (std.mem.indexOf(u8, term, "kitty") != null or
        std.mem.indexOf(u8, term, "alacritty") != null or
        std.mem.indexOf(u8, term, "iterm2") != null or
        std.mem.indexOf(u8, term, "wezterm") != null or
        std.mem.indexOf(u8, term, "foot") != null)
    {
        return .true_color;
    }

    // Default to basic 8 colors for unknown terminals
    return .basic;
}

/// Check if the terminal is a known modern terminal emulator
/// Returns false for unknown terminals (conservative default)
fn isModernTerminal(term: []const u8) bool {
    if (term.len == 0) return false;

    // Known modern terminals that support mouse, bracketed paste, and focus events
    const modern_terms = [_][]const u8{
        "xterm",
        "rxvt",
        "screen",
        "tmux",
        "kitty",
        "alacritty",
        "iterm2",
        "wezterm",
        "foot",
        "vte",
        "gnome",
        "konsole",
        "ghostty",
    };

    for (modern_terms) |modern| {
        if (std.mem.indexOf(u8, term, modern) != null) {
            return true;
        }
    }

    // Default to false for unknown terminals (conservative approach)
    // This prevents emitting escape sequences on legacy terminals like vt100, dumb, etc.
    return false;
}

test "detectColorDepth with truecolor" {
    const depth = detectColorDepth("xterm-256color", "truecolor");
    try std.testing.expectEqual(ColorDepth.true_color, depth);
}

test "detectColorDepth with 24bit" {
    const depth = detectColorDepth("xterm", "24bit");
    try std.testing.expectEqual(ColorDepth.true_color, depth);
}

test "detectColorDepth with 256color term" {
    const depth = detectColorDepth("xterm-256color", "");
    try std.testing.expectEqual(ColorDepth.color_256, depth);
}

test "detectColorDepth with mono" {
    const depth = detectColorDepth("vt100-mono", "");
    try std.testing.expectEqual(ColorDepth.mono, depth);
}

test "detectColorDepth with kitty" {
    const depth = detectColorDepth("xterm-kitty", "");
    try std.testing.expectEqual(ColorDepth.true_color, depth);
}

test "detectColorDepth default" {
    const depth = detectColorDepth("vt100", "");
    try std.testing.expectEqual(ColorDepth.basic, depth);
}

test "isModernTerminal known terminals" {
    try std.testing.expect(isModernTerminal("xterm-256color"));
    try std.testing.expect(isModernTerminal("screen-256color"));
    try std.testing.expect(isModernTerminal("tmux-256color"));
    try std.testing.expect(isModernTerminal("kitty"));
    try std.testing.expect(isModernTerminal("xterm-ghostty"));
}

test "isModernTerminal unknown terminals" {
    // Unknown terminals should return false (conservative)
    try std.testing.expect(!isModernTerminal("vt100"));
    try std.testing.expect(!isModernTerminal("dumb"));
    try std.testing.expect(!isModernTerminal("linux"));
    try std.testing.expect(!isModernTerminal(""));
}

test "detectCapabilities" {
    const caps = detectCapabilities();
    // Just verify it returns something reasonable
    try std.testing.expect(@intFromEnum(caps.color_depth) >= 0);
}

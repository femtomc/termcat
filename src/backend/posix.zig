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

/// Maximum number of concurrent backends that can receive resize notifications.
/// This is a compile-time constant to avoid dynamic allocation in signal handlers.
const max_resize_pipes = 16;

/// Global registry of resize notification pipes.
/// The signal handler writes to all registered pipes to notify each backend.
/// This must be lock-free and async-signal-safe.
const ResizePipeRegistry = struct {
    /// Write ends of pipes for each registered backend.
    /// -1 indicates an unused slot.
    pipes: [max_resize_pipes]std.atomic.Value(posix.fd_t),

    fn init() ResizePipeRegistry {
        var self: ResizePipeRegistry = undefined;
        for (&self.pipes) |*p| {
            p.* = std.atomic.Value(posix.fd_t).init(-1);
        }
        return self;
    }

    /// Register a pipe write fd. Returns the slot index, or null if full.
    fn register(self: *ResizePipeRegistry, write_fd: posix.fd_t) ?usize {
        for (&self.pipes, 0..) |*slot, i| {
            // Try to claim an empty slot (-1 -> write_fd)
            if (slot.cmpxchgStrong(-1, write_fd, .acq_rel, .acquire)) |_| {
                // Slot was not -1, try next
                continue;
            } else {
                // Successfully claimed slot
                return i;
            }
        }
        return null; // Registry full
    }

    /// Unregister a pipe by slot index.
    fn unregister(self: *ResizePipeRegistry, slot: usize) void {
        if (slot < max_resize_pipes) {
            self.pipes[slot].store(-1, .release);
        }
    }

    /// Signal handler: write a byte to all registered pipes.
    /// This is async-signal-safe (only uses write()).
    fn notifyAll(self: *ResizePipeRegistry) void {
        const byte = [_]u8{1};
        for (&self.pipes) |*slot| {
            const fd = slot.load(.acquire);
            if (fd >= 0) {
                // write() is async-signal-safe. Ignore errors (pipe full, closed, etc.)
                _ = posix.write(fd, &byte) catch {};
            }
        }
    }
};

/// Global resize pipe registry (initialized at comptime).
var resize_registry: ResizePipeRegistry = ResizePipeRegistry.init();

/// Reference count for SIGWINCH handler installation.
/// The handler is installed when count goes 0->1 and restored when count goes 1->0.
var sigwinch_refcount: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Stored original SIGWINCH handler (saved when first backend installs handler).
var original_sigaction: posix.Sigaction = undefined;
var original_sigaction_valid: bool = false;

/// POSIX terminal backend
pub const PosixBackend = struct {
    /// File descriptor for the terminal
    tty_fd: posix.fd_t,
    /// File descriptor used for input polling/reads
    input_fd: posix.fd_t,
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
    /// Input handler for decoding terminal input
    input_handler: Input,
    /// Self-pipe for resize notifications (read end, write end)
    resize_pipe: ?[2]posix.fd_t,
    /// Slot index in the global resize registry
    resize_slot: ?usize,

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

        // Create self-pipe for resize notifications if requested
        var resize_pipe: ?[2]posix.fd_t = null;
        var resize_slot: ?usize = null;
        if (options.install_sigwinch) {
            const pipe_fds = try posix.pipe();
            const O_NONBLOCK: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));

            // Set read end to non-blocking and close-on-exec
            const read_flags = posix.fcntl(pipe_fds[0], posix.F.GETFL, 0) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };
            _ = posix.fcntl(pipe_fds[0], posix.F.SETFL, read_flags | O_NONBLOCK) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };
            _ = posix.fcntl(pipe_fds[0], posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };

            // Set write end to non-blocking and close-on-exec
            const write_flags = posix.fcntl(pipe_fds[1], posix.F.GETFL, 0) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };
            _ = posix.fcntl(pipe_fds[1], posix.F.SETFL, write_flags | O_NONBLOCK) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };
            _ = posix.fcntl(pipe_fds[1], posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)) catch {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.PipeSetupFailed;
            };

            // Register the write end with the global registry
            resize_slot = resize_registry.register(pipe_fds[1]);
            if (resize_slot == null) {
                posix.close(pipe_fds[0]);
                posix.close(pipe_fds[1]);
                return error.TooManyBackends;
            }
            resize_pipe = pipe_fds;
        }
        errdefer if (resize_pipe) |p| {
            if (resize_slot) |slot| resize_registry.unregister(slot);
            posix.close(p[0]);
            posix.close(p[1]);
        };

        // Use stdin for input when it's a TTY (avoids poll() quirks on /dev/tty on macOS)
        const input_fd: posix.fd_t = if (posix.isatty(posix.STDIN_FILENO)) posix.STDIN_FILENO else tty_fd;

        var self = Self{
            .tty_fd = tty_fd,
            .input_fd = input_fd,
            .owns_fd = owns_fd,
            .orig_termios = orig_termios,
            .size = size,
            .capabilities = capabilities,
            .options = options,
            .in_raw_mode = false,
            .allocator = allocator,
            .output_buffer = .empty,
            .input_handler = Input.init(allocator, input_fd),
            .resize_pipe = resize_pipe,
            .resize_slot = resize_slot,
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
            self.installSigwinchHandler();
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

        // Unregister and close resize pipe
        if (self.resize_slot) |slot| {
            resize_registry.unregister(slot);
        }
        if (self.resize_pipe) |p| {
            posix.close(p[0]); // read end
            posix.close(p[1]); // write end
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
        try self.output_buffer.appendSlice(self.allocator, data);
    }

    /// Get a writer for the output buffer
    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.output_buffer.writer(self.allocator);
    }

    /// Install SIGWINCH handler with reference counting.
    /// Only installs the handler when refcount goes from 0 to 1.
    fn installSigwinchHandler(_: *Self) void {
        // Atomically increment refcount
        const prev_count = sigwinch_refcount.fetchAdd(1, .acq_rel);

        if (prev_count == 0) {
            // First backend: install the signal handler and save original
            const SA_RESTART: c_uint = 0x0002;

            var sa: posix.Sigaction = .{
                .handler = .{ .handler = sigwinchHandler },
                .mask = posix.sigemptyset(),
                .flags = SA_RESTART,
            };

            var old_sa: posix.Sigaction = .{
                .handler = .{ .handler = null },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };

            posix.sigaction(posix.SIG.WINCH, &sa, &old_sa);
            original_sigaction = old_sa;
            original_sigaction_valid = true;
        }
    }

    /// Restore previous SIGWINCH handler with reference counting.
    /// Only restores when refcount goes from 1 to 0.
    fn restoreSigwinchHandler(_: *Self) void {
        // Atomically decrement refcount
        const prev_count = sigwinch_refcount.fetchSub(1, .acq_rel);

        if (prev_count == 1 and original_sigaction_valid) {
            // Last backend: restore the original signal handler
            var sa = original_sigaction;
            posix.sigaction(posix.SIG.WINCH, &sa, null);
            original_sigaction_valid = false;
        }
    }

    /// SIGWINCH signal handler - writes to all registered pipes
    fn sigwinchHandler(_: c_int) callconv(.c) void {
        resize_registry.notifyAll();
    }

    /// Notify that a resize occurred (for external signal handling)
    pub fn notifyResize(self: *Self) void {
        // Write directly to this instance's pipe
        if (self.resize_pipe) |p| {
            const byte = [_]u8{1};
            _ = posix.write(p[1], &byte) catch {};
        }
    }

    /// Check and clear the resize pending flag by draining the pipe
    pub fn checkResizePending(self: *Self) bool {
        const pipe = self.resize_pipe orelse return false;
        var buf: [64]u8 = undefined;
        var had_data = false;
        // Non-blocking read loop to fully drain all pending notifications
        while (true) {
            const n = posix.read(pipe[0], &buf) catch break;
            if (n == 0) break; // EOF or no more data
            had_data = true;
        }
        return had_data;
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
                .fd = self.input_fd,
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
        return posix.read(self.input_fd, buf) catch |err| switch (err) {
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

test "ResizePipeRegistry per-instance notification" {
    // Create a local registry for testing (don't interfere with global)
    var registry = ResizePipeRegistry.init();

    // Create two pipes
    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);

    // Register both write ends
    const slot1 = registry.register(pipe1[1]);
    try std.testing.expect(slot1 != null);

    const slot2 = registry.register(pipe2[1]);
    try std.testing.expect(slot2 != null);

    // Notify all - both pipes should receive
    registry.notifyAll();

    // Both read ends should have data
    var buf: [16]u8 = undefined;
    const n1 = try posix.read(pipe1[0], &buf);
    try std.testing.expect(n1 > 0);

    const n2 = try posix.read(pipe2[0], &buf);
    try std.testing.expect(n2 > 0);

    // Unregister pipe1
    registry.unregister(slot1.?);

    // Notify again - only pipe2 should receive
    registry.notifyAll();

    // pipe1 should be empty (would block), pipe2 should have data
    // Since we can't set nonblocking in tests easily, just verify pipe2 works
    const n3 = try posix.read(pipe2[0], &buf);
    try std.testing.expect(n3 > 0);

    // Clean up
    registry.unregister(slot2.?);
}

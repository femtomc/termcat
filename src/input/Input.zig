const std = @import("std");
const posix = std.posix;
const Event = @import("../Event.zig");
const Decoder = @import("decoder.zig");

/// High-level input handler.
/// Wraps the decoder with buffering and timeout handling for ambiguous sequences.
pub const Input = @This();

/// Optional input tracing for debugging.
///
/// Set `TERMCAT_TRACE_INPUT=stderr` (or `-`) to log to stderr, or set it to a
/// file path to write logs to that file (truncated each run).
const Trace = struct {
    const Sink = union(enum) {
        disabled,
        stderr,
        file: std.fs.File,
    };

    sink: Sink = .disabled,
    /// Write buffer for the writer API (required in Zig 0.15+)
    write_buf: [4096]u8 = undefined,

    pub fn init() Trace {
        const value = std.posix.getenv("TERMCAT_TRACE_INPUT") orelse return .{};

        if (std.mem.eql(u8, value, "stderr") or std.mem.eql(u8, value, "-")) {
            return .{ .sink = .stderr };
        }

        const file = std.fs.cwd().createFile(value, .{ .truncate = true }) catch return .{};
        return .{ .sink = .{ .file = file } };
    }

    pub fn deinit(self: *Trace) void {
        switch (self.sink) {
            .file => |f| {
                f.close();
            },
            else => {},
        }
        self.* = .{};
    }

    pub fn logBytes(self: *Trace, label: []const u8, bytes: []const u8) void {
        switch (self.sink) {
            .disabled => return,
            .stderr => {
                const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
                var w = stderr_file.writer(&self.write_buf);
                logBytesToWriter(&w.interface, label, bytes) catch {};
                w.interface.flush() catch {};
            },
            .file => |f| {
                var w = f.writer(&self.write_buf);
                logBytesToWriter(&w.interface, label, bytes) catch {};
                w.interface.flush() catch {};
            },
        }
    }

    pub fn logEvent(self: *Trace, event: Event.Event) void {
        switch (self.sink) {
            .disabled => return,
            .stderr => {
                const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
                var w = stderr_file.writer(&self.write_buf);
                logEventToWriter(&w.interface, event) catch {};
                w.interface.flush() catch {};
            },
            .file => |f| {
                var w = f.writer(&self.write_buf);
                logEventToWriter(&w.interface, event) catch {};
                w.interface.flush() catch {};
            },
        }
    }

    fn logBytesToWriter(w: *std.Io.Writer, label: []const u8, bytes: []const u8) !void {
        try w.print("[input] {s}: {d} bytes | hex:", .{ label, bytes.len });
        for (bytes) |b| {
            try w.print(" {x:0>2}", .{b});
        }

        try w.writeAll(" | ascii: ");
        for (bytes) |b| {
            const ch: u8 = if (b >= 0x20 and b < 0x7f) b else '.';
            try w.writeByte(ch);
        }
        try w.writeByte('\n');
    }

    fn logEventToWriter(w: *std.Io.Writer, event: Event.Event) !void {
        switch (event) {
            .key => |key| {
                if (key.codepoint) |cp| {
                    if (cp < 0x80 and cp >= 0x20) {
                        try w.print("[event] key cp='{c}' ({d}) mods=ctrl:{d} alt:{d} shift:{d}\n", .{
                            @as(u8, @intCast(cp)),
                            cp,
                            @intFromBool(key.mods.ctrl),
                            @intFromBool(key.mods.alt),
                            @intFromBool(key.mods.shift),
                        });
                    } else {
                        try w.print("[event] key cp=U+{x} mods=ctrl:{d} alt:{d} shift:{d}\n", .{
                            cp,
                            @intFromBool(key.mods.ctrl),
                            @intFromBool(key.mods.alt),
                            @intFromBool(key.mods.shift),
                        });
                    }
                } else if (key.special) |sp| {
                    try w.print("[event] key special={s} mods=ctrl:{d} alt:{d} shift:{d}\n", .{
                        @tagName(sp),
                        @intFromBool(key.mods.ctrl),
                        @intFromBool(key.mods.alt),
                        @intFromBool(key.mods.shift),
                    });
                } else {
                    try w.writeAll("[event] key <invalid>\n");
                }
            },
            .mouse => |m| {
                try w.print("[event] mouse {s} ({d},{d}) mods=ctrl:{d} alt:{d} shift:{d}\n", .{
                    @tagName(m.button),
                    m.x,
                    m.y,
                    @intFromBool(m.mods.ctrl),
                    @intFromBool(m.mods.alt),
                    @intFromBool(m.mods.shift),
                });
            },
            .resize => |sz| {
                try w.print("[event] resize {d}x{d}\n", .{ sz.width, sz.height });
            },
            .paste => |text| {
                try w.print("[event] paste len={d}\n", .{text.len});
            },
            .focus => |focused| {
                try w.print("[event] focus {s}\n", .{if (focused) "in" else "out"});
            },
        }
    }
};

/// Decoder state machine
decoder: Decoder,
/// Raw input buffer
input_buf: [256]u8,
/// Current position in input buffer
input_pos: usize,
/// Number of valid bytes in input buffer
input_len: usize,
/// File descriptor to read from
fd: posix.fd_t,
/// Escape sequence timeout in milliseconds
escape_timeout_ms: u32,
/// Timestamp when we entered pending state
pending_start: ?i64,
/// Optional trace sink (see `TERMCAT_TRACE_INPUT`)
trace: Trace,

/// Default escape timeout (50ms is common for terminal emulators)
const default_escape_timeout_ms: u32 = 50;

/// Initialize the input handler
pub fn init(allocator: std.mem.Allocator, fd: posix.fd_t) Input {
    return Input{
        .decoder = Decoder.init(allocator),
        .input_buf = undefined,
        .input_pos = 0,
        .input_len = 0,
        .fd = fd,
        .escape_timeout_ms = default_escape_timeout_ms,
        .pending_start = null,
        .trace = Trace.init(),
    };
}

/// Clean up resources
pub fn deinit(self: *Input) void {
    self.decoder.deinit();
    self.trace.deinit();
}

/// Set the escape sequence timeout in milliseconds
pub fn setEscapeTimeout(self: *Input, timeout_ms: u32) void {
    self.escape_timeout_ms = timeout_ms;
}

/// Poll for an event with optional timeout.
/// Returns null on timeout, or an event if one is available.
///
/// This function handles:
/// - Buffered input from previous reads
/// - Poll/read from the file descriptor
/// - Escape sequence timeout for ambiguous sequences (bare ESC vs ESC + more)
pub fn pollEvent(self: *Input, timeout_ms: ?u32) !?Event.Event {
    // Track deadline for timeout handling
    const start_time = std.time.milliTimestamp();

    while (true) {
        // First, try to get an event from buffered input
        if (try self.processBuffer()) |event| {
            return event;
        }

        // Calculate remaining timeout
        const elapsed: i64 = std.time.milliTimestamp() - start_time;
        const remaining_ms: ?u32 = if (timeout_ms) |ms| blk: {
            if (elapsed >= ms) break :blk 0;
            break :blk @intCast(ms - @as(u32, @intCast(@max(0, elapsed))));
        } else null;

        // If decoder is pending (partial escape sequence), use escape timeout
        // to disambiguate bare ESC from ESC + more bytes
        const effective_timeout: ?u32 = if (self.decoder.isPending()) blk: {
            const esc_timeout = self.escape_timeout_ms;
            break :blk if (remaining_ms) |r| @min(esc_timeout, r) else esc_timeout;
        } else remaining_ms;

        // Check for escape timeout before polling
        if (self.decoder.isPending() and self.checkEscapeTimeout()) {
            // Timeout expired - emit pending escape
            if (self.decoder.reset()) |event| {
                return event;
            }
        }

        // Poll for input
        const poll_result = try self.pollFd(effective_timeout);

        if (poll_result > 0) {
            // Data available - read it
            const bytes_read = try self.readInput();
            if (bytes_read == 0) {
                // poll() reported ready but read() returned 0
                // This indicates EOF (TTY hangup, closed fd)
                return error.EndOfStream;
            }
            // We read data, loop back to process it
            continue;
        }

        // No data available (timeout on poll)
        // Check for escape timeout
        if (self.decoder.isPending() and self.checkEscapeTimeout()) {
            if (self.decoder.reset()) |event| {
                return event;
            }
        }

        // If we're blocking (no timeout), continue polling
        // If we have a timeout and it's expired, return null
        if (timeout_ms) |ms| {
            if (elapsed >= ms) {
                return null;
            }
        } else if (!self.decoder.isPending()) {
            // Blocking mode with no pending data - continue
            continue;
        }

        // Continue polling
    }
}

/// Non-blocking check for an event (equivalent to pollEvent(0))
pub fn peekEvent(self: *Input) !?Event.Event {
    return self.pollEvent(0);
}

/// Process buffered input and return an event if complete
fn processBuffer(self: *Input) !?Event.Event {
    while (self.input_pos < self.input_len) {
        const byte = self.input_buf[self.input_pos];
        self.input_pos += 1;

        // Track when we start pending state for timeout
        if (!self.decoder.isPending()) {
            self.pending_start = null;
        }

        const result = try self.decoder.feed(byte);

        switch (result) {
            .none => {
                // Need more input - record pending start time if not set
                if (self.decoder.isPending() and self.pending_start == null) {
                    self.pending_start = std.time.milliTimestamp();
                }
            },
            .event => |event| {
                self.pending_start = null;
                self.trace.logEvent(event);
                return event;
            },
        }
    }

    // Buffer exhausted - reset position
    self.input_pos = 0;
    self.input_len = 0;

    return null;
}

/// Poll the file descriptor for input
fn pollFd(self: *Input, timeout_ms: ?u32) !usize {
    var fds = [_]posix.pollfd{
        .{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;
    const result = try posix.poll(&fds, timeout);

    if (result > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
        return 1;
    }
    return 0;
}

/// Read available input into buffer
fn readInput(self: *Input) !usize {
    // Read into buffer starting at current length
    const space = self.input_buf.len - self.input_len;
    if (space == 0) return 0;

    const start = self.input_len;
    const bytes_read = posix.read(self.fd, self.input_buf[self.input_len..]) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };

    self.input_len += bytes_read;
    if (bytes_read > 0) {
        self.trace.logBytes("read", self.input_buf[start..][0..bytes_read]);
    }
    return bytes_read;
}

/// Check if escape timeout has expired
fn checkEscapeTimeout(self: *Input) bool {
    if (self.pending_start) |start| {
        const now = std.time.milliTimestamp();
        const elapsed = now - start;
        return elapsed >= self.escape_timeout_ms;
    }
    return false;
}

/// Reset the input handler state
pub fn reset(self: *Input) void {
    _ = self.decoder.reset();
    self.input_pos = 0;
    self.input_len = 0;
    self.pending_start = null;
}

test "Input init and deinit" {
    var input = Input.init(std.testing.allocator, 0);
    defer input.deinit();

    try std.testing.expectEqual(default_escape_timeout_ms, input.escape_timeout_ms);
}

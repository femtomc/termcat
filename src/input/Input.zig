const std = @import("std");
const posix = std.posix;
const Event = @import("../Event.zig");
const Decoder = @import("decoder.zig");

/// High-level input handler.
/// Wraps the decoder with buffering and timeout handling for ambiguous sequences.
pub const Input = @This();

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
    };
}

/// Clean up resources
pub fn deinit(self: *Input) void {
    self.decoder.deinit();
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

    const bytes_read = posix.read(self.fd, self.input_buf[self.input_len..]) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };

    self.input_len += bytes_read;
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

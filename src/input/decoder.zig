const std = @import("std");
const Event = @import("../Event.zig");
const Key = Event.Key;
const Mouse = Event.Mouse;
const Modifiers = Event.Modifiers;

/// Input decoder state machine.
/// Parses raw terminal input bytes into events.
pub const Decoder = @This();

/// Internal state for parsing sequences
const State = enum {
    /// Waiting for input
    ground,
    /// Received ESC, waiting for more
    escape,
    /// Received ESC [, parsing CSI sequence
    csi,
    /// Received ESC O, parsing SS3 sequence
    ss3,
    /// Parsing CSI parameters
    csi_param,
    /// Parsing SGR mouse sequence
    mouse_sgr,
    /// Inside bracketed paste
    paste,
    /// Parsing UTF-8 multi-byte sequence
    utf8,
    /// Parsing UTF-8 after ESC (Alt+unicode char)
    utf8_alt,
};

/// Maximum size for sequence buffer
const max_seq_len = 64;
/// Maximum size for paste buffer
const max_paste_len = 64 * 1024;
/// Maximum CSI parameter count
const max_params = 16;

/// Sequence buffer for partial input
seq_buf: [max_seq_len]u8,
/// Current position in sequence buffer
seq_len: usize,
/// CSI parameters
params: [max_params]u16,
/// Number of params parsed
param_count: usize,
/// Current param being built
current_param: u16,
/// Whether we've seen any digit for current param
has_param: bool,
/// Current decoder state
state: State,
/// UTF-8 bytes collected
utf8_buf: [4]u8,
/// UTF-8 bytes remaining
utf8_remaining: u3,
/// UTF-8 bytes collected so far
utf8_len: u3,
/// Paste buffer
paste_buf: []u8,
/// Current paste length
paste_len: usize,
/// Allocator for paste buffer
allocator: std.mem.Allocator,
/// Whether paste buffer is allocated
paste_allocated: bool,

/// Initialize the decoder
pub fn init(allocator: std.mem.Allocator) Decoder {
    return Decoder{
        .seq_buf = undefined,
        .seq_len = 0,
        .params = [_]u16{0} ** max_params,
        .param_count = 0,
        .current_param = 0,
        .has_param = false,
        .state = .ground,
        .utf8_buf = undefined,
        .utf8_remaining = 0,
        .utf8_len = 0,
        .paste_buf = &.{},
        .paste_len = 0,
        .allocator = allocator,
        .paste_allocated = false,
    };
}

/// Clean up decoder resources
pub fn deinit(self: *Decoder) void {
    if (self.paste_allocated) {
        self.allocator.free(self.paste_buf);
        self.paste_allocated = false;
    }
}

/// Result of feeding a byte to the decoder
pub const Result = union(enum) {
    /// No event yet, need more bytes
    none,
    /// A complete event
    event: Event.Event,
};

/// Feed a single byte to the decoder.
/// Returns an event if one is complete, or .none if more bytes needed.
pub fn feed(self: *Decoder, byte: u8) !Result {
    return switch (self.state) {
        .ground => self.handleGround(byte),
        .escape => self.handleEscape(byte),
        .csi => self.handleCsi(byte),
        .csi_param => self.handleCsiParam(byte),
        .ss3 => self.handleSs3(byte),
        .mouse_sgr => self.handleMouseSgr(byte),
        .paste => try self.handlePaste(byte),
        .utf8 => self.handleUtf8(byte, false),
        .utf8_alt => self.handleUtf8(byte, true),
    };
}

/// Handle ground state - normal character input
fn handleGround(self: *Decoder, byte: u8) Result {
    // Check for ESC
    if (byte == 0x1b) {
        self.state = .escape;
        self.seq_len = 0;
        return .none;
    }

    // Check for UTF-8 lead byte
    if (byte >= 0x80) {
        return self.startUtf8(byte);
    }

    // Control characters
    if (byte < 0x20) {
        return .{ .event = .{ .key = canonicalizeControl(byte) } };
    }

    // DEL
    if (byte == 0x7f) {
        return .{ .event = .{ .key = Key.fromSpecial(.backspace, .{}) } };
    }

    // Regular ASCII character
    return .{ .event = .{ .key = Key.fromCodepoint(byte, .{}) } };
}

/// Handle escape state - after receiving ESC
fn handleEscape(self: *Decoder, byte: u8) Result {
    switch (byte) {
        '[' => {
            self.state = .csi;
            return .none;
        },
        'O' => {
            self.state = .ss3;
            return .none;
        },
        0x1b => {
            // ESC ESC - emit first ESC, stay in escape state
            return .{ .event = .{ .key = Key.fromSpecial(.escape, .{}) } };
        },
        0x7f => {
            // Alt+Backspace (DEL)
            self.state = .ground;
            return .{ .event = .{ .key = Key.fromSpecial(.backspace, .{ .alt = true }) } };
        },
        else => {
            // Alt+key combination
            self.state = .ground;
            if (byte >= 0x20 and byte < 0x7f) {
                return .{ .event = .{ .key = Key.fromCodepoint(byte, .{ .alt = true }) } };
            }
            // Alt + control character
            if (byte < 0x20) {
                var key = canonicalizeControl(byte);
                key.mods.alt = true;
                return .{ .event = .{ .key = key } };
            }
            // Alt + UTF-8 character (ESC followed by UTF-8 lead byte)
            // This handles Alt+ñ, Alt+中, etc.
            if (byte >= 0x80) {
                // Start UTF-8 decode, but remember we have Alt modifier
                // For simplicity, we treat this as Alt + the decoded codepoint
                // Start collecting UTF-8 bytes
                const result = self.startUtf8WithAlt(byte);
                return result;
            }
            // Unknown byte after ESC - this shouldn't happen with valid input
            // but we emit ESC and let the byte be reprocessed
            return .{ .event = .{ .key = Key.fromSpecial(.escape, .{}) } };
        },
    }
}

/// Handle CSI start - ESC [
fn handleCsi(self: *Decoder, byte: u8) Result {
    // Check for CSI < (SGR mouse)
    if (byte == '<') {
        self.state = .mouse_sgr;
        self.resetParams();
        return .none;
    }

    // Check for CSI ? (private sequence like focus events)
    if (byte == '?') {
        // Store the '?' and continue to params
        self.seq_buf[0] = byte;
        self.seq_len = 1;
        self.state = .csi_param;
        self.resetParams();
        return .none;
    }

    // Regular CSI sequence - start param parsing
    self.state = .csi_param;
    self.seq_len = 0;
    self.resetParams();
    return self.handleCsiParam(byte);
}

/// Handle CSI parameter parsing
fn handleCsiParam(self: *Decoder, byte: u8) Result {
    // Digit - accumulate into current parameter
    if (byte >= '0' and byte <= '9') {
        self.current_param = self.current_param *| 10 +| (byte - '0');
        self.has_param = true;
        return .none;
    }

    // Semicolon - parameter separator
    if (byte == ';') {
        self.pushParam();
        return .none;
    }

    // Final byte - dispatch based on it
    if (byte >= 0x40 and byte <= 0x7e) {
        self.pushParam();
        return self.dispatchCsi(byte);
    }

    // Intermediate byte (space, !, ", #, etc.) - store and continue
    if (byte >= 0x20 and byte < 0x40) {
        if (self.seq_len < max_seq_len) {
            self.seq_buf[self.seq_len] = byte;
            self.seq_len += 1;
        }
        return .none;
    }

    // Invalid byte - reset
    self.state = .ground;
    return .none;
}

/// Handle SS3 sequence (ESC O)
fn handleSs3(self: *Decoder, byte: u8) Result {
    self.state = .ground;

    // SS3 function keys (F1-F4)
    const special: ?Key.Special = switch (byte) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => null,
    };

    if (special) |sp| {
        return .{ .event = .{ .key = Key.fromSpecial(sp, .{}) } };
    }

    // Unknown SS3 sequence
    return .none;
}

/// Handle SGR mouse sequence (CSI < ...)
fn handleMouseSgr(self: *Decoder, byte: u8) Result {
    // Digit - accumulate
    if (byte >= '0' and byte <= '9') {
        self.current_param = self.current_param *| 10 +| (byte - '0');
        self.has_param = true;
        return .none;
    }

    // Semicolon - next parameter
    if (byte == ';') {
        self.pushParam();
        return .none;
    }

    // M = press, m = release
    if (byte == 'M' or byte == 'm') {
        self.pushParam();
        self.state = .ground;
        return self.parseSgrMouse(byte == 'm');
    }

    // Invalid - reset
    self.state = .ground;
    return .none;
}

/// Handle paste data (inside bracketed paste)
fn handlePaste(self: *Decoder, byte: u8) !Result {
    // Check for end sequence: ESC [ 2 0 1 ~
    // We need to buffer and look for this pattern
    if (self.paste_len >= 5) {
        const end_seq = "\x1b[201~";
        const start = self.paste_len - 5;
        if (std.mem.eql(u8, self.paste_buf[start..self.paste_len], end_seq[0..5]) and byte == '~') {
            // Found end of paste - return the paste content (excluding end marker)
            const paste_content = self.paste_buf[0..start];
            self.state = .ground;
            const result = Result{ .event = .{ .paste = paste_content } };
            // Don't clear paste_len yet - data is still valid until next event
            return result;
        }
    }

    // Check for partial end sequence at very start
    if (self.paste_len == 0 and byte == 0x1b) {
        // Could be start of end sequence
    }

    // Append byte to paste buffer
    if (self.paste_len < self.paste_buf.len) {
        self.paste_buf[self.paste_len] = byte;
        self.paste_len += 1;
    } else {
        // Buffer full - need to grow
        try self.growPasteBuffer();
        self.paste_buf[self.paste_len] = byte;
        self.paste_len += 1;
    }

    return .none;
}

/// Handle UTF-8 continuation bytes
/// with_alt: if true, the Alt modifier should be applied to the result
fn handleUtf8(self: *Decoder, byte: u8, with_alt: bool) Result {
    // Must be a continuation byte (10xxxxxx)
    if ((byte & 0xc0) != 0x80) {
        // Invalid - reset and re-process as ground state
        self.state = .ground;
        return self.handleGround(byte);
    }

    self.utf8_buf[self.utf8_len] = byte;
    self.utf8_len += 1;
    self.utf8_remaining -= 1;

    if (self.utf8_remaining == 0) {
        // Complete UTF-8 sequence
        self.state = .ground;
        const len = self.utf8_len;
        if (std.unicode.utf8Decode(self.utf8_buf[0..len])) |codepoint| {
            const mods: Modifiers = if (with_alt) .{ .alt = true } else .{};
            return .{ .event = .{ .key = Key.fromCodepoint(codepoint, mods) } };
        } else |_| {
            // Invalid UTF-8 - ignore
            return .none;
        }
    }

    return .none;
}

/// Start parsing a UTF-8 multi-byte sequence
fn startUtf8(self: *Decoder, lead: u8) Result {
    // Determine expected length from lead byte
    const len: u3 = if ((lead & 0xe0) == 0xc0)
        2
    else if ((lead & 0xf0) == 0xe0)
        3
    else if ((lead & 0xf8) == 0xf0)
        4
    else {
        // Invalid lead byte - ignore
        return .none;
    };

    self.utf8_buf[0] = lead;
    self.utf8_len = 1;
    self.utf8_remaining = len - 1;
    self.state = .utf8;
    return .none;
}

/// Start parsing a UTF-8 multi-byte sequence with Alt modifier (ESC + UTF-8)
fn startUtf8WithAlt(self: *Decoder, lead: u8) Result {
    // Determine expected length from lead byte
    const len: u3 = if ((lead & 0xe0) == 0xc0)
        2
    else if ((lead & 0xf0) == 0xe0)
        3
    else if ((lead & 0xf8) == 0xf0)
        4
    else {
        // Invalid lead byte - emit ESC and return to ground
        self.state = .ground;
        return .{ .event = .{ .key = Key.fromSpecial(.escape, .{}) } };
    };

    self.utf8_buf[0] = lead;
    self.utf8_len = 1;
    self.utf8_remaining = len - 1;
    self.state = .utf8_alt; // Use utf8_alt state to remember Alt modifier
    return .none;
}

/// Dispatch a complete CSI sequence
fn dispatchCsi(self: *Decoder, final: u8) Result {
    self.state = .ground;

    // Check for focus events: CSI ? 1 ; ... and CSI I / CSI O
    if (final == 'I') {
        return .{ .event = .{ .focus = true } };
    }
    if (final == 'O') {
        return .{ .event = .{ .focus = false } };
    }

    // Check for bracketed paste start: CSI 2 0 0 ~
    if (final == '~') {
        return self.dispatchCsiTilde();
    }

    // Arrow keys and other special keys
    const mods = self.getModifiers();
    const special: ?Key.Special = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .tab, // Shift+Tab (CSI Z)
        else => null,
    };

    if (special) |sp| {
        var key_mods = mods;
        if (final == 'Z') key_mods.shift = true; // CSI Z is always Shift+Tab
        return .{ .event = .{ .key = Key.fromSpecial(sp, key_mods) } };
    }

    // Unknown CSI sequence
    return .none;
}

/// Dispatch CSI ~ sequences (function keys, etc.)
fn dispatchCsiTilde(self: *Decoder) Result {
    if (self.param_count == 0) return .none;

    const mods = self.getModifiers();
    const code = self.params[0];

    const special: ?Key.Special = switch (code) {
        1 => .home,
        2 => .insert,
        3 => .delete,
        4 => .end,
        5 => .page_up,
        6 => .page_down,
        7 => .home,
        8 => .end,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        200 => {
            // Bracketed paste start
            self.startPaste();
            return .none;
        },
        201 => {
            // Bracketed paste end (handled in paste state)
            return .none;
        },
        else => null,
    };

    if (special) |sp| {
        return .{ .event = .{ .key = Key.fromSpecial(sp, mods) } };
    }

    return .none;
}

/// Parse SGR mouse parameters into event
fn parseSgrMouse(self: *Decoder, is_release: bool) Result {
    if (self.param_count < 3) return .none;

    const cb = self.params[0];
    const x = self.params[1];
    const y = self.params[2];

    // Decode button from cb
    const button_bits = cb & 0x43; // bits 0, 1, 6
    const button: Mouse.Button = if (is_release)
        .release
    else switch (button_bits) {
        0 => .left,
        1 => .middle,
        2 => .right,
        64 => .wheel_up,
        65 => .wheel_down,
        else => if ((cb & 32) != 0) .move else .left,
    };

    // Decode modifiers
    const mods = Modifiers{
        .shift = (cb & 4) != 0,
        .alt = (cb & 8) != 0,
        .ctrl = (cb & 16) != 0,
    };

    return .{ .event = .{ .mouse = .{
        .x = if (x > 0) x - 1 else 0,
        .y = if (y > 0) y - 1 else 0,
        .button = button,
        .mods = mods,
    } } };
}

/// Extract modifiers from CSI parameters
fn getModifiers(self: *Decoder) Modifiers {
    // Modifiers are typically in param 2 (1-based: 1=none, 2=shift, 3=alt, etc.)
    if (self.param_count >= 2) {
        const mod_param = self.params[1];
        if (mod_param >= 1) {
            const mod_bits = mod_param - 1;
            return Modifiers{
                .shift = (mod_bits & 1) != 0,
                .alt = (mod_bits & 2) != 0,
                .ctrl = (mod_bits & 4) != 0,
            };
        }
    }
    return .{};
}

/// Canonicalize a control character to a Key event
fn canonicalizeControl(byte: u8) Key {
    return switch (byte) {
        0x00 => Key.fromCodepoint(' ', .{ .ctrl = true }), // Ctrl+Space
        0x09 => Key.fromSpecial(.tab, .{}), // Tab (Ctrl+I)
        0x0d => Key.fromSpecial(.enter, .{}), // Enter (Ctrl+M)
        0x1b => Key.fromSpecial(.escape, .{}), // Escape
        0x7f => Key.fromSpecial(.backspace, .{}), // Backspace (DEL)
        // Ctrl+A through Ctrl+Z (except Tab=0x09, Enter=0x0d, Escape=0x1b)
        0x01...0x08, 0x0a...0x0c, 0x0e...0x1a => Key.fromCodepoint('a' + byte - 1, .{ .ctrl = true }),
        else => Key.fromCodepoint(byte, .{ .ctrl = true }),
    };
}

/// Reset CSI parameters
fn resetParams(self: *Decoder) void {
    self.param_count = 0;
    self.current_param = 0;
    self.has_param = false;
}

/// Push current parameter and start new one
fn pushParam(self: *Decoder) void {
    if (self.param_count < max_params) {
        self.params[self.param_count] = if (self.has_param) self.current_param else 0;
        self.param_count += 1;
    }
    self.current_param = 0;
    self.has_param = false;
}

/// Start paste mode
fn startPaste(self: *Decoder) void {
    self.state = .paste;
    self.paste_len = 0;
    // Allocate initial paste buffer if not already done
    if (!self.paste_allocated) {
        self.paste_buf = self.allocator.alloc(u8, 4096) catch &.{};
        if (self.paste_buf.len > 0) {
            self.paste_allocated = true;
        }
    }
}

/// Grow paste buffer
fn growPasteBuffer(self: *Decoder) !void {
    const new_len = @min(self.paste_buf.len * 2, max_paste_len);
    if (new_len <= self.paste_buf.len) {
        return error.PasteBufferFull;
    }
    const new_buf = try self.allocator.realloc(self.paste_buf, new_len);
    self.paste_buf = new_buf;
}

/// Reset decoder state (for timeout handling)
pub fn reset(self: *Decoder) ?Event.Event {
    const old_state = self.state;
    self.state = .ground;
    self.seq_len = 0;
    self.resetParams();

    // If we were in escape state, emit the pending ESC
    if (old_state == .escape) {
        return .{ .key = Key.fromSpecial(.escape, .{}) };
    }

    return null;
}

/// Check if we're in the middle of a sequence (need more input or timeout)
pub fn isPending(self: *Decoder) bool {
    return self.state != .ground;
}

test "decode simple ASCII" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    const result = try decoder.feed('a');
    try std.testing.expect(result == .event);
    const event = result.event;
    try std.testing.expect(event == .key);
    try std.testing.expectEqual(@as(?u21, 'a'), event.key.codepoint);
}

test "decode escape key with timeout" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Feed ESC
    const result1 = try decoder.feed(0x1b);
    try std.testing.expect(result1 == .none);
    try std.testing.expect(decoder.isPending());

    // Simulate timeout
    const pending = decoder.reset();
    try std.testing.expect(pending != null);
    try std.testing.expect(pending.?.key.special == .escape);
}

test "decode arrow keys" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // ESC [ A = Up arrow
    _ = try decoder.feed(0x1b);
    _ = try decoder.feed('[');
    const result = try decoder.feed('A');

    try std.testing.expect(result == .event);
    try std.testing.expect(result.event.key.special == .up);
}

test "decode alt+letter" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // ESC a = Alt+a
    _ = try decoder.feed(0x1b);
    const result = try decoder.feed('a');

    try std.testing.expect(result == .event);
    try std.testing.expectEqual(@as(?u21, 'a'), result.event.key.codepoint);
    try std.testing.expect(result.event.key.mods.alt);
}

test "decode ctrl+letter" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Ctrl+C = 0x03
    const result = try decoder.feed(0x03);

    try std.testing.expect(result == .event);
    try std.testing.expectEqual(@as(?u21, 'c'), result.event.key.codepoint);
    try std.testing.expect(result.event.key.mods.ctrl);
}

test "decode function keys" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // ESC O P = F1
    _ = try decoder.feed(0x1b);
    _ = try decoder.feed('O');
    const result = try decoder.feed('P');

    try std.testing.expect(result == .event);
    try std.testing.expect(result.event.key.special == .f1);
}

test "decode enter and tab" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Enter = 0x0d
    const enter_result = try decoder.feed(0x0d);
    try std.testing.expect(enter_result.event.key.special == .enter);

    // Tab = 0x09
    const tab_result = try decoder.feed(0x09);
    try std.testing.expect(tab_result.event.key.special == .tab);
}

test "decode focus events" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // CSI I = focus in
    _ = try decoder.feed(0x1b);
    _ = try decoder.feed('[');
    const result = try decoder.feed('I');

    try std.testing.expect(result == .event);
    try std.testing.expect(result.event == .focus);
    try std.testing.expect(result.event.focus == true);
}

test "decode UTF-8" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // UTF-8 encoded 'é' (U+00E9): 0xC3 0xA9
    _ = try decoder.feed(0xc3);
    const result = try decoder.feed(0xa9);

    try std.testing.expect(result == .event);
    try std.testing.expectEqual(@as(?u21, 0xe9), result.event.key.codepoint);
}

test "decode SGR mouse" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // CSI < 0;10;20 M = left button press at (10, 20)
    _ = try decoder.feed(0x1b);
    _ = try decoder.feed('[');
    _ = try decoder.feed('<');
    _ = try decoder.feed('0');
    _ = try decoder.feed(';');
    _ = try decoder.feed('1');
    _ = try decoder.feed('0');
    _ = try decoder.feed(';');
    _ = try decoder.feed('2');
    _ = try decoder.feed('0');
    const result = try decoder.feed('M');

    try std.testing.expect(result == .event);
    try std.testing.expect(result.event == .mouse);
    try std.testing.expectEqual(@as(u16, 9), result.event.mouse.x); // 0-indexed
    try std.testing.expectEqual(@as(u16, 19), result.event.mouse.y);
    try std.testing.expect(result.event.mouse.button == .left);
}

test "decode alt+backspace" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // ESC DEL = Alt+Backspace
    _ = try decoder.feed(0x1b);
    const result = try decoder.feed(0x7f);

    try std.testing.expect(result == .event);
    try std.testing.expect(result.event.key.special == .backspace);
    try std.testing.expect(result.event.key.mods.alt);
}

test "decode alt+utf8 character" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    // ESC + UTF-8 'é' (U+00E9): ESC 0xC3 0xA9 = Alt+é
    _ = try decoder.feed(0x1b);
    _ = try decoder.feed(0xc3);
    const result = try decoder.feed(0xa9);

    try std.testing.expect(result == .event);
    try std.testing.expectEqual(@as(?u21, 0xe9), result.event.key.codepoint);
    try std.testing.expect(result.event.key.mods.alt);
}

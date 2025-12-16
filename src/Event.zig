const std = @import("std");

/// Terminal event types
pub const Event = union(enum) {
    /// Key press event
    key: Key,
    /// Mouse event
    mouse: Mouse,
    /// Terminal resize event
    resize: Size,
    /// Bracketed paste content
    paste: []const u8,
    /// Focus in/out event
    focus: bool,
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

/// Key event
///
/// Invariants:
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
    /// Unicode codepoint for regular keys, null for special keys
    codepoint: ?u21,
    /// Special key (arrows, function keys, etc.), null for regular keys
    special: ?Special,
    /// Modifier keys
    mods: Modifiers,

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
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };

    /// Create a key event from a codepoint
    pub fn fromCodepoint(cp: u21, mods: Modifiers) Key {
        return .{
            .codepoint = cp,
            .special = null,
            .mods = mods,
        };
    }

    /// Create a key event from a special key
    pub fn fromSpecial(sp: Special, mods: Modifiers) Key {
        return .{
            .codepoint = null,
            .special = sp,
            .mods = mods,
        };
    }
};

/// Modifier key state
pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _padding: u5 = 0,

    pub const none: Modifiers = .{};

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return self.ctrl == other.ctrl and
            self.alt == other.alt and
            self.shift == other.shift;
    }
};

/// Mouse event
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
        move,
    };
};

test "Key from codepoint" {
    const key = Key.fromCodepoint('a', .{ .ctrl = true });
    try std.testing.expectEqual(@as(?u21, 'a'), key.codepoint);
    try std.testing.expectEqual(@as(?Key.Special, null), key.special);
    try std.testing.expect(key.mods.ctrl);
}

test "Key from special" {
    const key = Key.fromSpecial(.enter, .{});
    try std.testing.expectEqual(@as(?u21, null), key.codepoint);
    try std.testing.expectEqual(@as(?Key.Special, .enter), key.special);
}

test "Modifiers equality" {
    const m1: Modifiers = .{ .ctrl = true };
    const m2: Modifiers = .{ .ctrl = true };
    const m3: Modifiers = .{ .alt = true };
    try std.testing.expect(m1.eql(m2));
    try std.testing.expect(!m1.eql(m3));
}

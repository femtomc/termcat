const std = @import("std");
const posix = std.posix;
const ColorDepth = @import("posix.zig").ColorDepth;
const InitOptions = @import("posix.zig").InitOptions;

test "detectCapabilities returns reasonable defaults" {
    const caps = @import("posix.zig").detectCapabilities();

    // Should return valid capability structure
    try std.testing.expect(@intFromEnum(caps.color_depth) >= 0);
    try std.testing.expect(@intFromEnum(caps.color_depth) <= 3); // mono, basic, 256, true
}

test "ColorDepth enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(ColorDepth.mono));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(ColorDepth.basic));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(ColorDepth.color_256));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(ColorDepth.true_color));
}

test "InitOptions default values" {
    const opts = InitOptions{};

    try std.testing.expect(opts.install_sigwinch);
    try std.testing.expect(opts.enable_mouse);
    try std.testing.expect(opts.enable_bracketed_paste);
    try std.testing.expect(opts.enable_focus_events);
}

test "InitOptions custom values" {
    const opts = InitOptions{
        .install_sigwinch = false,
        .enable_mouse = false,
        .enable_bracketed_paste = true,
        .enable_focus_events = false,
    };

    try std.testing.expect(!opts.install_sigwinch);
    try std.testing.expect(!opts.enable_mouse);
    try std.testing.expect(opts.enable_bracketed_paste);
    try std.testing.expect(!opts.enable_focus_events);
}

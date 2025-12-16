//! termcat - A minimal, fast cell-based terminal I/O library for Zig
//!
//! This library provides a termbox2-style API for terminal manipulation with:
//! - Raw mode terminal control
//! - Alternate screen buffer
//! - Mouse and keyboard input
//! - Bracketed paste support
//! - Color and attribute handling
//! - Diff-based rendering (future)

const std = @import("std");

// Core types
pub const Cell = @import("Cell.zig");
pub const Color = Cell.Color;
pub const Attributes = Cell.Attributes;

// Event types
pub const Event = @import("Event.zig");
pub const Size = Event.Size;
pub const Position = Event.Position;
pub const Rect = Event.Rect;
pub const Key = Event.Key;
pub const Modifiers = Event.Modifiers;
pub const Mouse = Event.Mouse;

// Backend
pub const backend = struct {
    pub const posix = @import("backend/posix.zig");
    pub const pty = @import("backend/pty.zig");
    pub const posix_test = @import("backend/posix_test.zig");

    pub const PosixBackend = posix.PosixBackend;
    pub const Pty = pty.Pty;
    pub const ColorDepth = posix.ColorDepth;
    pub const Capabilities = posix.Capabilities;
    pub const InitOptions = posix.InitOptions;
};

// Convenience re-exports for backend types
pub const PosixBackend = backend.PosixBackend;
pub const Pty = backend.Pty;
pub const ColorDepth = backend.ColorDepth;
pub const Capabilities = backend.Capabilities;
pub const InitOptions = backend.InitOptions;

/// Detect terminal capabilities from environment
pub const detectCapabilities = backend.posix.detectCapabilities;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}

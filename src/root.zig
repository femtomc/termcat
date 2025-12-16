//! termcat - A minimal, fast cell-based terminal I/O library for Zig
//!
//! This library provides a termbox2-style API for terminal manipulation with:
//! - Raw mode terminal control
//! - Alternate screen buffer
//! - Mouse and keyboard input
//! - Bracketed paste support
//! - Color and attribute handling
//! - Diff-based rendering

const std = @import("std");

// Core types
pub const Cell = @import("Cell.zig");
pub const Color = Cell.Color;
pub const ColorDepth = Cell.ColorDepth;
pub const Attributes = Cell.Attributes;
pub const Buffer = @import("Buffer.zig");
pub const Renderer = @import("Renderer.zig");

// Unicode utilities
pub const unicode = struct {
    pub const width = @import("unicode/width.zig");
    pub const codePointWidth = width.codePointWidth;
    pub const stringWidth = width.stringWidth;
};

// Event types
pub const Event = @import("Event.zig");
pub const Size = Event.Size;
pub const Position = Event.Position;
pub const Rect = Event.Rect;
pub const Key = Event.Key;
pub const Modifiers = Event.Modifiers;
pub const Mouse = Event.Mouse;

// Input handling
pub const input = struct {
    pub const Decoder = @import("input/decoder.zig");
    pub const Input = @import("input/Input.zig");
};

// Backend
pub const backend = struct {
    pub const posix = @import("backend/posix.zig");
    pub const windows = @import("backend/windows.zig");
    pub const pty = @import("backend/pty.zig");
    pub const posix_test = @import("backend/posix_test.zig");
    pub const integration_test = @import("backend/integration_test.zig");

    pub const PosixBackend = posix.PosixBackend;
    pub const WindowsBackend = windows.WindowsBackend;
    pub const Pty = pty.Pty;

    /// Platform-specific backend
    pub const Backend = if (@import("builtin").os.tag == .windows)
        windows.WindowsBackend
    else
        posix.PosixBackend;

    /// Platform-specific capabilities
    pub const Capabilities = if (@import("builtin").os.tag == .windows)
        windows.Capabilities
    else
        posix.Capabilities;

    /// Platform-specific init options
    pub const InitOptions = if (@import("builtin").os.tag == .windows)
        windows.InitOptions
    else
        posix.InitOptions;
};

// Convenience re-exports for backend types
pub const PosixBackend = backend.PosixBackend;
pub const WindowsBackend = backend.WindowsBackend;
pub const Backend = backend.Backend;
pub const Pty = backend.Pty;
pub const Input = input.Input;
pub const Decoder = input.Decoder;
pub const Capabilities = backend.Capabilities;
pub const InitOptions = backend.InitOptions;

/// Detect terminal capabilities from environment
pub const detectCapabilities = if (@import("builtin").os.tag == .windows)
    backend.windows.detectCapabilities
else
    backend.posix.detectCapabilities;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}

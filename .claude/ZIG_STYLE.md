# Zig Style Guide

This document establishes Zig coding conventions for termcat. Follow these guidelines for all code contributions.

## Tooling

Always use the Zig formatter:

```bash
zig fmt src/           # Format source files
zig fmt .              # Format all .zig files
zig build test         # Run tests
```

**Run `zig fmt` before considering any work complete.**

## Formatting

Use `zig fmt` defaults:

- 4-space indentation
- No tabs
- Max line width: 120 characters (soft limit)
- Unix line endings (LF)

## Naming Conventions

| Item | Convention | Example |
|------|------------|---------|
| Types | PascalCase | `HttpClient`, `ParseError` |
| Functions | camelCase | `parseConfig`, `getValue` |
| Variables | snake_case | `user_count`, `max_retries` |
| Constants | snake_case | `max_buffer_size` |
| Compile-time constants | snake_case | `block_size` |
| Namespaces (file-level) | snake_case | `config_parser.zig` |

Special conventions:
- Type functions (return a type): PascalCase like `ArrayList`
- Acronyms in names: treat as single word (`HttpServer`, not `HTTPServer`)

## File Organization

Order items within a file:

1. Imports (`@import`)
2. Public constants
3. Private constants
4. Type definitions (structs, enums, unions)
5. Public functions
6. Private functions
7. Tests

```zig
const std = @import("std");
const mem = std.mem;

const Config = @import("config.zig").Config;

// Public constants
pub const default_timeout: u64 = 30;

// Private constants
const max_retries: u32 = 3;

// Types
pub const Client = struct {
    allocator: mem.Allocator,
    timeout: u64,

    pub fn init(allocator: mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .timeout = default_timeout,
        };
    }

    pub fn deinit(self: *Client) void {
        // cleanup
    }
};

// Public functions
pub fn createClient(allocator: mem.Allocator) !Client {
    return Client.init(allocator);
}

// Private functions
fn validateConfig(config: Config) bool {
    return config.valid;
}

// Tests
test "client initialization" {
    const client = Client.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(default_timeout, client.timeout);
}
```

## Error Handling

- Use error unions (`!T`) for recoverable errors
- Use `try` for error propagation
- Define error sets explicitly when the set is small and known
- Use `anyerror` sparingly

```zig
const ParseError = error{
    InvalidSyntax,
    UnexpectedToken,
    EndOfFile,
};

fn parseConfig(data: []const u8) ParseError!Config {
    if (data.len == 0) return error.EndOfFile;
    // ...
}

// Propagate with try
pub fn loadConfig(path: []const u8) !Config {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    defer allocator.free(data);
    return try parseConfig(data);
}
```

## Memory Management

- Always pair allocations with deallocations
- Use `defer` for cleanup immediately after allocation
- Prefer stack allocation when size is known at comptime
- Document ownership in function signatures

```zig
// Caller owns returned memory
pub fn readFile(allocator: mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, max_file_size);
}

// Usage - caller must free
const data = try readFile(allocator, "config.txt");
defer allocator.free(data);
```

## Structs

- Use anonymous struct literals (`.{ ... }`) when type is known
- Order fields by alignment (largest first) to minimize padding
- Use `packed` only when necessary for FFI or memory layout

```zig
const Point = struct {
    x: f64,  // 8 bytes
    y: f64,  // 8 bytes
    id: u32, // 4 bytes
    flags: u8, // 1 byte

    pub fn origin() Point {
        return .{ .x = 0, .y = 0, .id = 0, .flags = 0 };
    }
};
```

## Optional and Null

- Use optionals (`?T`) instead of sentinel values
- Use `orelse` for default values
- Use `if` with capture for conditional unwrapping

```zig
fn findValue(key: []const u8) ?u32 {
    // ...
}

// Usage
const value = findValue("key") orelse default_value;

if (findValue("key")) |v| {
    // use v
} else {
    // not found
}
```

## Slices and Arrays

- Prefer slices (`[]T`) over pointers to arrays
- Use `[_]T{...}` for inferred-length arrays
- Use sentinel-terminated slices (`[:0]const u8`) for C interop

```zig
// Array with inferred length
const items = [_]u32{ 1, 2, 3, 4, 5 };

// Slice parameter - more flexible
fn processItems(items: []const u32) void {
    for (items) |item| {
        // ...
    }
}
```

## Comptime

- Use `comptime` for compile-time computation
- Prefer `inline` only when necessary for performance
- Use `@TypeOf` and `@typeInfo` for generic programming

```zig
fn Matrix(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    return struct {
        data: [rows][cols]T,

        pub fn zero() @This() {
            return .{ .data = .{.{0} ** cols} ** rows };
        }
    };
}

const Mat4x4 = Matrix(f32, 4, 4);
```

## Testing

- Place tests at the bottom of each file
- Use descriptive test names in strings
- Use `std.testing` assertions
- Test error cases explicitly

```zig
test "parseConfig returns error on empty input" {
    const result = parseConfig("");
    try std.testing.expectError(error.EndOfFile, result);
}

test "parseConfig parses valid config" {
    const config = try parseConfig("key=value");
    try std.testing.expectEqualStrings("value", config.get("key").?);
}
```

## Things to Avoid

- `@panic` in library code (return errors instead)
- Ignoring errors with `_ = mayFail()` without justification
- `anytype` when a concrete type or trait would work
- Excessive use of `inline` (trust the optimizer)
- Global mutable state
- `std.debug.print` in production code (use logging)
- Commented-out code

## Documentation

Use `///` for doc comments:

```zig
/// Parses configuration from the given data.
///
/// Returns `error.InvalidSyntax` if the data is malformed.
/// Caller owns the returned Config and must call `deinit`.
pub fn parseConfig(allocator: mem.Allocator, data: []const u8) !Config {
    // ...
}
```

## Common Patterns

### Builder pattern
```zig
const ClientBuilder = struct {
    timeout: u64 = 30,
    retries: u32 = 3,

    pub fn setTimeout(self: *ClientBuilder, timeout: u64) *ClientBuilder {
        self.timeout = timeout;
        return self;
    }

    pub fn build(self: ClientBuilder) Client {
        return .{ .timeout = self.timeout, .retries = self.retries };
    }
};

// Usage
const client = ClientBuilder{}
    .setTimeout(60)
    .build();
```

### Resource cleanup with errdefer
```zig
pub fn init(allocator: mem.Allocator) !Self {
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const handle = try openResource();
    errdefer closeResource(handle);

    return .{ .buffer = buffer, .handle = handle };
}
```

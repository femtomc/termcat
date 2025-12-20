# termcat

A low-level terminal I/O interface library in Zig.

## Quick Commands

```bash
# Build
zig build
zig build -Doptimize=ReleaseFast

# Test
zig build test
zig test src/main.zig

# Run
zig build run
zig run src/main.zig

# Format
zig fmt src/
zig fmt .

# Generate docs
zig build-lib src/main.zig -femit-docs
```

## Issue Tracking (Tissue)

```bash
tissue list                       # List all issues
tissue ready                      # Show issues ready to work (no blockers)
tissue show <id>                  # Show issue details
tissue new "title"                # Create new issue
tissue new "title" -t feature     # Create with tag
tissue new "title" -p 2           # Create with priority (1-5, 1=highest)
tissue status <id> in_progress    # Update status
tissue status <id> closed         # Close an issue
tissue comment <id> -m "message"  # Add comment to issue
tissue tag add <id> <tag>         # Add a tag
tissue dep add <id> blocks <id2>  # Add dependency
```

## Project Structure

```
termcat/
├── src/
│   ├── main.zig         # Entry point / library root
│   └── root.zig         # Library exports (if library)
├── build.zig            # Build configuration
├── build.zig.zon        # Package manifest
├── .claude/             # Claude configuration
│   ├── CLAUDE.md        # This file
│   ├── ZIG_STYLE.md     # Zig style conventions
│   └── commands/        # Slash commands
│       └── work.md      # Issue workflow
├── .tissue/             # Issue tracker data
└── zig-out/             # Build output
```

## Architecture

<!-- Document your architecture here as the project develops -->

## Dependencies

<!-- Document key dependencies and their purposes -->

## External Resources

- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig Standard Library](https://ziglang.org/documentation/master/std/)
- [Zig Learn](https://ziglearn.org/)
- [Tissue Issue Tracker](https://github.com/femtomc/tissue)

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

## Issue Tracking (Beads)

```bash
bd list                           # List all issues
bd ready                          # Show issues ready to work (no blockers)
bd show <id>                      # Show issue details
bd create "title"                 # Create new issue
bd create "title" -t feature      # Create feature (types: bug, feature, epic)
bd create "title" -p 1            # Create with priority (0=P0, 1=P1, 2=P2, 3=P3)
bd update <id> --status in_progress
bd close <id>                     # Close an issue
bd comment <id> "message"         # Add comment to issue
bd sync                           # Sync with git remote
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
├── .beads/              # Issue tracker data
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
- [Beads Issue Tracker](https://github.com/steveyegge/beads)

# Zig Porting Debt

Idiomatic-Zig cleanup for code that is functionally complete but
C-shaped. Each item describes working code that could be more
natural in Zig.

## Architecture

- `types.zig` is a monolithic `tmux.h` replacement. Move
  subsystem-owned types closer to their implementation files.
- The keycode constant block in `types.zig` belongs in a dedicated
  key module.
- `c.zig` imports more C surface than needed. Narrow it toward
  Zig std/os abstractions where available.

## State and Ownership

- Global mutable state in `client.zig`, `server.zig`, `proc.zig`
  uses C-shaped globals. Zig benefits from explicit state structs.
- Nullable-pointer-heavy object graphs in `types.zig`,
  `session.zig`, `window.zig` could use Zig's type system to
  make ownership and initialization phases explicit.
- Bitmask-style flags could become narrower enums or packed structs.

## Memory

- `xmalloc.zig` fatal-on-OOM helpers are faithful to tmux. A Zig
  pass could propagate allocator errors where appropriate.
- `utf8.zig` uses linear caches and an alloc-heavy byte-builder;
  tmux uses RB trees and pre-sized buffer writes.
- `arguments.zig` sorts hash-map keys on demand instead of owning
  an ordered tree/iterator structure.

## Registration

- `cmd.zig` hand-maintains a command table. A comptime-driven
  registry would be more idiomatic.

## Constants

- `spawn.zig` uses a magic `TIOCSCTTY` literal. Use a named
  constant.
- `grid_default_cell` lives in `types.zig` as a temporary placeholder.
  Move it to `grid.zig`.

## Bridges

- `src/compat/imsg.c` and `imsg-buffer.c` are C IPC bridges.
  Replace with Zig-native implementation when the protocol
  layer stabilizes.

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

## API Drift

- Several call sites used the Zig 0.14 `std.ArrayList(T).init(allocator)`
  pattern. Zig 0.15 removed `init`; the idiomatic form is zero-init
  (`.{}`) with the allocator passed to each method. Remaining
  instances in non-test code paths (e.g., `status-prompt.zig:1434`,
  `window.zig:1652`, `control.zig:360`) still compile because
  they are not reachable from any current call graph, but will
  break once wired in.
- `std.fs.File.writer()` in Zig 0.15 requires a `[]u8` buffer
  argument. Two call sites in `status-prompt.zig` and `status.zig`
  were ported to use `file.writeAll` / `std.fmt.bufPrint` instead.

## Status Screen Lifecycle

- `StatusLine.screen` was changed from an embedded `Screen`
  value to `?*Screen` (heap-allocated pointer, nullable). The
  embedded form created a type mismatch with `screen_init` which
  heap-allocates. `status_free` now frees the screen when
  non-null. All test clients that construct `StatusLine` use
  the default `.screen = null`.

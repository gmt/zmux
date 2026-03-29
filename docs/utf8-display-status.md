## Current State

- `src/types.zig` and `src/utf8.zig` provide a tmux-shaped payload and
  decode substrate built around `Utf8Data`.
- `src/utf8-combined.zig` provides reduced combine policy helpers.
- `src/grid.zig` stores real cell payloads and exposes reduced `string_cells` and
  `grid_reader` function above that payload model.
- `src/utf8.zig` exposes reduced shared `CellBufferReader` plus
  `CellBuffer` word/range helpers so prompt-side word/search/edit boundaries
  can reuse lower display-cell traversal
- `src/server-print.zig` raw attached view output writes through a shared
  `screen-write` escaped-byte code path.
- `src/format.zig`, `src/cmd-list-keys.zig`, and `src/key-string.zig` uses
  the named shared `displayWidth`/`trimDisplay`/`padDisplay` consumer facade
  instead of reaching under it to the legacy raw helper names.
- `src/screen-write.zig` writes through a shared cell-aware path which,
  relative to tmux `screen_write_cell`, is incomplete.
- prompt, status, and message consumers touch the shared path, but they
  do not yet all use one end-to-end display-cell model.
- `src/status.zig` owns a shared per-client `status-interval` timer
  so status redraw cadence stays under the shared status runtime 

## Active Gap

The main open gap is not raw Unicode decoding but broader
consumer and runtime adoption of the shared display-cell model.

- prompt and status consumers have reduced runtime behavior beyond the
  now-shared prompt word/search/edit helpers
- some redraw, tty, and mode behavior still suffers from deficient underlying impl.
- broader search, edit, and message surfaces still do not all share one
  display-cell representation

## Future Intent

- keep extending the lower shared layers instead of adding command-local text
  hacks
- widen the shared `screen-write`, prompt, status, and redraw/runtime seams
- UTF-8-sensitive parity work once close
  enough that new command ports can depend on them

## Library Rule

`utf8proc` may help as a backend width or conversion helper, but it should not
become the semantic model. The semantic model stays tmux-shaped and
display-oriented.

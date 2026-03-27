# UTF-8 and Display Status

This note tracks the current truthful state of the shared display stack and the
future intent for reopening UTF-8-sensitive parity work.

## Current State

- `src/types.zig` and `src/utf8.zig` already provide a tmux-shaped payload and
  decode substrate built around `Utf8Data`.
- `src/utf8-combined.zig` already provides the reduced combine policy helpers.
- `src/grid.zig` stores real cell payloads rather than forcing all text through
  ASCII-only storage, and now also exposes reduced shared `string_cells` and
  `grid_reader` seams above that payload model.
- `src/utf8.zig` now also exposes a reduced shared `CellBufferReader` seam so
  prompt-side word/search boundaries can reuse lower display-cell traversal
  instead of keeping local byte-oriented scans.
- `src/server-print.zig` raw attached view output now writes through a shared
  `screen-write` escaped-byte seam instead of keeping a consumer-local UTF-8
  decode-and-escape loop.
- `src/format.zig`, `src/cmd-list-keys.zig`, and `src/key-string.zig` now use
  the named shared `displayWidth`/`trimDisplay`/`padDisplay` consumer facade
  instead of reaching under it to the legacy raw helper names.
- `src/screen-write.zig` writes through a shared cell-aware seam, but that seam
  is still reduced relative to tmux `screen_write_cell`.
- prompt, status, and message consumers already touch the shared path, but they
  do not yet all use one end-to-end display-cell model.

## Active Gap

The main open gap is not raw Unicode decoding. The main open gap is broader
consumer and runtime adoption of the shared display-cell model.

Open pressure points:
- prompt and status consumers still have reduced runtime behavior beyond the
  now-shared prompt word/search reader seam
- some redraw, tty, and mode behavior still sits on reduced seams
- broader search, edit, and message surfaces still do not all share one
  display-cell representation

## Future Intent

- keep extending the lower shared layers instead of adding command-local text
  hacks
- widen the shared `screen-write`, prompt, status, and redraw/runtime seams
- reopen UTF-8-sensitive parity work only when those shared seams are truthful
  enough that new command ports can depend on them

## Library Rule

`utf8proc` may help as a backend width or conversion helper, but it should not
become the semantic model. The semantic model stays tmux-shaped and
display-oriented.

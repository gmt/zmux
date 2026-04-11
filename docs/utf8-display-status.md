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
- `src/screen-write.zig` writes through the shared cell-aware path used by
  prompt, status, message, popup, and attached-view output consumers.
- `src/status.zig` and `src/status-runtime.zig` now keep a persistent base
  status screen plus an overlay screen for prompt/message redraw, matching the
  tmux `status.c` ownership model closely enough that payload redraw, prompt
  geometry, and message overlays share one runtime.
- `src/status-prompt.zig` prompt input, width, scroll, and cursor calculations
  now feed the same message-format expansion path used to render the prompt.
- payload rendering in `src/server-client.zig` consumes the shared owned status
  screens rather than building a separate temporary status/prompt renderer.

## Follow-On Work

- future Unicode-sensitive bugs should now be treated as ordinary focused
  parity bugs in the affected command or runtime area, not as evidence that a
  separate display-cell adoption project is still open.

## Library Rule

`utf8proc` may help as a backend width or conversion helper, but it should not
become the semantic model. The semantic model stays tmux-shaped and
display-oriented.

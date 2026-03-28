# Window Copy

`src/window-copy.zig` currently owns a reduced `copy-mode` runtime.

## Current State

- `copy-mode` enters an alternate-screen pane mode instead of failing at the
  command boundary
- the mode snapshots a source pane's base screen into a private backing screen
  and renders a viewport into the target pane
- `capture-pane -M` sees that backing snapshot rather than the live pane
- the reduced runtime supports:
  - source-pane snapshots via `copy-mode -s`
  - refresh from the source pane
  - cursor movement
  - mouse-root `copy-mode -M` entry that keeps the reduced copy-mode cursor
    under pane drags
  - page and half-page navigation
  - top, middle, and bottom viewport positioning
  - history-top and history-bottom over the captured snapshot
  - scrollbar drag entry via `copy-mode -S` and in-mode `scroll-to-mouse`
    over the reduced snapshot viewport
  - cancel/exit
- the default key tables now include a small reduced `copy-mode` and
  `copy-mode-vi` binding set for those supported commands
- client key routing now prefers the active pane-mode key table while the
  client is otherwise on the default root table
- pane drag does not yet start or maintain a visual selection; the reduced
  drag path currently tracks cursor position only

## Future Intent

- widen the backing model to real pane history rather than the current
  snapshot-only screen
- add selection, copy, search, marks, and fuller drag semantics from upstream
  `window-copy.c`
- teach the reduced pane-mode runtime about resize and richer mode-local draw
  hooks so `window-copy` does not need to live entirely inside the alternate
  pane screen

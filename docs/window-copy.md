# Window Copy

`src/window-copy.zig` owns a `copy-mode` runtime.

## Current State

- `copy-mode` enters an alternate-screen pane mode.
- The mode keeps a private backing screen synchronized from the source
  pane's live base history and renders a viewport into the target pane.
- `capture-pane -M` sees that live-synchronized mode backing.
- Supported features:
  - source-pane snapshots via `copy-mode -s`
  - refresh from the source pane
  - cursor movement
  - mouse-root `copy-mode -M` entry with cursor tracking under
    pane drags
  - page and half-page navigation
  - numeric `goto-line` over the captured snapshot
  - top, middle, bottom viewport positioning
  - history-top and history-bottom
  - scrollbar drag via `copy-mode -S` and `scroll-to-mouse`
  - the `copy-selection-no-clear`, `copy-pipe-line`,
    `copy-pipe-line-and-cancel`, and `copy-pipe-end-of-line` command heads
  - cancel/exit
- Default key tables include `copy-mode` and `copy-mode-vi`
  bindings for supported commands.
- Client key routing prefers the active pane-mode key table when
  the client is on the default root table.
- Pane drag tracks cursor position but does not maintain a visual
  selection.

## Gaps (tracked in docs/zig-porting-todo.md)

- Selection, copy, search, marks, drag, and clipboard-selection semantics
- Regex search, mouse-driven selection growth, and the broader line/word
  selection semantics are still short of full tmux parity
- A smaller tail of less-common copy-mode commands still falls through to the
  unsupported-command path
- Resize and mode-local draw hooks

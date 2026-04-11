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
  - regex search through `search-forward` and `search-backward`
  - incremental search restoring its saved origin as the search text changes
    and clearing back to that origin when the incremental text is emptied
  - keyboard selection growth through ordinary cursor movement
  - drag-started visual selection that stays synchronized on the active screen
  - edge drag updates that scroll the viewport while extending a selection
  - stationary edge-drag repeat scrolling through the copy-mode timer path
  - mouse-positioned `select-word` and `select-line`
  - word selection growth that keeps using the session's
    `word-separators`
  - the shipped `copy-mode` and `copy-mode-vi` `send -X`
    command heads without falling into the unsupported-command path
  - `copy-selection` and related copy helpers falling back to the current
    search match when no explicit selection is active
  - `append-selection` appending onto the current top paste buffer instead of
    always creating a fresh one
  - clipboard export through the live copy-mode copy helpers
  - cursor and active selection rewrapping across pane width changes
  - cancel/exit
- Default key tables include `copy-mode` and `copy-mode-vi`
  bindings for supported commands.
- Client key routing prefers the active pane-mode key table when
  the client is on the default root table.

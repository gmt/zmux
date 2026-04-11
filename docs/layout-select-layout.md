# Select Layout Runtime

`select-layout`, `next-layout`, and `previous-layout` now prefer the
authoritative `window.layout_root` when dumping layouts, but still fall back to
live pane-rectangle reconstruction when the stored tree is stale or missing.

- preset layout names and next/previous cycling update `Window.lastlayout` and
  keep the current pane-list order as the leaf order
- `select-layout -E` spreads the nearest sibling branch evenly inside that same
  layout runtime
- `select-layout -o` and explicit layout strings use tmux-style layout dumps
  from `window.layout_root` when it matches the live pane set
- applying a dumped or explicit layout may resize the reduced window geometry
  to the layout bounds before the pane rectangles are written back
- future intent is to move these commands onto persistent shared layout
  ownership once split, destroy, and resize paths share one authoritative tree

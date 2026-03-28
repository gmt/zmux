# Select Layout Runtime

`select-layout`, `next-layout`, and `previous-layout` currently operate on a
transient layout tree reconstructed from the live pane rectangles in
[`src/layout.zig`](src/layout.zig).

- preset layout names and next/previous cycling update `Window.lastlayout` and
  keep the current pane-list order as the leaf order
- `select-layout -E` spreads the nearest sibling branch evenly inside that same
  transient reconstruction
- `select-layout -o` and explicit layout strings use tmux-style layout dumps
  derived from the transient tree rather than persistent `window.layout_root`
  ownership
- applying a dumped or explicit layout may resize the reduced window geometry
  to the layout bounds before the pane rectangles are written back
- future intent is to move these commands onto persistent shared layout
  ownership once split, destroy, and resize paths share one authoritative tree

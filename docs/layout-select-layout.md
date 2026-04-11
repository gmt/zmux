# Select Layout Runtime

`select-layout`, `next-layout`, and `previous-layout` now snapshot undo state
and explicit-layout round trips directly from the authoritative
`window.layout_root`. Generic layout dump, spread, and resize helpers now
prefer that shared tree whenever its leaf ownership matches the window's live
pane order.

- preset layout names and next/previous cycling update `Window.lastlayout` and
  keep the current pane-list order as the leaf order
- `select-layout -E` now spreads the nearest sibling branch from the
  authoritative layout tree when `layout_root` is present
- `select-layout -o` and explicit layout strings use tmux-style layout dumps
  from `window.layout_root`
- `resize-pane` now also prefers the authoritative tree over stale pane
  rectangles when the stored layout still owns the window panes
- applying a dumped or explicit layout may resize the reduced window geometry
  to the layout bounds before the pane rectangles are written back
- layout-managed pane detaches now leave the repaired tree geometry alone
  instead of re-collapsing the gap from stale rectangles after `layout_close_pane`

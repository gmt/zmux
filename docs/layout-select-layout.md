# Select Layout Runtime

`select-layout`, `next-layout`, and `previous-layout` now snapshot undo state
and explicit-layout round trips directly from the authoritative
`window.layout_root`. Pane destroy and respawn teardown now repair that shared
tree before removing panes, but generic layout-dump callers still fall back to
live pane-rectangle reconstruction when the stored tree is stale or missing.

- preset layout names and next/previous cycling update `Window.lastlayout` and
  keep the current pane-list order as the leaf order
- `select-layout -E` now spreads the nearest sibling branch from the
  authoritative layout tree when `layout_root` is present
- `select-layout -o` and explicit layout strings use tmux-style layout dumps
  from `window.layout_root`
- applying a dumped or explicit layout may resize the reduced window geometry
  to the layout bounds before the pane rectangles are written back
- layout-managed pane detaches now leave the repaired tree geometry alone
  instead of re-collapsing the gap from stale rectangles after `layout_close_pane`
- future intent is to finish the remaining stale-tree producers in the broader
  runtime so generic dump and geometry helpers no longer need rectangle
  fallback

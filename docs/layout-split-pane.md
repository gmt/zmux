# Split Pane Runtime

`split-window` now routes its shared command path through the window layout
runtime, and the shared dump, spread, and resize helpers now keep using the
stored layout tree when it still owns the window panes.

- Target-pane splits size and place the new pane from the target pane's
  geometry.
- `-h`/default `-v`, `-l`, `-p`, `-b`, `-f`, `-I`, and `-Z` ride the shared
  layer.
- Full-size `-f` splits and the related destroy, respawn, dump, spread, and
  resize follow-on paths now stay on the shared layout tree instead of
  reconstructing from pane rectangles when the tree is still valid.

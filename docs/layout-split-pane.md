# Split Pane Runtime

`split-window` currently uses a reduced flat-pane geometry seam in
[`window.zig`](src/window.zig) rather than a full tmux
layout tree.

- ordinary target-pane splits now size and place the new pane from the target
  pane's current geometry
- `-h`/default `-v`, `-l`, `-p`, `-b`, `-I`, and reduced `-Z` now ride that
  shared seam
- full-size `-f` splits across an already multi-pane window still require a
  real top-level layout runtime and should stay explicit about that boundary

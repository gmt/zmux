# Split Pane Runtime

`split-window` uses a flat-pane geometry layer in `window.zig` instead
of a full tmux layout tree.

- Target-pane splits size and place the new pane from the target pane's
  geometry.
- `-h`/default `-v`, `-l`, `-p`, `-b`, `-I`, and `-Z` ride the shared
  layer.
- Full-size `-f` splits across a multi-pane window require a real
  top-level layout runtime (see `docs/zig-porting-todo.md`).

# Split Pane Runtime

`split-window` uses a flat-pane geometry layer in `window.zig` instead
of a full tmux layout tree.

- Target-pane splits size and place the new pane from the target pane's
  geometry.
- `-h`/default `-v`, `-l`, `-p`, `-b`, `-f`, `-I`, and `-Z` ride the shared
  layer.
- Persistent layout ownership is still incomplete in the broader runtime, but
  the command path now drives full-size `-f` splits through the shared layout
  tree.

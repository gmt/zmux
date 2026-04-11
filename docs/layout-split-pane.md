# Split Pane Runtime

`split-window` now routes its shared command path through the window layout
runtime, but adjacent window teardown and dump helpers still have some
rectangle-first fallback behavior.

- Target-pane splits size and place the new pane from the target pane's
  geometry.
- `-h`/default `-v`, `-l`, `-p`, `-b`, `-f`, `-I`, and `-Z` ride the shared
  layer.
- Persistent layout ownership is still incomplete in the broader runtime, but
  the command path now drives full-size `-f` splits and the related destroy and
  respawn teardown through the shared layout tree.

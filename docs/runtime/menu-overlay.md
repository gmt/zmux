# Menu Overlay Runtime

`src/menu.zig` owns the current shared menu overlay runtime used by
`display-menu`.

Current state:

- menu items are expanded at command execution time and rendered through the
  shared screen/grid path
- keyboard navigation, shortcut selection, and reduced mouse selection run
  through the shared per-client overlay path
- redraw and outer mouse-mode integration live under the existing
  `server-fn.zig`, `server-client.zig`, and `mouse-runtime.zig` seams
- `display-menu` currently supports the core tmux placement shorthands used by
  the default bindings (`C`, `M`, `P`, `R`, `S`, `W`) plus numeric positions

Future intent:

- reuse the same runtime for other tmux menu consumers instead of growing new
  command-local overlay code
- widen position handling toward fuller tmux format parity when a live consumer
  needs more than the current shorthand and numeric support

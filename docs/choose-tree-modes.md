# Choose-Tree Modes

- `choose-tree`, `choose-client`, `choose-buffer`, and `customize-mode` are
  registered on the Zig command surface.
- Current `choose-client` behavior resolves `-t target-pane`, validates
  `-O sort-order`, keeps tmux's empty-client no-op case, and otherwise enters a
  `mode-tree`-backed `client-mode` alternate-screen browser over the shared
  `window-mode-runtime.zig` interface.
- The current `client-mode` supports tmux's default choose action plus
  detach, kill, suspend, tagging, custom `-F` format, `-f` filter, `-O`
  sorting, `-r` reverse sorting, template execution against the selected
  client target, custom `-K` key labels, preview rendering with copied status
  lines, live preview refresh through the shared mode update path, and `-Z`
  zoom ownership for the mode lifetime.
- The current `client-mode` still lacks tmux's fuller preview interaction
  surface, so the remaining chooser gap is now mostly polish around the
  `client-mode` preview/runtime path rather than missing tree-mode mechanics.
- Current `choose-tree` and `find-window` behavior enters a reduced `tree-mode`
  alternate-screen browser over the shared `window-mode-runtime.zig` interface.
- The current reduced `tree-mode` supports session/window/pane tree browsing,
  current-target focus, default choose actions, `-F` formatting, `-f` filters,
  `-O` sorting, `-r` reverse sorting, `-G` group squashing control,
  shared `mode-tree` raw-key handling, tagging/navigation bindings, preview
  panes, preview-tile mouse selection,
  prompt-driven command and kill flows, custom `-K` key labels, and `-Z` zoom
  ownership for the mode lifetime
  with prior zoom state restored on exit.
- The current reduced `tree-mode` still does not provide all of tmux's chooser
  interaction polish, but the biggest remaining chooser gap is now on the
  `client-mode` side rather than preview-tile selection in `tree-mode`.
- Current `customize-mode` behavior enters the reduced
  `options-mode` pane consumer described in [`docs/modes/options-mode.md`](docs/modes/options-mode.md).
- Current `choose-buffer` behavior enters the reduced `buffer-mode` consumer on
  the shared pane-mode runtime, including custom `-K` key format and preview
  flag plumbing.
- Future intent is to move the rest of the chooser family onto the same shared
  pane-mode substrate instead of adding command-local shims.

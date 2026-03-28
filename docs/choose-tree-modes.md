# Choose-Tree Modes

- `choose-tree`, `choose-client`, `choose-buffer`, and `customize-mode` are
  registered on the Zig command surface.
- Current `choose-client` behavior resolves `-t target-pane`, validates
  `-O sort-order`, keeps tmux's empty-client no-op case, and otherwise enters a
  reduced `client-mode` alternate-screen list over the shared
  `window-mode-runtime.zig` seam.
- The current reduced `client-mode` supports tmux's default choose action plus
  detach, kill, suspend, tagging, custom `-F` format, `-f` filter, `-O`
  sorting, `-r` reverse sorting, and template execution against the selected
  client target.
- The current reduced `client-mode` does not provide tmux's preview pane,
  preview zoom, or custom `-K` key-format path.
- Current `choose-tree` and `find-window` behavior enters a reduced `tree-mode`
  alternate-screen browser over the shared `window-mode-runtime.zig` seam.
- The current reduced `tree-mode` supports session/window/pane tree browsing,
  current-target focus, default choose actions, `-F` formatting, `-f` filters,
  `-O` sorting, `-r` reverse sorting, `-G` group squashing control, reduced
  tagging/navigation bindings, and `-Z` zoom ownership for the mode lifetime
  with prior zoom state restored on exit.
- The current reduced `tree-mode` does not provide tmux's preview panes,
  prompt-driven command or kill flows, mouse preview selection, or custom `-K`
  key-format bindings.
- Current `customize-mode` behavior enters the reduced read-only
  `options-mode` pane consumer described in [`docs/modes/options-mode.md`](/home/greg/src/zmux/docs/modes/options-mode.md).
- Current `choose-buffer` behavior still stops at the explicit reduced-mode
  error because there is still no `window-buffer` consumer wired onto the
  pane-mode runtime.
- Future intent is to move the rest of the chooser family onto the same shared
  pane-mode substrate instead of adding command-local shims.

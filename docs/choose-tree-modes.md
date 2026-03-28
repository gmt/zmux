# Choose-Tree Modes

- `choose-tree`, `choose-client`, `choose-buffer`, and `customize-mode` are
  registered on the Zig command surface.
- Current `choose-client` behavior resolves `-t target-pane`, validates
  `-O sort-order`, keeps tmux's empty-client no-op case, and otherwise enters a
  reduced `client-mode` alternate-screen list over the shared
  `window-mode-runtime.zig` interface.
- The current reduced `client-mode` supports tmux's default choose action plus
  detach, kill, suspend, tagging, custom `-F` format, `-f` filter, `-O`
  sorting, `-r` reverse sorting, and template execution against the selected
  client target.
- The current reduced `client-mode` does not provide tmux's preview pane,
  preview zoom, or custom `-K` key-format path.
- Current `choose-tree`, `choose-buffer`, and `customize-mode` behavior still
  stops at the explicit reduced-mode error because there is still no
  `window-tree`, `window-buffer`, or `window-customize` consumer wired onto the
  pane-mode runtime.
- Future intent is to move the rest of the chooser family onto the same shared
  pane-mode substrate instead of adding command-local shims.

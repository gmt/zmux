# Choose-Tree Modes

- `choose-tree`, `choose-client`, `choose-buffer`, and `customize-mode` are
  registered on the Zig command surface.
- Current behavior resolves `-t target-pane`, validates `-O sort-order`, keeps
  tmux's empty choose-buffer and choose-client no-op cases, and otherwise
  returns an explicit reduced-mode error because the shared `mode-tree.zig`
  substrate is present only as a reduced tree-state engine and there is still
  no `window-tree`, `window-client`, `window-buffer`, or `customize-mode`
  consumer wired onto the pane-mode runtime.
- Future intent is to land those window-mode runtimes under the shared
  `window-mode-runtime.zig` seam rather than adding command-local shims.

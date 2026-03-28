# Choose-Tree Modes

- `choose-tree`, `choose-client`, `choose-buffer`, and `customize-mode` are
  registered on the Zig command surface.
- Current behavior resolves `-t target-pane`, validates `-O sort-order`, keeps
  tmux's empty choose-buffer and choose-client no-op cases, and otherwise
  returns an explicit reduced-mode error because the shared tree/client/buffer
  mode runtime is still absent.
- Future intent is to land those window-mode runtimes under the shared
  `window-mode-runtime.zig` seam rather than adding command-local shims.

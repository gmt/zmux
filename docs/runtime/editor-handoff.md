# Editor Handoff

Current state:

- `window-buffer` selected edit now opens the configured `editor` inside a
  popup-backed PTY runtime.
- zmux still uses the editor handoff helper to manage the temp file and apply
  the saved contents on popup exit if the buffer identity still matches.
- if the pane is still in `buffer-mode` when the editor returns, zmux rebuilds
  the mode tree before redraw so the updated sample text is visible

Future intent:

- keep the temp-file lifecycle helper small and shared rather than growing a
  second popup-editor implementation
- continue shrinking any remaining popup/editor behavior drift as the fuller
  popup runtime matures

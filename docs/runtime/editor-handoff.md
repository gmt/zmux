# Editor Handoff

Current state:

- `window-buffer` selected edit uses an attached-client editor handoff.
- zmux writes the selected paste buffer to a temp file, asks the attached
  client to run the configured `editor`, and applies the saved file on unlock
  if the buffer identity still matches.
- if the pane is still in `buffer-mode` when the editor returns, zmux rebuilds
  the mode tree before redraw so the updated sample text is visible

Future intent:

- replace this handoff path with a real popup-editor runtime under the shared
  popup ownership boundary
- keep the save callback and mode-tree refresh semantics aligned with tmux as
  that fuller popup runtime lands

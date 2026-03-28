# Popup Runtime

This note describes the current `display-popup` runtime in zmux and the
intended direction for the remaining popup seam.

## Current State

- `display-popup` now owns a shared popup overlay runtime instead of returning
  a permanent command-local stub.
- the current popup body is built from captured shell-command output and
  rendered through the attached-client overlay path
- popup title, width, height, close, border-line selection, popup style, and
  border style are applied by the shared runtime
- popup modify and close reuse the same shared popup ownership instead of
  rebuilding command-local state
- popup rendering currently lives inside the pane area below any status rows;
  it does not yet cover tmux's full-screen overlay/status intersection
- popup output currently uses the reduced shared screen writer over captured
  bytes; it does not yet emulate tmux's live PTY-fed terminal parser inside the
  popup body

## Future Intent

- replace captured-output popup bodies with a live PTY-backed popup job runtime
- widen popup positioning to tmux's richer format-aware coordinate rules
- add the remaining popup job, mouse, resize, menu, and editor behaviors on the
  shared popup runtime instead of in `display-popup`

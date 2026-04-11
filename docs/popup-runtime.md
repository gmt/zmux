# Popup Runtime

## Current State

- `display-popup` owns a shared popup overlay runtime.
- The popup body now runs as a live PTY-backed job and parses into a
  popup-local terminal surface rendered through the attached-client overlay
  path.
- Title, width, height, close, border-line selection, popup style,
  and border style are applied by the shared runtime.
- `display-popup -x/-y` now expands tmux-shaped popup position formats,
  including centre, pane, mouse, status-line, and window-status anchors.
- Popup modify, close, resize, key forwarding, mouse forwarding, and
  popup-editor reuse shared popup ownership.
- Popup context-menu actions now cover paste, fill-space, centre, and
  pane promotion on top of the live runtime.
- Rendering lives inside the pane area below status rows; full-screen
  overlay/status intersection is not covered.
- `window-buffer` edit now rides popup-editor through the shared popup
  runtime instead of the older direct attached-client dispatch path.

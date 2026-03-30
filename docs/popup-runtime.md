# Popup Runtime

## Current State

- `display-popup` owns a shared popup overlay runtime.
- The popup body is built from captured shell-command output and
  rendered through the attached-client overlay path.
- Title, width, height, close, border-line selection, popup style,
  and border style are applied by the shared runtime.
- Popup modify and close reuse shared popup ownership.
- Rendering lives inside the pane area below status rows; full-screen
  overlay/status intersection is not covered.
- Output uses the shared screen writer over captured bytes; a live
  PTY-fed terminal parser inside the popup body is not implemented.

## Gaps (tracked in docs/zig-porting-todo.md)

- Live PTY-backed popup job runtime
- Format-aware coordinate rules
- Popup job, mouse, resize, menu, and editor behaviors

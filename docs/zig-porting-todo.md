# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## ~~Pane Resize~~ (FIXED)

- Fixed: `window_pane_resize` now queues `WindowPaneResize` entries
  and calls `screen_resize` (un-stubbed to forward to
  `screen_resize_cursor`). `layout_fix_panes` / `apply_panes_skip`
  call `window_pane_resize` instead of direct assignment.
  `server_client_check_pane_resize` → `window_pane_send_resize` →
  TIOCSWINSZ chain was already ported — just never fed.

## SGR Attribute Rendering

- `fortune|cowsay|lolcat` produces garbled output. lolcat emits
  heavy SGR colour sequences (256-color and truecolor) that stress
  the screen-write → tty-draw rendering pipeline. The cow renders
  but colours corrupt the line drawing characters. tmux handles
  this correctly.

## Sixel Passthrough

- chafa inside zmux shows `SIXEL IMAGE (2x1)` instead of real
  images when the outer terminal doesn't advertise sixel support
  via TERM. tmux solves this with `allow-passthrough` which lets
  DCS sequences pass directly to the outer terminal. zmux's
  `apply_dcs` has a passthrough stub that silently consumes.

## Shell Environment

- Initial shell spawns as `-sh-5.3$` (no profile sourcing). The
  pane shell should behave as a login shell matching tmux's
  `default-command` behaviour.

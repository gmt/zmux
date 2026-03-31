# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## Pane Resize

- Terminal resize events update the zmux status bar width correctly
  but panes do not resize. Vim stays at 80x24 when the terminal
  grows. tmux propagates resize via server_client_check_resize →
  recalculate_size → window_pane_resize → ioctl(TIOCSWINSZ).
  One of those links is broken or fudged in zmux.

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

# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## TTY Query/Response Routing

- `tty_send_requests` / `tty_repeat_requests` are disabled because
  terminal query responses (DA, colour, XTVERSION) leak into panes
  as raw escape text. The responses arrive on the client fd but are
  read by `pane_read_cb` instead of being consumed by the tty-keys
  decoder. tmux routes these through `tty_keys_next` → DA/palette
  response parsers in `tty-keys.c`. zmux's `tty_keys_next` dispatch
  loop exists (T6-4) but the client read callback doesn't use it.

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

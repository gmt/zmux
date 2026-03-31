# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## TTY Query/Response Routing

- `tty_keys_next_inner` now contains the full tmux dispatch chain:
  clipboard, DA1/DA2/XDA, colour, palette, mouse, extended key,
  and winsz parsers all run before falling back to input-keys.zig.
  Client stdin is routed through `tty.in_buf` → `tty_keys_next`.
- `tty_send_requests` / `tty_repeat_requests` remain disabled pending
  interactive verification that responses are consumed without ANSI
  spam. The parsers are wired; the queries just need to be re-enabled
  and tested in a real terminal.

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

# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## ~~Pane Resize~~ (FIXED)

- Fixed: `window_pane_resize` now queues `WindowPaneResize` entries
  and calls `screen_resize` (un-stubbed to forward to
  `screen_resize_cursor`). `layout_fix_panes` / `apply_panes_skip`
  call `window_pane_resize` instead of direct assignment.
  `server_client_check_pane_resize` → `window_pane_send_resize` →
  TIOCSWINSZ chain was already ported — just never fed.

## ~~SGR Attribute Rendering~~ (FIXED)

- Fixed: `apply_sgr_raw` was splitting semicolon-separated params
  into independent calls, breaking multi-param sequences like
  `38;2;R;G;B`. Accumulated into a single buffer. Also
  `style_to_sgr` in `tty-draw.zig` only handled 16 basic ANSI
  colours — added `append_colour` supporting 256-colour and 24-bit
  RGB. Wired `tty_check_fg`/`bg`/`us` into `tty_attributes`.

## DCS Passthrough

- The `allow-passthrough` option exists in the options table but
  the DCS handler (`input.zig` `apply_dcs`) silently consumes
  `tmux;`-prefixed passthrough sequences instead of forwarding
  them to the outer terminal.  Sixel rendering itself (parse →
  store → re-emit via `sixel_print`) is fully wired.

## ~~Shell Environment~~ (FIXED)

- Fixed: `server_start` re-created global options from table
  defaults after forking, resetting `default-shell` to `/bin/sh`.
  Now calls `getshell()` in the server child to pick up `$SHELL`.

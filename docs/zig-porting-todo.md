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

## ~~DCS Passthrough~~ (FIXED)

- Fixed: `apply_dcs` now checks `allow-passthrough`, strips the
  `tmux;` prefix, and forwards raw bytes via `screen_write_rawstring`
  → `wp.passthrough_pending`.  The render cycle in
  `build_client_draw_payload` drains the buffer to attached clients.
  Also fixed out-of-bounds crash in DCS sixel parameter parsing
  (`dcs.params[1]` on empty param string).

## ~~Shell Environment~~ (FIXED)

- Fixed: `server_start` re-created global options from table
  defaults after forking, resetting `default-shell` to `/bin/sh`.
  Now calls `getshell()` in the server child to pick up `$SHELL`.

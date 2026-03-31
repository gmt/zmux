# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## Screen Write

- `screen_write_text` returns 0 and renders nothing. Two callers
  in window-customize.zig (`draw_key`, `draw_option`) produce
  empty preview panes.
- Call sites that tmux routes through `screen_write_puts(ctx, &gc, ...)`
  were fudged to use `putn(ctx, text)` during porting, dropping
  the `GridCell` styling parameter. Affected call sites: mode-tree
  item/filter/search display, window-tree labels and navigation
  arrows, window-clock time rendering. Text renders in default
  style only.
- `screen_write_strlen` (text measurement for layout in
  `screen_write_text`) has no callers because `screen_write_text`
  is a stub; will be needed when `screen_write_text` is ported.

## Server-Client

- `server_client_print` drops pane output when the pane has an
  active mode (copy/view). Should forward to `window_copy_add`
  for view-mode text accumulation.

## Session

- `session_lock_timer` logs only. The `lock-after-time` option
  has no libevent timer wired; session locking is non-functional.
- `session_update_history` sets `gd.hlimit` but does not call
  `grid_collect_history` (which exists and is implemented).
  Changing `history-limit` on a live session does not trim
  existing scrollback.

## Window Copy Mode

- `window_copy_vadd` ignores the `parse` flag. `input_parse_screen`
  exists but is not wired; view-mode output renders ANSI escapes
  as raw text.

## Format

- `resolve_pane_format`, `resolve_window_format`, and
  `resolve_session_format` return hardcoded "0". `FormatContext`
  lacks a type discriminator; tmux returns "1" when the format
  tree was created with the matching type. Affects conditional
  format strings like `#{?pane_format,...}`.

## Commands

- `cmd-list-clients` default template is
  `#{client_tty} #{client_termname}`. tmux uses a richer template
  including `client_name`, `session_name`, dimensions, uid, and
  flags. The format variables exist; the template string needs
  updating.

## Job Runtime

- `job_run_child` hardcodes `/bin/sh`. The `default-shell` session
  option is defined in the options table but not consulted when
  `JOB_DEFAULTSHELL` is set.

## Image and Sixel

- Image/sixel rendering pipeline stubs (`screen_write_sixelimage`,
  `tty_cmd_sixelimage`, `tty_draw_images`) have zero callers.
  Infrastructure exists in `image.zig`, `image-sixel.zig`, and
  `tty-features.zig` but the wiring from input → storage → tty
  output is not connected.

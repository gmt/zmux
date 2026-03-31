# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.
Each item is an actionable porting task.

## Key Dispatch

- `window_pane_key` (window.zig) returns 0 without dispatching
  keys to the active mode's key handler or forwarding to the pane
  via `input_key_pane`. Mode key handling (copy-mode, customize-mode)
  is inert from the server-side dispatch path.
- `window_pane_copy_key` (window.zig) iterates synchronized panes
  but discards the key argument. `synchronize-panes` keyboard
  forwarding is non-functional.

## Screen Write

- `screen_write_text` returns 0 and renders nothing. Blocks
  window-customize preview panes and mode-tree text display.
  Four callers depend on it.
- `screen_write_puts` is a no-op. Used for formatted text output
  to screens (e.g., mode-tree item display).
- `screen_write_strlen` returns 0. Used for text measurement in
  screen_write_text layout calculations.
- `rawstring` is a no-op. tmux uses this for DCS/OSC passthrough
  sequences written through screen-write.
- `setselection` is a no-op. Clipboard integration via OSC 52
  write path from screen-write.
- `fullredraw` is a no-op. zmux relies on PANE_REDRAW flags
  instead; verify this is functionally equivalent.

## TTY

- `tty_check_overlay` returns hardcoded 1 (always visible). Should
  check client overlay bounds. Used by `tty_cmd_cell` and drawing
  functions to skip cells occluded by popups/menus.
- `tty_cmd_cell` fetches the screen context `s` then discards it.
  tmux uses the screen for attribute comparison and wide-character
  handling during cell rendering.
- `tty_cmd_sixelimage` is a no-op. Requires image/sixel runtime
  wiring to emit sixel DCS to the outer terminal.

## Server-Client

- `server_client_output_mode` drops output when the pane has an
  active mode (copy/view). Should dispatch to `window_copy_add`
  for view-mode text accumulation.
- `server_format_session` is a no-op placeholder for format-tree
  integration.

## Session

- `session_lock_timer` logs only. Session locking via the
  `lock-after-time` option is non-functional.
- `session_update_history` sets `hlimit` but does not call
  `grid_collect_history`. History trimming does not take effect
  when `history-limit` is changed on a live session.

## Window Copy Mode

- `window_copy_vadd` ignores the `parse` parameter. View-mode
  output does not parse ANSI escapes; colored text appears as
  raw escape codes.

## Format

- `resolve_pane_format`, `resolve_window_format`, and
  `resolve_session_format` return hardcoded "0" because
  `FormatContext` lacks a type discriminator. tmux returns "1"
  when the format tree was created with the matching type.
- `sixel_support` format variable returns "0"; needs to check
  the tty feature flag.

## Job Runtime

- `job_run_child` hardcodes `/bin/sh` as the shell. The
  `default-shell` session option is ignored when `JOB_DEFAULTSHELL`
  is set.

## Commands

- `cmd-start-server` exec is a no-op returning `.normal`.
- `cmd-list-clients` forwards to `cmd-list-panes` infrastructure
  instead of having its own exec function.
- `cmd-new-window` forwards to `cmd-select-window` infrastructure
  instead of having its own exec function.

## Image and Sixel

- `screen_write_sixelimage` needs to call `image_store` when
  writing sixel data into a screen.
- `tty_draw_images` needs to iterate `s.images` and write sixel
  data for each image to the outer tty.
- `sixel_to_screen` fallback (cell grid for non-sixel tty) is
  not ported.

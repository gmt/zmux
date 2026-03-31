# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## UTF-8 Width Fudges

Eight call sites use `bytes.len` (byte count) where tmux uses
`utf8_cstrwidth` (display width). CJK, emoji, and other wide
characters will overflow columns or be split mid-character.

- `mode-tree.zig:724` — `text_buf.items.len` used as display
  width limit for `putn` truncation. Should use display width
  to avoid splitting wide characters.
- `cmd-display-menu.zig:157` — `candidate.len + 3` for key
  display width. Should be `utf8_cstrwidth(candidate) + 3`.
- `menu.zig:198,209` — `kstr.len + 3` for key column width
  (two occurrences). Same fix.
- `format-draw.zig:321` — `expanded.len` for screen allocation
  width. Multi-byte format expansions get wrong-sized screens.
- `mode-tree.zig:1016` — `name.len` for menu item width.
- `mode-tree.zig:1030` — `title.len` for menu title width.
- `window-tree.zig:679,682` — `text.len` for fit check and
  centering calculation in `drawCenteredText`.

## Screen Redraw (dead module)

- `screen_redraw_screen` and `screen_redraw_pane` were ported
  (T4.17) but have zero callers. `server_client_check_redraw`
  uses a monolithic `build_client_draw_payload` instead of the
  per-pane redraw dispatch that tmux uses. The screen-redraw
  module needs to be wired into server-client's redraw path.

## TTY Feature Requests

- `tty_send_requests` and `tty_repeat_requests` are implemented
  but never called from `server-client.zig`. Terminal feature
  probing (colours, cursor shape, clipboard support) is never
  initiated from the server side for connected clients.

## TTY Write Callback

- `tty_write_callback` is an export stub that ignores all
  parameters. tmux uses it for output blocking via
  `tty_block_maybe`. Without it, zmux never backs off when the
  output buffer fills.

## TTY Viewport Offsets (dead functions)

- `tty_update_window_offset` was ported but has zero callers.
  tmux calls it from `resize_window`, `recalculate_size`,
  `session_set_current`, `window_set_active_pane`, and
  `screen_write_offset_timer`. Viewport offsets go stale after
  any layout or session change.
- `tty_window_bigger` was ported but has zero callers outside
  format-resolve. tmux calls it from `cmd_select_pane_redraw`.

## TTY Keys (dead dispatch loop)

- `tty_keys_next1` was ported (T4.18) but the dispatch loop
  `tty_keys_next` that tmux calls from `tty_read_callback` does
  not exist. The entire tty-keys parsing infrastructure (TST key
  decoder, CSI u, mouse, clipboard, DA parsers) is unreachable
  from the server's tty read path.

## Screen Write

- `screen_write_text` returns 0 and renders nothing. Two callers
  in window-customize.zig (`draw_key`, `draw_option`) produce
  empty preview panes.
- Call sites that tmux routes through `screen_write_puts(ctx, &gc, ...)`
  were fudged to use `putn(ctx, text)` during porting, dropping
  the `GridCell` styling parameter. Affected: mode-tree item
  display, window-tree labels/arrows, window-clock time rendering.
- `screen_write_strlen` has no callers; will be needed when
  `screen_write_text` is ported.
- `linefeed` is missing `image_scroll_up` / `image_check_line`
  calls for sixel image scrolling.

## Focus Events

- `KEYC_FOCUS_IN` / `KEYC_FOCUS_OUT` are recognized in
  `server_client_key_callback` (filtered for assume-paste) but
  no handler calls `window_update_focus` or sends
  `client-focus-in`/`client-focus-out` notifications. Terminal
  focus tracking is non-functional.
- `session_set_current` does not call `window_update_focus` when
  switching windows. tmux calls it for both the old and new window
  when `focus-events` is enabled.

## Format

- `resolve_window_bigger` compares `w.sx > cl.tty.sx` directly.
  tmux calls `tty_window_offset` which accounts for viewport
  offset fields (`oox`/`ooy`). Result may differ for offset
  rendering scenarios.
- `resolve_window_offset_x` / `resolve_window_offset_y` return
  `wp.xoff` / `wp.yoff` (pane offset within window). tmux returns
  `ox` / `oy` from `tty_window_offset` (window viewport offset
  within terminal). These are different values.
- `resolve_pane_format`, `resolve_window_format`, and
  `resolve_session_format` return hardcoded "0". `FormatContext`
  lacks a type discriminator.
- Popup position format variables (`popup_pane_top`,
  `popup_pane_bottom`, etc.) are missing from `cmd-display-menu`.

## Server-Client

- `server_client_print` drops pane output when the pane has an
  active mode (copy/view). Should forward to `window_copy_add`.
- `cmd_select_pane_redraw` is missing. tmux checks
  `tty_window_bigger` per-client and does a full redraw when the
  window is larger than the terminal; zmux always uses the
  lighter border/status redraw.
- `server_client_set_session` does not call
  `tty_update_client_offset`. Viewport offsets may be stale
  after session switches.

## Window Pane

- `window_pane_start_input` was ported but has zero callers.
  tmux calls it from `cmd_display_message_exec` and
  `cmd_split_window_exec` to attach client stdin to a pane.

## Menu Builder

- `menu_create`, `menu_add_item`, and `menu_add_items` were
  ported but have zero callers. `cmd-display-menu` builds
  `MenuItem` structs directly, bypassing the builder API.
  tmux routes through these functions from cmd-display-menu,
  mode-tree, popup, and status-prompt.

## Mode-Tree

- `drawcb` callback signature passes `*Data` (entire mode-tree
  struct) as first argument. tmux passes `mtd->modedata`
  (mode-specific data). window-customize.zig casts the wrong
  type, breaking encapsulation.
- `mode_tree_clear_tagged` is exported but has zero callers
  (tmux has 2 call sites).
- `runCommand` callers (window-tree, window-buffer) always pass
  session+winlink context. tmux sometimes passes `fs=NULL` to
  let the command resolve context implicitly.

## Window-Tree

- Tree separator lines use `putc('|')` instead of
  `screen_write.vline()` with box-drawing styling.

## Session

- `session_lock_timer` logs only. The `lock-after-time` option
  has no libevent timer; session locking is non-functional.
- `session_update_history` sets `gd.hlimit` but does not call
  `grid_collect_history` (which exists). Changing `history-limit`
  does not trim existing scrollback.

## Window Copy Mode

- `window_copy_vadd` ignores the `parse` flag.
  `input_parse_screen` exists but is not wired; view-mode output
  renders ANSI escapes as raw text.
- `window_copy_search_marks` is called from `doSearch` but 9 of
  10 tmux callers were fudged out: `scroll1`, `pageup1`,
  `pagedown1`, `size_changed`, `cmd_history_bottom`,
  `cmd_history_top`, `scroll_to`, `scroll_up`, `scroll_down`.
  Search mark highlighting is only updated on direct search,
  not on scroll or navigation.
- `window_copy_formats` is missing the `top_line_time` format
  variable.

## Commands

- `cmd-list-clients` default template is too minimal. tmux
  includes `client_name`, `session_name`, dimensions, uid, and
  flags. The format variables exist; the template needs updating.

## Job Runtime

- `job_run_child` hardcodes `/bin/sh`. The `default-shell`
  session option is not consulted when `JOB_DEFAULTSHELL` is set.

## Popup

- `popup_make_pane` calls `layout_split_pane` with 6 arguments
  but the function takes 4. This is a latent compile error
  hidden by Zig lazy compilation (function has no callers).

## Command Queue

- `cmdq_merge_formats` does not add the `command` format
  variable. tmux adds it so that `#{command}` resolves in
  hook templates.

## Deleted Stubs With Active tmux Callers

Functions deleted as "dead empty-body stubs" (b1863933, 718a80ab)
that tmux actively calls. zmux callers either skip the behavior
or use alternatives that don't match tmux semantics.

- `tty_raw` (21 callers in tmux): writes raw terminal sequences
  during tty_stop_tty and server_lock_client. Without it, terminal
  cleanup on tty stop/lock does not emit raw reset sequences.
- `tty_hyperlink` (1 caller): emits OSC 8 hyperlink sequences in
  tty_attributes. Hyperlink rendering is non-functional.
- `tty_draw_images` (1 caller): called from screen_redraw_draw_pane
  to render sixel images after pane content.
- `tty_write_one` (1 caller): called from tty_draw_images.
- `grid_set_cells` (1 caller): called from grid_view_set_cells for
  multi-cell character placement.
- `grid_string_cells_add_code` (3 callers): SGR code serialization
  in grid_string_cells_code.
- `grid_string_cells_add_hyperlink` (3 callers): hyperlink
  serialization in grid_string_cells.
- `input_reply` (25 callers): terminal reply for DA, DSR, DECRQSS,
  winops, etc. Replaced by input_replyf in some paths but many
  callers in CSI dispatch have no replacement.
- `input_osc_colour_reply` (5 callers): palette/fg/bg colour query
  replies.
- `input_report_current_theme` (1 caller): theme report reply.
- `input_csi_dispatch_winops` (1 caller): window operation replies.
- `input_csi_dispatch_sm_graphics` (1 caller): graphics mode replies.
- `input_request_reply` (2 callers): tty-keys clipboard/palette
  reply forwarding.
- `input_send_reply` (3 callers): low-level reply writer.
- `input_start_ground_timer` (4 callers): DCS/OSC/APC/rename ground
  timeout.
- `input_start_request_timer` (2 callers): request timeout.
- `input_set_buffer_size` (1 caller): options_push_changes buffer
  resize.
- `input_reply_clipboard` (4 callers): OSC 52 clipboard replies.

## Image and Sixel

- `sixel_parse` call in `input_dcs_dispatch` is stubbed
  (silently consumed). `screen_write_sixelimage` is a no-op.
  `tty_cmd_sixelimage` and `tty_draw_images` have zero callers.
  The full pipeline from input → sixel_parse → image_store →
  screen_write_sixelimage → tty output is not connected.

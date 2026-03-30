# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.
Each item describes what zmux does and what it lacks.

## Grid and Screen

- `screen_write_collect_*` batching system feeds the tty callback
  path. When no callback is set (off-screen renders), the collect
  path tracks state but skips the callback.
- Scrollback storage uses visible-rows-first ordering instead of
  tmux's history-first layout.

## Input Parser

- The input parser uses a direct byte-by-byte approach instead of
  tmux's state machine. CSI/ESC dispatch, DCS, APC entry points
  are stubs.
- `input_init`/`input_free`/`input_reset` lifecycle is stubbed.
- Request/reply machinery (DA, clipboard, colour, palette) is
  stubbed.

## TTY

- `tty.c` request/buffer/query/path machinery is absent. Capability
  capture is a selected subset, not tmux's full terminal registry.
- Local raw-mode/alternate-screen takeover is split into
  `client.zig` instead of being capability-driven from `tty.zig`.

## Format

- 185 `format_cb_*` aliases point to a single no-op stub. zmux's
  resolver table in `format-resolve.zig` handles many of these, but
  some format variables return empty/zero placeholder values.
- `format_create`/`format_free`/`format_find`/`format_add` are
  stubs. zmux uses `FormatContext` struct initialization instead.
- `format_defaults_*` context population is stubbed.
- `format_loop_*` iteration stubs return empty results.
- `format_job_get`/`format_job_complete` job-backed expansion is
  stubbed.
- `format_replace`/`format_replace_expression` expansion engine
  stubs delegate to the existing resolver but lack the full DSL.
- The formatter lacks jobs, pane-search `C`, and the broader DSL.

## Server-Client

- `server_client_handle_key`/`server_client_key_callback` key
  dispatch is stubbed.
- `server_client_check_mouse`/`server_client_check_mouse_in_pane`
  mouse classification is stubbed.
- `server_client_set_overlay` overlay installation is stubbed.
- `server_client_check_pane_resize`/`check_pane_buffer` are stubs.
- Repeat/resize/redraw/click timer callbacks are stubs.
- `server_client_unref`/`server_client_free` lifecycle is stubbed.

## Window Copy Mode

- ~200 `window_copy_*` functions are stubs or have stub bodies
  (parameter discards, hardcoded returns). The copy-mode engine
  lacks cursor movement, selection, search, scroll, copy/pipe,
  and draw implementations.

## Window Modes (tree, buffer, client, customize)

- Window mode wrapper functions delegate to existing Zig helpers
  where possible, but many (`kill`, `swap`, `command` callbacks,
  key-binding editing) are stubs.
- Mode-tree `draw()` and `handleKey()` have real implementations.
  `runCommand()`, `displayMenu()`, `displayHelp()` are stubs.

## Control Mode

- `control_read_callback`/`control_error_callback` I/O callbacks
  are stubs.
- Subscription checking (`control_check_subs_*`) has thin wrappers
  but the timer-driven polling path is stubbed.
- `control_append_data` output encoding exists but the full
  write/pending/flush pipeline has stub edges.

## File I/O

- `file_read_open`/`file_read_cancel`/`file_write_open`/
  `file_write_close`/`file_write_data` are client IPC stubs.
- The port lacks `MSG_READ_*` transport, tmux's shared
  `client_file` ownership/backpressure model, and callback-time
  write-error completion.
- `file_read.zig` uses a synchronous client-side read loop instead
  of tmux's bufferevent-driven runtime.

## Popup

- `popup_draw_cb`/`popup_free_cb`/`popup_make_pane` are stubs.
  The overlay does not draw popup content.
- `popup_editor` returns -1.
- `popup_job_update_cb`/`popup_job_complete_cb` are stubs.

## Job Runtime

- `job.zig` uses a thread/pipe bridge instead of tmux's shared
  bufferevent-backed `job.c` runtime. This affects `if-shell`,
  `run-shell`, `pipe-pane`, and format jobs.

## Commands

- `cmd-queue.zig` `cmdq_get_current`/`cmdq_get_target` are
  skeletal. Queued current/target state is not fully wired.
- Readonly ACL enforcement is not wired through command dispatch.
- `server_send_exit()` flush/sweep path has no Zig equivalent.
- `display-panes` paints text badges instead of tmux's large digit
  art.
- `display-message -a/-I/-v` surface is incomplete.
- `capture-pane` lacks mode/pending capture and tmux-grade
  escape/input handling.
- `set-buffer -w`/`load-buffer -w` clipboard export does not
  render tmux's `Ms` capability template.
- Several commands reject flags (`-a`, `-b`) that tmux supports,
  pending grouped-session/shuffle/layout infrastructure.

## Layout

- Layout uses transient geometry reconstruction, not persistent
  `layout_root`/`layout_cell` ownership.
- `layout_split_pane`, `layout_close_pane`,
  `layout_new_pane_size` are stubs.
- Multi-pane zoom, mouse-border resize, and layout-cell redraw
  semantics are absent.

## Status and Prompt

- Status row caching, multiline status, and the full
  per-pane/status/overlay redraw matrix are incomplete.
- Prompt mouse consumers are missing.
- `display-menu` and completion popup depend on unported menu
  infrastructure.

## Miscellaneous

- `check_window_name` is a stub (timer/event/redraw/status-update
  pieces belong on top of a real runtime).
- `colour.zig` lacks the full X11 colour-name table.
- `style.zig` skips dynamic `#{...}` expansion and style-range
  consumers.
- `key-bindings.zig` defers broader default tables, repeat timing,
  and richer dispatch semantics.
- Pane output uses synchronous writes, not tmux's bufferevent
  runtime.
- Lock/unlock uses `client_leave_attached_mode`/
  `client_enter_attached_mode` instead of capability-driven lock
  handoff.
- `tty-acs.zig` leftover `Tty.acs`/`u8_cap_present`/`u8_cap`
  fields should fold under `tty-term` ownership.

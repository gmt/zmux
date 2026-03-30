# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.
Each item describes what zmux does and what blocks completion.

## Grid and Screen

- Scrollback storage uses visible-rows-first ordering instead of
  tmux's history-first layout.

## Input Parser

- Request/reply machinery (DA, clipboard, colour, palette) requires
  a PTY write-back path.
- Ground timer requires libevent `evtimer` or Zig async timer.
- Theme reporting requires PTY write-back plus
  `window_pane_get_theme`.

## TTY

- `tty.c` request/buffer/query/path machinery is absent.
- Local raw-mode/alternate-screen takeover is split into
  `client.zig` instead of being capability-driven from `tty.zig`.
- `tty_block_maybe` (output throttling), `tty_window_bigger`
  (client-vs-window size), `tty_set_client_cb`/`tty_client_ready`
  (per-client dispatch), and `tty_cmd_sixelimage` are stubs pending
  their respective runtime infrastructure.

## Format

- `client_written`, `pane_format`, `session_format`,
  `window_format` return placeholder values because the backing
  state fields do not exist yet.
- `sixel_support` returns `"0"` because zmux does not implement
  sixel graphics.
- The formatter lacks jobs, pane-search `C`, and the broader DSL.

## Server-Client

- Overlay open/clear paths still do not refresh pane focus state via
  `window_update_focus`.
- Status line range queries for mouse-on-status classification use
  a simplified area test; `status_get_range` is not available.
- Pane buffer management operates on `input_pending` instead of
  libevent bufferevents; backpressure is not wired.

## Window Copy Mode

- 14 functions blocked on specific infrastructure:
  - Format callbacks need `format_get_pane`
  - Regex search needs POSIX `regex_t` bridge
  - Search mark management needs `searchmark[]` in `CopyModeData`

## Window Modes

### window-customize (14 stubs)
- `draw`, `draw_key`, `draw_option` — rendering customize items
- `build_keys` — building key-binding items
- `destroy`, `free_callback` — cleanup with command state
- `set_command_callback`, `set_note_callback` — prompt callbacks
- `set_key`, `unset_key`, `reset_key` — key-binding editing
- `change_each`, `change_current_callback`,
  `change_tagged_callback` — bulk change operations
All blocked on mode-tree `runCommand` and prompt infrastructure.

### window-tree (8 stubs)
- `swap`, `destroy` — tree operations
- `command_done`, `command_callback`, `command_free` — command
  dispatch within tree mode
- `kill_each`, `kill_current_callback`, `kill_tagged_callback` —
  kill operations
Blocked on mode-tree `runCommand` and window/session destruction
hooks.

## Popup

- `popup_draw_cb` — drawing popup content to the overlay
- `popup_free_cb` — cleanup with job state
- `popup_make_pane` — creating a PTY-backed popup pane
- `popup_menu_done` — menu completion within popup
- `popup_job_update_cb`/`popup_job_complete_cb` — job lifecycle
- `popup_editor` — editor popup
All blocked on live PTY-backed popup job runtime.

## Control Mode

- `control_read_callback` requires libevent bufferevent read
  integration.
- Timer-driven subscription polling path is a thin wrapper.

## File I/O

- Detached-client file transport is message-driven, but the remaining
  lifecycle still uses synchronous local reads instead of tmux's
  bufferevent runtime.

## Job Runtime

- `job.zig` uses a thread/pipe bridge instead of tmux's shared
  bufferevent-backed `job.c` runtime.

## Commands

- `display-panes` paints text badges instead of large digit art.
- `display-popup` still rejects environment overlays, close-on-exit,
  argv-vector forms, and interactive popup shell paths.
- `set-buffer -w`/`load-buffer -w` does not render `Ms` template.
- Several commands reject flags pending layout infrastructure.

## Layout

- Transient geometry reconstruction, not persistent ownership.
- `layout_split_pane`, `layout_close_pane`,
  `layout_new_pane_size` are stubs.
- Multi-pane zoom and layout-cell redraw are absent.

## Status and Prompt

- Status row caching and multiline status are incomplete.
- Prompt mouse consumers are missing.
- Menu infrastructure is not ported.

## Miscellaneous

- `check_window_name` stub (needs runtime).
- `colour.zig` lacks X11 colour-name table.
- `style.zig` skips `#{...}` expansion and style-range consumers.
- Pane output uses synchronous writes.
- Lock/unlock uses local mode swap instead of capability-driven
  handoff.
- `tty-acs.zig` leftover fields should fold under `tty-term`.

## Window Pane I/O

- `window_pane_input_callback` and `window_pane_read_callback`
  require libevent bufferevent integration for PTY I/O.

# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.
Each item describes what tmux does and what zmux lacks.

## Input Parser

zmux uses a simplified sequential parser (switch-on-byte) rather than
tmux's full VT100 state machine (17 named states with transition
tables). The reduced parser handles the common CSI, OSC, DCS, and ESC
sequences but has these gaps:

- DA/colour/clipboard reply machinery: `input_reply` writes to the pane
  pty fd. DA1/DA2 CSI queries are consumed silently (no reply); theme
  report (`CSI ? 996 n`) is likewise silently consumed.
- DCS DECRQSS replies with cursor-style via `input_replyf`; other DECRQSS
  subcommands return DCS 0 $ r ST.
- Sixel image data inside DCS is consumed silently; tmux parses it
  into an `image` object and renders via `tty_cmd_sixelimage`.
- OSC 4 query (`?`) replies are sent directly to pane fd when the palette
  entry is already cached; the request-queue path (INPUT_REQUEST_PALETTE)
  for forwarding to the outer terminal is not yet implemented.
- OSC 52 query with `get-clipboard=2` (async clipboard request) is not
  yet implemented.
- Ground timer requires libevent `evtimer` or Zig async timer.

### Zig vs. C note

tmux's `input.c` parser is a table-driven state machine generated
partly from the VT100 spec. zmux reimplements the same dispatch with
if-chains and switch statements, which is adequate for correctness but
means adding a new state (e.g., PM string handling) is a manual edit
rather than a table entry.

## TTY

- `tty_block_maybe` (output throttling based on evbuffer watermarks)
  returns 0; tmux blocks output when the client evbuffer is too full.
- `tty_window_bigger` / `tty_window_offset` (client-vs-window size
  comparisons for offset rendering) return 0; the "bigger window"
  code path is dead.
- `tty_set_client_cb` / `tty_client_ready` (per-client dispatch
  callbacks) return 0; needed for multi-client overlay rendering.
- `tty_cmd_sixelimage` is a no-op; requires image/sixel runtime.
- `tty_send_requests` and `tty_repeat_requests` are implemented and
  send DA1/DA2/XTVERSION queries and FG/BG colour queries to
  VT100-like terminals.  The start timer fires after `TTY_QUERY_TIMEOUT`
  seconds and calls `tty_send_requests`.
- Local raw-mode/alternate-screen takeover lives in `client.zig`
  rather than being capability-driven from `tty.zig`.

## TTY Keys (tty-keys.c -- no zmux equivalent)

tmux's `tty-keys.c` (1800 lines) is entirely absent from zmux. It
provides:

- A ternary search tree built from terminfo key definitions and a
  large table of raw escape sequences (numeric keypad, rxvt/xterm
  arrows, function keys, etc.).
- `tty_keys_next`: the server-side input decoder that reads bytes from
  a client fd, matches against the key tree with ambiguity timers, and
  produces key codes. This is the bridge between raw terminal input
  and tmux's key binding system.
- Extended key parsing: CSI u (kitty), xterm modifyOtherKeys.
- Mouse protocol parsing (`tty_keys_mouse`).
- Clipboard paste detection (`tty_keys_clipboard`).
- Device attribute response parsing (DA1, DA2, XDA, XTVERSION).
- Palette colour response parsing.

zmux's `input-keys.zig` handles key encoding (key code to escape
sequence) and decodes some input sequences, but the full server-side
key input tree from `tty-keys.c` is missing. Without it, the server
cannot properly decode all terminal input from attached clients.

## Screen Redraw (screen-redraw.c -- partial port in src/screen-redraw.zig)

`src/screen-redraw.zig` ports the structural skeleton of tmux's
`screen-redraw.c`.  Core border geometry (`ScreenRedrawCtx`,
`screen_redraw_set_context`, `screen_redraw_pane_border`,
`screen_redraw_cell_border`, `screen_redraw_type_of_cell`,
`screen_redraw_check_cell`, `screen_redraw_check_is`),
border glyph selection for all six styles (`screen_redraw_border_set`),
border arrow indicators, and scrollbar slider geometry are in place.

Remaining gaps that need porting dependencies:

- `screen_redraw_make_pane_status` / `screen_redraw_draw_pane_status`:
  require the format system (`format_create`, `format_expand_time`,
  `format_draw`) and `status_screen` / `status_size` fields on
  `WindowPane`, none of which are ported yet.
- `screen_redraw_screen` / `screen_redraw_pane` orchestration:
  the logical flow is present, but the actual draw calls delegate to
  the zmux payload path (`tty_draw_*`); full ctx-based tty drawing
  (tty_cell, tty_cursor, tty_puts, tty_draw_line) is not wired.
- Bidi isolate handling for horizontal borders requires
  `tty_term_has(tty->term, TTYC_BIDI)`.
- `window_copy_get_current_offset` for accurate scrollbar slider
  position in copy mode.

## Image and Sixel

`src/image.zig` and `src/image-sixel.zig` provide the core image layer.
Remaining wiring gaps:

- `tty_cmd_sixelimage` is a no-op; needs to call `image_store` and
  emit the sixel DCS to the outer tty.
- `screen_write_sixelimage` in `screen-write.zig` needs to call
  `image_store` when writing sixel data into a screen.
- `tty_draw_images` in `tty-draw.zig` needs to iterate `s.images` and
  write the sixel data for each image to the outer tty.
- `sixel_support` format variable still returns "0"; needs to check
  the tty feature flag and return "1" when supported.
- `sixel_to_screen` (fallback cell grid for non-sixel tty) is not yet
  ported; requires `screen_write_box` wiring.

## Format

- Format callbacks (`format_cb_*`) that tmux lazily evaluates are
  handled as direct resolver functions in `format-resolve.zig`. Most
  variable names resolve, but several return placeholder values because
  the backing runtime state does not exist: `client_written`,
  `sixel_support` (always "0").
- `format_job_get` (run a shell command inside `#{...}` and cache its
  output) is not implemented. tmux maintains a `format_job_tree` for
  this.
- The format DSL's conditional `?` operator, string comparison `==`,
  matching `m` and `C` (pane search), and substitution `s` modifiers
  work, but the `l` (literal), `E` (expand), and loop modifiers have
  reduced coverage.
- `format_defaults` / `format_defaults_pane` / `format_create` use a
  struct-based context rather than tmux's RB-tree of key-value pairs.
  `format_add` (arbitrary key insertion via `FormatExtras`) is wired;
  window-copy mode populates its format variables through
  `window_copy_formats`.

### Zig vs. C note

tmux's format system uses an RB-tree of string key-value pairs with
lazy callback evaluation. zmux uses a static resolver table with
direct struct field access plus a `FormatExtras` hash map for
dynamic keys. Copy-mode variables are evaluated eagerly in
`window_copy_formats` rather than via lazy callbacks.

## Server-Client

- Overlay open/clear paths do not call `window_update_focus`. The
  function exists in `window.zig` but the server-client overlay
  lifecycle does not invoke it (marked TODO in source).
- `server_client_check_modes` is a stub; does not invoke mode update
  callbacks on status redraw.
- Pane buffer management uses `input_pending` (ArrayList) instead of
  libevent bufferevents; backpressure is not wired.

## Window Copy Mode

- `window_copy_cursor_hyperlink_cb` is wired but `format_add_cb` is
  not implemented; the copy-mode format variables are populated eagerly
  in `window_copy_formats` instead.
- Regex search (`window_copy_search_lr_regex`,
  `window_copy_search_rl_regex`, `window_copy_search_back_overlap`,
  `window_copy_last_regex`) is wired via the `zmux-regex.c` bridge;
  `window_copy_search_jump` still falls back to plain search for the
  regex path.

## Window Modes

### window-customize

Implemented: `draw`, `draw_key`, `draw_option`, `build_keys`,
`destroy`, `free_callback`, `set_command_callback`,
`set_note_callback`, `set_key`, `unset_key`, `reset_key`,
`change_each`, `change_current_callback`, `change_tagged_callback`.

Remaining: `screen_write_text` is a stub so draw preview panes
produce no output; `cmdListToString` omits command arguments
(requires `cmd_list_print` which is not yet ported).

### window-tree (8 stubs)

- `swap`, `destroy` -- tree operations
- `command_done`, `command_callback`, `command_free` -- command
  dispatch within tree mode
- `kill_each`, `kill_current_callback`, `kill_tagged_callback` --
  kill operations

Blocked on mode-tree `runCommand` and window/session destruction
hooks.

### mode-tree shared infrastructure

All five items below are implemented as of T3-U9:

- `runCommand`: wired to `cmd_parse_from_string` + `cmdq_append`.
- `displayMenu`: wired to `menu_display` with `ChoiceCb` callback.
- `displayHelp`: wired to `popup_display` + `popup_write`.
- `searchCallback`: wired to `status_prompt_set` with search input/free callbacks.
- `filterCallback`: wired to `status_prompt_set` with filter input/free callbacks.

## Popup

- `popup_draw_cb` -- drawing popup content to the overlay. The
  function exists but is a no-op; popup content rendering through the
  tty pipeline is not ported.
- `popup_free_cb` -- cleanup with job state is a no-op stub.
- `popup_make_pane` -- creating a PTY-backed popup pane (promoting
  popup into a split) needs window/layout infrastructure.
- `popup_menu_done` -- context menu completion within popup.
- `popup_job_update_cb` / `popup_job_complete_cb` -- job lifecycle
  hooks are no-op stubs.
- `popup_editor` -- editor popup (writes to temp file, opens in
  popup, reads back on close) returns -1.

All blocked on live PTY-backed popup job runtime (tmux uses
`job_run` with bufferevents).

## Control Mode

- `control_read_callback` is a stub; tmux reads lines from the
  client bufferevent and dispatches them as commands. zmux handles
  command dispatch through the peer/proc layer instead, but the
  control protocol line-reading path is not exercised.
- Timer-driven subscription polling is a thin wrapper.

## File I/O

- `filePush` does synchronous sends in a loop rather than using
  event-driven retry with `event_once`.
- `filePushCb`, `fileWriteErrorCallback`, `fileReadCallback`,
  `fileReadDoneCallback`, `fileWriteDoneCallback` are stubs that
  log and clean up but do not implement the full libevent bufferevent
  lifecycle.

## Job Runtime

- `job.zig` uses a thread/pipe bridge (`AsyncShell`) instead of
  tmux's shared bufferevent-backed `job.c` runtime. The thread
  approach works for command execution but does not integrate with
  the libevent loop for job resize, output streaming, or
  popup-backed jobs.

## Commands

### detach-client / suspend-client (cmd-detach-client.c -- no zmux equivalent)

tmux's `cmd-detach-client.c` is not ported. It provides:

- `detach-client` with `-a` (detach all other clients), `-P` (kill
  on detach), `-E` (exec shell command after detach), and `-s`
  (detach from specific session).
- `suspend-client` (send SIGTSTP to the client process).

### display-panes

- Paints text badges instead of tmux's large digit art overlays.

### display-popup

- Environment overlays, close-on-exit flag, argv-vector forms, and
  interactive popup shell paths are rejected.

### buffer commands

- `set-buffer -w` / `load-buffer -w` does not render the `Ms`
  (modified selection) escape template.

### Other command gaps

- Several commands reject flags pending layout infrastructure
  (e.g., `split-window` cannot perform actual layout splits because
  `layout_split_pane` returns null).

## Layout

- `layout_split_pane` returns null (always fails). tmux's
  implementation creates a new layout cell, resizes siblings, and
  returns the cell for the new pane.
- `layout_new_pane_size` returns `PANE_MINIMUM` unconditionally
  instead of computing the available size.
- `layout_set_size_check` returns true unconditionally.
- Layout preset functions (even-h, even-v, main-h, main-v, tiled)
  are implemented in `layout.zig`.
- `layout_close_pane` and `layout_init` are implemented.
- `parse_window` (layout-custom string parsing) is implemented.
- Multi-pane zoom toggle and layout-cell selective redraw are absent.

### Zig vs. C note

zmux uses a transient `Builder` that reconstructs the layout tree
from pane geometry on each operation, then applies changes back.
tmux maintains a persistent `layout_cell` tree. The zmux approach
avoids ownership complexity but means the tree is not available
between operations for incremental updates.

## Status and Prompt

- Status row caching is implemented (cached expanded strings with
  invalidation).
- Multiline status (up to STATUS_LINES_LIMIT = 5) is structurally
  supported.
- `status_get_range` is implemented for mouse hit-testing.
- Prompt mouse consumers (click-to-position cursor in the prompt
  input line) are missing.
- Context menus triggered from status-line ranges work for basic
  cases but full menu infrastructure (nested menus, dynamic menu
  generation from format strings) is incomplete.

## Colour

- The X11 colour-name table has 20 entries; tmux has ~560. Colours
  like "DarkGoldenrod", "LightSteelBlue", "MediumOrchid1", etc.
  are not recognised.

### Zig vs. C note

zmux uses comptime inline loops over colour-name arrays, making
lookups zero-allocation. Expanding the table is just adding entries.

## Style

- `style.zig` parses style strings including ranges, alignment,
  padding, width, and push/set/pop defaults.
- `#{...}` expansion within style strings (format interpolation
  inside style attribute values) is not performed at parse time;
  callers must pre-expand.

## Miscellaneous

- `colour.zig` X11 table as noted above.
- Pane output uses synchronous writes.
- Lock/unlock uses local mode swap instead of capability-driven
  handoff.
- `server_client_unref` is a stub (logs only).

## Window Pane I/O

- `window_pane_set_event` is a stub (zmux uses `pane-io.zig`).
- `window_pane_start_input` is a stub.
- `window_pane_get_new_data` / `window_pane_update_used_data` are
  stubs; zmux uses `input_pending` ArrayList directly.
- `window_pane_input_callback` and `window_pane_read_callback`
  require libevent bufferevent integration for PTY I/O.
- `window_pane_error_callback` is a stub.

## Grid and Screen

- Grid storage uses visible-rows-first ordering: visible rows occupy
  indices 0..sy-1 and history rows are appended after. tmux uses
  history-first: history rows are at the start and visible rows
  follow. This difference is handled by `absolute_row_to_storage`
  but callers must be aware of the mapping.

## Command Parser

- zmux's `cmd_parse_from_string` handles semicolon-separated command
  lists and quoted strings. tmux's `cmd-parse.y` is a full yacc
  grammar supporting `if` / `%if` conditionals, `{` `}` command
  blocks, `%hidden`, `%begin`/`%end` blocks, `~` home expansion,
  and format expansion within command arguments. The zmux parser
  does not support these constructs.

### Zig vs. C note

tmux generates its command parser with yacc. zmux uses hand-written
Zig parsing, which avoids the yacc dependency but limits the grammar
to simple semicolon-split tokenisation.

## Screen Write

- `screen_write.newline` unconditionally sets `cx = 0` (carriage
  return). tmux's `screen_write_linefeed` only moves the cursor
  down without changing the column. The CR should only occur when
  `MODE_CRLF` is set, which the caller (`handle_plain_control`)
  already handles before calling `newline`. LF, VT, and FF
  without `MODE_CRLF` currently move the cursor to column 0,
  unlike tmux where they stay in the current column.

## Control Mode Notifications

- Control-mode `%pane-mode-changed`, `%sessions-changed`, and
  similar notifications are delivered via `notify_add` →
  `cmdq_append_item` callbacks. The notification is only flushed
  to the client socket when `cmdq_next` processes the callback.
  tmux dispatches these synchronously in the event loop. The
  async delivery means control clients may see notifications
  delayed until the next queue drain.
- Tests that read control notifications from a socket pair must
  call `cmdq_next` before the blocking `imsgbuf_read` so the
  notification callback fires and flushes data to the socket.
  The `imsgbuf_read` call has no timeout and will hang the
  entire test suite if the message is not delivered.

## Test Infrastructure

- Many tests create sessions, windows, and clients using global
  state (`global_options`, `global_s_options`, `global_environ`)
  without draining the server command queue. Notification
  callbacks queued by one test reference sessions that subsequent
  tests free, causing alignment panics in the options hash map.
  Tests that create sessions or call `cmdq_next` must call
  `cmdq_reset_for_tests()` at entry and in a `defer` at exit.

- `window_pane_destroy` must null `wp.screen.saved_grid` before
  freeing the alternate screen to prevent double-free of the base
  grid (the alternate screen's `saved_grid` points to
  `wp.base.grid`).

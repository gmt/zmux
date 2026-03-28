# zmux Architecture

This file is the canonical architecture note for the current port. It names
the stack shape we want, the seams that are already shared, and the seams that
still stay intentionally reduced.

it disagrees with this file, this file wins.

This note stays compact on purpose. If a topic needs more than a small current-
state summary, add a separate focused doc under `docs/` instead of growing this
file into a planner blob.

## Truth Split

- `tmux` is the behavioral oracle. Read the C when behavior is
  unclear.
- this file decides where ported behavior should live in the Zig stack

## Identity And Independence

- tmux is tmux. It does things called tmux.
- zmux is zmux. It does things called zmux.
- zmux is a clone of tmux, but it is meant to be independent and distinct.
- it should be possible to nest tmux inside zmux and zmux inside tmux.
- that should come from each program behaving like itself, not from bespoke
  cross-tool awareness.
- when choosing names, messages, environment variables, and user-visible
  behavior in zmux, prefer `zmux` names unless the text is explicitly about
  tmux itself.
- tmux should not be modeled as explicitly aware of zmux; because zmux is
  unreleased, there is no way for tmux to know anything about zmux anyway.

## Stack Shape

### Text And Cells

- `src/types.zig`, `src/utf8.zig`, and `src/utf8-combined.zig` own UTF-8
  payloads, decode helpers, width policy, and combine policy
- `src/tty-acs.zig` owns the reduced ACS-versus-UTF-8 drawing policy seam
- `src/grid.zig` owns stored `GridCell` payloads and the reduced
  `string_cells` render seam for capture-style consumers
- `src/screen-write.zig` owns shared glyph and cell writes into the live grid

### Prompt, Status, And Message Consumers

- `src/status-prompt.zig` uses the shared cell model for prompt storage and
  editing
- `src/format-draw.zig`, `src/status.zig`, `src/status-runtime.zig`, and
  `src/menu.zig` own the reduced shared status, message, and menu-overlay
  presentation path
- `src/server-print.zig` and `src/cmd-queue.zig` route attached, detached, and
  control-client output through shared lower seams instead of command-local
  writers
- `src/control.zig`, `src/control-notify.zig`, and
  `src/control-subscriptions.zig` own the reduced control-client pane-offset
  bookkeeping, notify, and `%subscription-changed` polling path

### Mouse, Redraw, And TTY Runtime

- `src/window.zig`, `src/mouse-runtime.zig`, `src/server-fn.zig`, and
  `src/tty-draw.zig` own the reduced pane hit-test, redraw, border, and
  scrollbar seams
- `src/tty-term.zig`, `src/tty-features.zig`, and `src/tty.zig` own the
  reduced terminfo and outer-tty capability path

### Layout And Geometry

- `src/layout.zig` owns the reduced geometry-tree reconstruction and
  layout-dependent pane-resize seam used by `resize-pane`
- future intent is to replace that transient reconstruction with persistent
  layout ownership as more split, destroy, and layout-aware consumers land

### Async Job Runtime

- `src/job.zig` owns the reduced shared job registry, summary fields, shell
  launcher, and async completion bridge
- `src/cmd-run-shell.zig` and `src/cmd-if-shell.zig` consume that shared job
  seam instead of keeping private launch loops
- `src/cmd-show-messages.zig` uses the shared job summary seam for `-J`
- `src/server.zig` routes shared async job child-exit status through
  `job_check_died`

## Current Open Seams

### UTF-8 And Display

- the live writer is still reduced relative to tmux `screen_write_cell`
- broader prompt, search, edit, and reader consumers still do not all operate
  on the same shared display-cell model
- the reopen gate is consumer adoption plus fuller writer side effects, not
  more local UTF-8 helpers

### Status And Runtime

- multiline status and message presentation remains reduced
- the redraw matrix is still much smaller than tmux's pane, border, status, and
  overlay runtime
- shared status and message producers exist, but producer coverage is still
  incomplete

### Jobs And Files

- the shared job layer is still reduced relative to tmux `job.c`
- output capture uses a thread-backed reader plus wakeup, not tmux's
  bufferevent job runtime
- there is still no shared `file.c`-style print or read runtime under that job
  layer

### TTY And Input

- the tty runtime still exposes only a selected-capability `tty-term` seam
- mouse/runtime coverage is still reduced compared with tmux's fuller attached
  client path
- layout mutation now covers reduced `resize-pane` border motion, but the
  broader persistent layout runtime is still intentionally incomplete

## Rules For New Work

- port honest behavior from tmux before making design claims
- reuse shared lower layers when they already carry truthful semantics
- if a consumer needs missing semantics, extend the shared layer instead of
  adding a local workaround
- do not add new UTF-8, display-width, combine, or rendering hacks outside the
  declared stack
- put ugly-but-ported cleanup in `TODO.md`, not in queue notes or this file

## Queue Pressure

- finish the remaining shared writer and display-consumer adoption work before
  reopening more UTF-8-sensitive command work
- keep message, prompt, and redraw producers moving onto the shared runtime
- grow the job and file runtime only where an active consumer needs a more
  truthful lower seam
- widen tty and mouse runtime beneath the existing shared ownership boundaries
- turn material discoveries into small canonical queue tasks or small topical
  docs, not long planner prose

# zmux Architecture

Canonical architecture note for zmux. Names the stack shape and where
ported behavior lives. Stays compact — topic-specific detail goes in
separate docs under `docs/`.

## Truth Split

- `tmux` is the behavioral oracle. Read the C when behavior is unclear.
- This file decides where ported behavior lives in the Zig stack.

## Identity

- zmux is a feature-compatible clone of tmux, independent and distinct.
- Nesting tmux inside zmux and zmux inside tmux should work by each
  program behaving like itself, not through cross-tool awareness.
- User-visible names, messages, and environment variables use `zmux`.

### Compatibility Mode

When invoked as `tmux` (argv[0] detection), zmux switches all
user-visible names, paths, and environment variables to their tmux
equivalents. Internally it remains zmux — source files, function
names, and types are unchanged. The compat mode affects only the
surfaces a user or external tool would observe.

## Stack Shape

### Text and Cells

- `types.zig`, `utf8.zig`, `utf8-combined.zig` — UTF-8 payloads,
  decode helpers, width policy, combine policy
- `tty-acs.zig` — ACS-versus-UTF-8 drawing policy
- `grid.zig` — stored `GridCell` payloads, `string_cells` for capture
- `screen-write.zig` — glyph and cell writes into the live grid

### Prompt, Status, Message

- `status-prompt.zig` — prompt storage and editing over the cell model
- `format-draw.zig`, `status.zig`, `status-runtime.zig`, `menu.zig` —
  status, message, and menu-overlay presentation
- `server-print.zig`, `cmd-queue.zig` — attached/detached/control
  output routing
- `control.zig`, `control-notify.zig`, `control-subscriptions.zig` —
  control-client pane-offset bookkeeping, notify, subscription polling

### Mouse, Redraw, TTY

- `window.zig`, `mouse-runtime.zig`, `server-fn.zig`, `tty-draw.zig` —
  pane hit-test, redraw, border, scrollbar
- `tty-term.zig`, `tty-features.zig`, `tty.zig` — terminfo and
  outer-tty capability path

### Layout and Geometry

- `layout.zig` — geometry-tree reconstruction, layout-dependent
  pane-resize

### Async Jobs

- `job.zig` — shared job registry, shell launcher, async completion
- `cmd-run-shell.zig`, `cmd-if-shell.zig` — consume the shared job interface
- `cmd-show-messages.zig` — job summary for `-J`
- `server.zig` — routes job child-exit status through `job_check_died`

## Rules

- Port honest behavior from tmux before making design claims.
- Reuse shared lower layers when they carry truthful semantics.
- Extend shared layers for missing semantics instead of adding
  local workarounds.
- UTF-8, display-width, combine, and rendering code stays within
  the declared stack.
- Functional tmux-parity gaps go in `docs/zmux-porting-todo.md`.
- Delete fixed todo entries instead of marking them resolved in place.
- Zig-idiom cleanup and refactor debt go in `docs/zig-porting-debt.md`.

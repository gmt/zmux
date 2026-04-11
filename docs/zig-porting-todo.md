# Zig Porting TODO

Live tmux-parity gaps only.

## Rules

- This file is for functional or capability gaps where zmux does not yet match
  tmux.
- Keep only live entries. When a gap is fixed, delete the entry. Do not leave
  behind `FIXED`, `RESOLVED`, strike-through sections, or historical cemeteries.
- Do not put Zig cleanup, refactors, naming work, type-shape cleanup, or API
  cleanup here. That belongs in `docs/zig-porting-debt.md`.
- Prefer one section per gap with three bullets:
  - `tmux:` what behavior exists upstream
  - `zmux:` what is currently missing or approximate
  - `likely files:` where the repair probably lives

## Chooser Preview And Prompt Flows

- `tmux:` `choose-client`, `choose-tree`, and `find-window` support preview
  panes, preview zoom, richer prompt-driven command and kill flows, mouse
  preview selection, and custom `-K` key-format bindings where tmux provides
  them.
- `zmux:` the chooser family is still on reduced alternate-screen runtimes.
  `choose-client` and `choose-tree` are usable, but the preview and richer
  interaction paths are still missing.
- `likely files:` `src/cmd-choose-tree.zig`, `src/window-client.zig`,
  `src/window-tree.zig`, `src/mode-tree.zig`, `src/window-mode-runtime.zig`,
  `docs/choose-tree-modes.md`

## Popup PTY Runtime

- `tmux:` `display-popup` can host a live PTY-backed job with popup-local
  terminal behavior, resize, mouse, menu, and editor interactions.
- `zmux:` the popup body is still built from captured command output. The live
  PTY-fed terminal path, format-aware coordinates, and the broader popup job
  interaction surface are not there yet.
- `likely files:` `src/popup.zig`, `src/cmd-display-menu.zig`,
  `src/server-client.zig`, `docs/popup-runtime.md`

## Copy-Mode Runtime Parity

- `tmux:` copy mode operates on real pane history with tmux's selection, copy,
  search, mark, drag, resize, mode-local redraw, and clipboard-selection
  behavior.
- `zmux:` the current mode runs on a snapshot-backed screen. Core navigation is
  there, but real history backing and the richer copy/search/selection flows
  are still incomplete, and some less-common commands still fall through to
  the unsupported-command path.
- `likely files:` `src/window-copy.zig`, `src/cmd-copy-mode.zig`,
  `src/screen-write.zig`, `src/server-client.zig`, `docs/window-copy.md`

## Persistent Layout Ownership

- `tmux:` split, destroy, resize, and `select-layout` all share one
  authoritative layout tree, so full-window splits and explicit layout
  application preserve one consistent ownership model.
- `zmux:` target-pane splits work on the current pane geometry, but the broader
  runtime still reconstructs transient layout state from rectangles. That
  leaves `split-window -f` across an existing multi-pane window and the
  `select-layout` explicit-layout path short of full tmux parity.
- `likely files:` `src/window.zig`, `src/layout.zig`,
  `src/cmd-split-window.zig`, `src/cmd-select-layout.zig`,
  `docs/layout-split-pane.md`, `docs/layout-select-layout.md`

## Display-Cell Runtime Adoption

- `tmux:` prompt, status, message, redraw, and related text consumers share one
  display-oriented cell model closely enough that Unicode-sensitive behavior is
  consistent across the UI.
- `zmux:` the lower UTF-8 and cell layers are much better than they were, but
  prompt, status, redraw, and message surfaces still do not all ride one
  end-to-end display-cell model. Remaining parity bugs here are likely to show
  up as width, trimming, or cursor-placement mismatches rather than decode
  failures.
- `likely files:` `src/status-prompt.zig`, `src/status.zig`,
  `src/screen-write.zig`, `src/server-print.zig`, `src/tty-draw.zig`,
  `docs/utf8-display-status.md`

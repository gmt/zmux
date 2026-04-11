# zmux Porting TODO

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

## Persistent Layout Ownership

- `tmux:` split, destroy, resize, and `select-layout` all share one
  authoritative layout tree, so full-window splits and explicit layout
  application preserve one consistent ownership model.
- `zmux:` target-pane splits work on the current pane geometry, but the broader
  runtime still reconstructs transient layout state from rectangles in generic
  dump callers and adjacent geometry helpers. `select-layout` now snapshots
  undo state from `window.layout_root`, and pane destroy plus respawn teardown
  now repair the shared tree before removal. Layout-managed pane detaches now
  also leave the repaired tree geometry alone, and `select-layout -E` now
  prefers the shared tree, but the broader stale-tree fallback surface is still
  short of full tmux parity even though `split-window -f` now rides the shared
  layout tree.
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

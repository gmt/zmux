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

## server-print: attached view-mode print path segfaults

- `tmux:` `server_client_print` and `server_client_close_view_mode` handle
  attached view-mode output without crashing.
- `zmux:` the same code paths produce signal 11 (4 test cases). The shared
  attached/view-mode print path has a use-after-free or null-pointer issue.
- `likely files:` `src/server-print.zig`

## tty-draw: clipped wide-cell padding incorrect

- `tmux:` `tty_draw_render_window_region` correctly clears padding when a
  leading wide cell is clipped at the left edge of a region.
- `zmux:` the clipped leading wide-cell padding is not cleared, causing
  rendering artifacts at region boundaries.
- `likely files:` `src/tty-draw.zig`

## cmd-new-session / cmd-attach-session: attach flow divergence

- `tmux:` `new-session` and `attach-session` handle the full client-attach
  lifecycle including terminal setup, session switching, and notification.
- `zmux:` the attach flow crashes or diverges during terminal setup in certain
  configurations.
- `likely files:` `src/cmd-new-session.zig`, `src/cmd-attach-session.zig`

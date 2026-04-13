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

## Command output bypasses tmux's write-open/write-ready handshake

- `tmux:` commands that print to stdout in the trace sweep (`list-sessions`, `list-panes`, `display-message -p`) send `write_open(303)` and wait for `write_ready(305)` before sending `write(304)` payloads.
- `zmux:` the same commands send `write(304)` directly and never emit the `write_open`/`write_ready` pair, so the client-side file-transfer protocol diverges whenever command output is streamed.
- `likely files:` `src/client.zig`, `src/file-write.zig`, `src/file.zig`


## list-panes default output is still the simplified placeholder format

- `tmux:` `list-panes -t trace-probe` printed `0: [80x24] [history 0/2000, 1575 bytes] %0 (active)` with the usual pane metadata and decorations.
- `zmux:` `list-panes -t trace-probe` printed `0: 80x24 pid=470168`, so the default format is still a simplified placeholder rather than tmux's pane listing.
- `likely files:` `src/cmd-list-panes.zig`, `src/format.zig`

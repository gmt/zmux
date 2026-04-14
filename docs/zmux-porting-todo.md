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

## display-message -p breaks after oh-my-tmux config loading

- `tmux:` `display-message -p` works at all times for detached clients, including after oh-my-tmux config loads
- `zmux:` `display-message -p` works at t=1s after server start, but by t=3s (after oh-my-tmux run-shell commands execute) it returns exit 1 with no output. `show-options` and `show-environment` continue to work — only the `-p` print path is affected
- `likely files:` `src/cmd-display-message.zig`, `src/file-write.zig`, `src/server-print.zig` — something in the run-shell execution or config sourcing path corrupts the detached stdout write channel

## Command-line \; command chaining

- `tmux:` `tmux set X \; set Y` chains two commands on the CLI; the client-side argv parser splits on `\;`
- `zmux:` CLI-side `\;` chaining is not implemented; the shell passes `\;` as `;` to zmux which treats it as a single argument. `source-file` and `bind-key` contexts now handle `\;` correctly, but bare CLI invocations do not.
- `likely files:` `src/zmux.zig` (client-side argv processing)

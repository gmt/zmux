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

## Format expansion in set-option values

- `tmux:` `set -g extended-keys #{?#{||:...},on,off}` expands the format string before validating the option value, so the result is `on` or `off`
- `zmux:` the format string is passed literally as the option value, producing "invalid choice" errors for choice-type options
- `likely files:` `src/cmd-set-option.zig` (option execution), `src/format.zig` (format expansion)

## Command-line \; command chaining

- `tmux:` `tmux set X \; set Y` chains two commands on the CLI; the client-side argv parser splits on `\;`
- `zmux:` CLI-side `\;` chaining is not implemented; the shell passes `\;` as `;` to zmux which treats it as a single argument. `source-file` and `bind-key` contexts now handle `\;` correctly, but bare CLI invocations do not.
- `likely files:` `src/zmux.zig` (client-side argv processing)

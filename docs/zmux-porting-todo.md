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

## bind-key \; command chaining

- `tmux:` `bind r run "..." \; display "..."` chains two commands with `\;`; `cmd_parse_from_argv` splits on `\;` and builds a command list
- `zmux:` `cmd_parse_from_argv` does not split on `\;`, so the entire tail is passed as a single command and fails with "invalid command"
- `likely files:` `src/cmd.zig` (`cmd_parse_from_argv`), `src/cmd-bind-key.zig`

## oh-my-tmux _apply_configuration fails

- `tmux:` oh-my-tmux's embedded `_apply_configuration` shell function uses `$TMUX_PROGRAM` to run a long chain of `set-option`, `bind-key`, and perl-based config rewriting that sets up the themed status bar
- `zmux:` the script runs but produces errors ("not in a mode", perl syntax error) suggesting some commands used by the script are not fully supported or return unexpected output
- `likely files:` multiple — probably needs command-by-command triage of the _apply_configuration output

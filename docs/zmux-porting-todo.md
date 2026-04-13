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

## display-message -l (literal) flag missing from template

- `tmux:` template string is `"aCc:d:lINpt:F:v"` — includes `l` so
  `display-message -l "#{foo}"` prints the literal string without expansion.
- `zmux:` template string is `"ac:d:F:INpPRt:v"` — `l` is absent, so the
  flag is rejected at parse time. The code in `expandMessage` checks
  `args.has('l')` but it can never be true.
- `likely files:` `src/cmd-display-message.zig` line 161 (entry template)

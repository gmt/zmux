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

## oh-my-tmux BEL character leaks into terminal

- `tmux:` `set-titles on` sends OSC 0 (set terminal title) which includes `\x07` (BEL) as the terminator; terminals handle this silently
- `zmux:` the BEL character from the title OSC sequence appears as a visible character in PTY capture tests; may also affect real terminals depending on terminal emulator handling
- `likely files:` `src/tty.zig` (title output), `src/input.zig` (OSC handling)


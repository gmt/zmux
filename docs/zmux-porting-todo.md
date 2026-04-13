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

## utf8 wide-character width returns 1 instead of 2

- `tmux:` CJK characters (e.g., U+4E00 中) and emoji (e.g., U+1F642 🙂) have
  display width 2 per Unicode East Asian Width rules. tmux's utf8 decoder
  returns width 2 for these code points.
- `zmux:` `utf8.zig` width() returns 1 for these code points. This causes
  `format_width`, `format_trim_left`, `format_trim_right`, and `format_draw`
  to produce incorrect results for wide characters.
- `likely files:` `src/utf8.zig` (width calculation), `src/format-draw.zig`
  (consumers of width)


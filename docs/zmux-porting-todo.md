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

## utf8 wide-character width returns 1 instead of 2

- `tmux:` CJK characters (e.g., U+4E00 中) and emoji (e.g., U+1F642 🙂) have
  display width 2 per Unicode East Asian Width rules. tmux's utf8 decoder
  returns width 2 for these code points.
- `zmux:` `utf8.zig` width() returns 1 for these code points. This causes
  `format_width`, `format_trim_left`, `format_trim_right`, and `format_draw`
  to produce incorrect results for wide characters.
- `likely files:` `src/utf8.zig` (width calculation), `src/format-draw.zig`
  (consumers of width)

## server-client: command dispatch not dropped during CLIENT_EXIT shutdown

- `tmux:` when a client is in `CLIENT_EXIT` state, tmux drops incoming command
  messages rather than queuing them. The dispatch table skips command handling
  once the exit flag is set.
- `zmux:` `server_client_dispatch_for_test` (and the production dispatch path)
  still queues command messages even when `CLIENT_EXIT` is set, diverging from
  tmux's shutdown semantics.
- `likely files:` `src/server-client.zig` (dispatch table, CLIENT_EXIT check)

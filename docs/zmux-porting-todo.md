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

## cmd-new-session / cmd-attach-session: attach flow divergence

- `tmux:` `new-session -A` routes through `cmd_attach_session()` directly,
  sharing the full attach lifecycle. `session_create()` stores captured
  termios. First attach sends `READY` only for non-control clients and emits
  `notify_client("client-attached", c)`.
- `zmux:` `new-session -A` uses a separate `attach_existing_session()` helper
  that misses `-E` handling, pane-target attach semantics, nested-session
  guard, and client-attached notification. `session_create()` ignores the
  passed termios (`src/session.zig:271-280`). `server_client_attach()` always
  sends `READY` regardless of client type.
- `likely files:` `src/cmd-new-session.zig` (route `-A` through shared attach),
  `src/session.zig` (preserve termios), `src/server-client.zig` (conditional
  `READY` send)

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

## Client mis-reports clean `kill-server` as crash

- tmux: on `MSG_SHUTDOWN` the client sets `CLIENT_EXIT_SERVER_EXITED`
  ("server exited") and acks the server with `MSG_EXITING` so the server can
  finish its own teardown bookkeeping.
- zmux: on `.shutdown` the client sets `.lost_server` ("server exited
  unexpectedly"), making every `kill-server` look like a crash, and skips the
  `MSG_EXITING` ack entirely.
- likely files: `src/client.zig` (the `.shutdown` arm of `client_dispatch`,
  around line 279).


# zmux Porting Todo

Implementation gaps where zmux behaviour diverges from tmux due to incomplete
porting.  "Porting todo" and "porting bug" are synonymous here: the acceptance
criterion is full parity, so every row in this table represents unfinished work
regardless of current severity.

Append new rows as gaps are discovered.  Do not remove a row until the fix has
landed and been tested.

| Gap | Location | Remediation | Prerequisites |
|-----|----------|-------------|---------------|
| ~~fd-passing / stdin_data ownership gap~~ (RESOLVED) | `client.zig`, `server.zig`, `tty.zig`, protocol | Server now owns the tty fd directly via libevent; `stdin_data` removed; control clients read from `cl.fd`; `PROTOCOL_VERSION=8`; `MSG_RESIZE` empty payload; client thinned to signal shell. | landed and tested |
| resize ioctl test coverage needs a real pty fd | tests around resize handling | Use a real pty fd so `ioctl(TIOCGWINSZ)` is exercised instead of falling back to default geometry. | test harness support |

## Documentation Debt

(No open items.)

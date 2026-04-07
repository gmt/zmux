# zmux Porting Todo

Implementation gaps where zmux behaviour diverges from tmux due to incomplete
porting.  "Porting todo" and "porting bug" are synonymous here: the acceptance
criterion is full parity, so every row in this table represents unfinished work
regardless of current severity.

Append new rows as gaps are discovered.  Do not remove a row until the fix has
landed and been tested.

| Gap | Location | Remediation | Prerequisites |
|-----|----------|-------------|---------------|
| `file_write_callback`, `file_read_callback` and error variants not using libevent bufferevent — zmux does synchronous fd I/O instead; will block on slow writes and miss async read readiness signals; `file.zig:230` explicitly notes the gap | `src/file.zig:530,545,564,589` (`fileWriteErrorCallback`, `fileWriteCallback`, `fileReadErrorCallback`, `fileReadCallback`) | Replace direct `read()`/`write()` with `bufferevent_new()` + `bufferevent_setcb()` wired to the libevent base; mirror `tmux-museum/src/file.c` bufferevent setup | libevent bufferevent layer needs to be integrated into zmux's event loop first |

## Documentation Debt

(No open items.)

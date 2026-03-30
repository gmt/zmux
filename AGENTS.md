Please read COPYING and be sure to add headers to code files as Greg Turner

## tmux-museum/src is pristine

`tmux-museum/src/` is an unmodified copy of the tmux source tree from
https://github.com/tmux/tmux.  It must NEVER be modified:

- Do not run autotools (autogen.sh, configure, make) against it
- Do not generate cscope, tags, or any other artifacts inside it
- Do not add, remove, or edit any files in it
- To update it, replace the entire tree with a fresh `git archive` from upstream

All build activity goes through `tmux-museum/bin/refresh-labs.sh`, which
uses a disposable build source mirror in `tmux-museum/build/src/` for
anything that writes to the source tree.  The pristine `src/` is used only
for reading and cross-referencing.

## Cursor Cloud specific instructions

### Prerequisites

- **Zig ≥ 0.15.0** (installed at `/opt/zig-x86_64-linux-0.15.2/zig`, symlinked to `/usr/local/bin/zig`).
- **C dev headers**: `libevent-dev`, `libncursesw5-dev`, `libsystemd-dev`, `libutempter-dev`.

### ncursesw linker-script workaround

Zig's linker cannot parse the GNU ld linker script at `/usr/lib/x86_64-linux-gnu/libncursesw.so`. The update script replaces it with a symlink to the real ELF shared object (`libncursesw.so.6.4`). Without this, `zig build` fails with `UnexpectedEndOfFile`.

### Build / test / run

| Action | Command |
|--------|---------|
| Build | `zig build` |
| Unit tests | `zig build test` |
| Fast smoke tests | `zig build smoke` |
| Run binary | `./zig-out/bin/zmux -V` |
| Start detached session | `ZMUX_TMPDIR=/tmp ./zig-out/bin/zmux -L test -f /dev/null new-session -d -s demo` |

See `docs/testing.md` for the full testing lanes.

### Known issues (pre-existing, not environment)

- `zig build test` has 3 compilation errors from Zig 0.15 stdlib API changes (`.init()`, `.writer()`, pointer/value mismatch). These are in the source code, not the environment.
- `zig build smoke` shows 6 PASS / 10 FAIL — the failures are WIP port gaps, not environment issues.
- `kill-server` may hang; use socket cleanup or `kill` by PID if needed.

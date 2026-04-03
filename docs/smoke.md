BSD 3-Clause documentation note: this file follows the repository guidance in
`COPYING`/`LICENSE` for non-generated text.

# zmux Smoke Skill

This document describes an LLM-assisted smoke-test skill for `zmux`. The agent
should treat `/usr/bin/tmux` as the oracle, `zig-out/bin/zmux` as the port
under test, and keep the distinction explicit in every transcript, screenshot,
and verdict.

## Goal

Prove that `zmux` is not only non-crashing, but also usable:

- core tmux/zmux commands execute without hanging
- attached-client flows work from outside the session and from a real client
- shared sessions behave sensibly
- screen updates stay sane under resize, ANSI color, alternate-screen, and
  animation-heavy workloads
- keybindings and mouse interactions do what an operator expects
- attach/detach/exit do not corrupt the terminal or spew garbage to stderr

## Automated First Pass

Run the automated suites before any manual inspection:

```sh
zig build smoke
zig build smoke-oracle
zig build smoke-recursive-attach
zig build smoke-soak
zig build smoke-docker
```

Use `/tmp` for ephemeral sockets and stress artifacts by default.

If any automated suite fails, stop and inspect that failure before manual smoke.
Manual validation is not a substitute for a deterministic breakage.

`zig build smoke-recursive-attach` is a separate characterization suite for
nested recursive attach weirdness. It is intentionally opt-in and not part of
`smoke-all`: use it when working on client/attach semantics or when you need to
reproduce tmux-versus-zmux behavior under nested mux containers.

## Manual Skill Workflow

1. Build `zmux` and confirm the oracle version:

```sh
zig build
/usr/bin/tmux -V
./zig-out/bin/zmux -V
```

2. Start one oracle session and one zmux session with isolated sockets and
   empty configs:

```sh
TMUX_TMPDIR=/tmp /usr/bin/tmux -L oracle -f /dev/null new-session -s smoke
ZMUX_TMPDIR=/tmp ./zig-out/bin/zmux -L zmux-smoke -f /dev/null new-session -s smoke
```

3. Use the oracle first, then repeat the same interaction in zmux. Capture:

- a terminal transcript with `script`
- screenshots when display corruption is suspected
- stderr from the client process
- any unusual pauses, redraw glitches, or stuck input states

4. Keep one extra terminal ready for recovery commands:

```sh
/usr/bin/tmux -L oracle kill-server
./zig-out/bin/zmux -L zmux-smoke kill-server
reset
stty sane
```

## Manual Scenarios

Run these in both oracle tmux and zmux unless the command is still unsupported
in zmux. Unsupported items should be recorded as gaps, not silent skips.

### Keybindings

- prefix handling: `Ctrl-b`, repeated prefix use, and accidental double-prefix
- window creation, selection, previous/next window, and detach
- copy-mode entry/exit if supported
- nested session behavior: launch tmux inside tmux and confirm the outer session
  still behaves normally after the inner client exits

### Mouse

- enable mouse, then test pane selection, window selection, scrolling, and drag
- verify clicks do not leak raw escape sequences into the shell
- detach and reattach after mouse activity to ensure no stuck mode remains

### ANSI And Rendering

- 8-color, 256-color, and truecolor gradients
- alternate screen programs such as `less`, `vim`, or `htop`
- cursor movement and full-screen redraws
- box-drawing/line-drawing characters
- fast-changing output such as `watch`, shell loops, or the soak fixtures
- `cacademo` and other animated pane content when full tmux pane support exists

### Shared Sessions

- attach two viewers to the same session
- create and select windows from one client while watching the other update
- resize clients differently and confirm neither viewer gets wedged
- detach one client, then exit the other, and verify the session/server state is
  still sensible

### Exit And TTY Health

- exit from pane shell
- detach and reattach repeatedly
- kill the session and kill the server
- after each path, confirm:
  - prompt echo is normal
  - backspace works
  - no bracketed-paste residue remains
  - `stty -a` looks sane
  - stderr stayed quiet

## Pass/Fail Heuristics

Fail the smoke if any of these happen:

- the client or server hangs
- visible redraw corruption persists after a normal refresh
- keybindings or mouse actions inject raw control sequences into applications
- attach/detach/exit leaves the terminal broken
- stderr shows repeated warnings, protocol noise, or unexpected stack traces
- memory, FD count, or client count grows without settling during soak runs

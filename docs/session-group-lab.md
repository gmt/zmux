# Session Group Trace Lab

This lab is for debugging `regress/session-group-resize.sh` with a repeatable
staircase of experiments. The tooling keeps the primary worktree clean by
using a disposable git worktree plus one artifact root under `/tmp`.

The normal museum policy still applies to the main worktree: do not edit
`tmux-museum/src/` there. The temporary exception for this bug is only inside
the disposable worktree created by the lab.

## Setup

Create the disposable worktree and artifact directories:

```sh
python3 regress/session-group-lab.py setup
python3 regress/session-group-lab.py status
```

Defaults:

- worktree: `../zmux-session-group-lab`
- artifact root: `/tmp/zmux-session-group-lab`

## Driver

The lab uses a dedicated repro driver against an already-running server:

```sh
regress/session-group-drive.sh switch-only --binary ./zig-out/bin/zmux --socket /tmp/example.sock
regress/session-group-drive.sh full --binary ./zig-out/bin/zmux --socket /tmp/example.sock
```

Modes:

- `switch-only`: isolate the second client and the `switch-client -t :=1` path
- `full`: run the complete three-client reproduction used by the smoke test

The driver never starts or kills the server. It assumes the server is already
running on the given socket and fails fast if it is not.

## Phase Ladder

### Phase 1: zmux gdb, no patches

```sh
python3 regress/session-group-lab.py phase1-zmux-gdb --mode switch-only
python3 regress/session-group-lab.py phase1-zmux-gdb --mode switch-only --run
python3 regress/session-group-lab.py drive
```

This builds a debug zmux in the disposable worktree, writes a gdb breakpoint
file, assigns a dedicated socket, and records driver metadata in the artifact
root. `--run` opens gdb on the no-fork server path.

### Phase 2: museum tmux gdb, no patches

```sh
python3 regress/session-group-lab.py phase2-tmux-gdb --mode switch-only
python3 regress/session-group-lab.py phase2-tmux-gdb --mode switch-only --run
python3 regress/session-group-lab.py drive
```

This builds `tmux-museum/out/gdb/tmux` in the disposable worktree and mirrors
the same socket/driver workflow as phase 1.

### Phase 3: signal and exit tracing with strace

```sh
python3 regress/session-group-lab.py phase3-zmux-strace --mode switch-only
python3 regress/session-group-lab.py phase3-zmux-strace --mode switch-only --run
python3 regress/session-group-lab.py drive
```

And the museum mirror:

```sh
python3 regress/session-group-lab.py phase3-tmux-strace --mode switch-only
python3 regress/session-group-lab.py phase3-tmux-strace --mode switch-only --run
python3 regress/session-group-lab.py drive
```

The strace phase follows signals, `kill`, `wait4`, and `exit_group` and stores
the output under `/tmp/zmux-session-group-lab/strace/`.

### Phase 4: temporary zmux patching

```sh
python3 regress/session-group-lab.py phase4-zmux-patch --mode switch-only
python3 regress/session-group-lab.py save-patch --label phase4-zmux
```

Edit only inside the disposable worktree. The phase command prints the
recommended edit scope. Save the patch before tearing the worktree down.

### Phase 5: temporary museum tmux patching

```sh
python3 regress/session-group-lab.py phase5-tmux-patch --mode switch-only
python3 regress/session-group-lab.py save-patch --label phase5-tmux
```

Again: edit only inside the disposable worktree, never in the main worktree.

## Wind-down

For any active phase:

```sh
python3 regress/session-group-lab.py wind-down
```

That sends a best-effort `kill-server` to the current phase socket and clears
the current phase metadata. It does not remove logs or patches.

To preserve any tracked diff from the disposable worktree and remove the
worktree itself:

```sh
python3 regress/session-group-lab.py teardown
```

To also remove the artifact root:

```sh
python3 regress/session-group-lab.py teardown --purge-artifacts
```

`teardown` saves the current tracked diff as a timestamped patch under
`/tmp/zmux-session-group-lab/patches/` before removing the worktree.

## Expected Flow

1. `setup`
2. `phase1-zmux-gdb --run` in one terminal
3. `drive` in another terminal
4. `wind-down`
5. Repeat with phase 2 or phase 3 if the earlier phase did not localize the gap
6. Use phase 4 and phase 5 only after the no-patch phases stop paying rent
7. `teardown` when done

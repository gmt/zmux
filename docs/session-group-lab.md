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
- branch: `lab/zmux-session-group-lab`
- artifact root: `/tmp/zmux-session-group-lab`

`setup` now puts the disposable worktree on a real local branch instead of a
detached `HEAD`. Pass `--branch <name>` if you want a different breadcrumb:

```sh
python3 regress/session-group-lab.py setup --branch lab/session-group-race
```

If you already have an older detached lab worktree, rerunning `setup` will
attach it to the requested branch as long as that worktree is clean.

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

### Crash capture first

```sh
python3 regress/session-group-lab.py capture-crash --mode switch-only --runs 20
python3 regress/session-group-lab.py analyze-crash
```

This is the preferred first move when the bug looks like an intermittent
segfault. `capture-crash` runs the repro at full speed against the lab zmux
binary and writes the latest result under `/tmp/zmux-session-group-lab/crash/`.

Backend selection:

- default: prefer `coredumpctl` when it is available and usable
- fallback: rerun under `gdb --batch` when `coredumpctl` is unavailable

If a crash is captured, `analyze-crash` saves:

- a normalized backtrace
- the first non-runtime application frame
- the immediate caller above it
- any locals/args it can recover from the core
- a suggested replay anchor for paired gdb

If no crash appears within the run budget, `capture-crash` exits nonzero but
still keeps the run logs and manifest for inspection.

### Parallel tmux-vs-zmux gdb

```sh
python3 regress/session-group-lab.py parallel-gdb --mode switch-only
tmux attach-session -t session-group-parallel-gdb
```

To replay from the latest crash analysis instead of the default handoff preset:

```sh
python3 regress/session-group-lab.py parallel-gdb --from-crash
tmux attach-session -t session-group-parallel-gdb
```

To walk farther up the stack manually:

```sh
python3 regress/session-group-lab.py parallel-gdb --from-crash --anchor server_client_set_session
```

This launches a detached outer `tmux` session with two windows:

- `gdb`: left pane runs zmux gdb, right pane runs museum tmux gdb
- `drive`: left pane has the zmux driver command preloaded, right pane has the
  tmux driver command preloaded

The helper prints the exact `runz` and `runt` commands as well, so you can
retype them manually if you want. The drive panes stay idle until you press
Enter. With `--from-crash`, the generated gdb scripts also seed a narrow
replay from the analyzed crash frame/caller instead of the default broad set.

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
the current phase metadata. If `parallel-gdb` is active, it also kills both
servers and the outer `tmux` session. It does not remove logs or patches.
Crash artifacts stay under `/tmp/zmux-session-group-lab/crash/` until teardown
or manual removal.

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
It does not delete the local branch, so you keep a breadcrumb back to the
investigation even after the disposable worktree is gone.

## Expected Flow

1. `setup`
2. `capture-crash --mode switch-only --runs 20`
3. `analyze-crash`
4. `parallel-gdb --from-crash`
5. `tmux attach-session -t session-group-parallel-gdb`
6. `cont` in both gdb panes
7. Press Enter on the preloaded `runz` and `runt` commands in the drive panes
8. If needed, rerun `parallel-gdb --from-crash --anchor <higher-frame>`
9. `wind-down`
10. Repeat with the single-phase gdb/strace lanes if the paired view does not localize the gap
11. Use phase 4 and phase 5 only after the no-patch phases stop paying rent
12. `teardown` when done

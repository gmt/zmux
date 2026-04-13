# Smoke Tests

Smoke tests are end-to-end tests that exercise zmux as a built binary
through its command-line and client/server interfaces. They verify that
core functionality works: session lifecycle, client attach/detach, window
management, control mode, rendering, and clean exit behavior.

All smoke infrastructure lives in `regress/`, but runnable smoke commands now
go through one root timed runner: `regress/test_orchestrator.py`.
`run-all.sh` is only a compatibility shim. The root runner gives every smoke
case its own timer and sandbox under `/tmp/zmux_test_<hex>`, forces `HOME`,
`TMPDIR`, and XDG state into that sandbox, prepends a per-case `bin/` to
`PATH`, and verifies that no net-new `tmux` or `zmux` process survives the
case. The checked-in timeout policy in `regress/test_timeouts.json` is explicit
per case; default family values are only a bootstrap aid for calibration work.

When user namespaces are available, each case runs inside a user+pid namespace
so descendant processes are torn down with the namespace. Otherwise the root
runner falls back to a process-group cleanup path plus explicit `tmux`/`zmux`
reaping.

## Suites

| Command | Suite | What it does |
|---|---|---|
| `zig build smoke` | fast | Quick end-to-end pass against `zig-out/bin/zmux`. Runs ~16 shell tests plus a command sweep and inside-session check. Finishes in under a minute. |
| `zig build smoke-oracle` | oracle | Same command sweep and inside-session tests, but run against `/usr/bin/tmux`. Verifies that the test expectations themselves are correct. |
| `zig build smoke-soak` | soak | Long-running stress-oriented tests against zmux. Checks for resource leaks (memory, FDs, client count) over sustained operation. |
| `zig build smoke-recursive-attach` | recursive | Characterization tests for nested recursive attach behavior. Opt-in; not included in `smoke-all`. Use when working on client/attach semantics. |
| `zig build smoke-docker` | docker | Docker + SSH harness against system tmux. Requires Docker. |
| `zig build smoke-all` | all | Runs fast + oracle + docker suites together. |

The oracle lane uses system tmux when available. If it is missing, the runner
builds and uses `tmux-museum/out/gdb/tmux`.

Oracle-known-bad policy:

- If a smoke case is red against tmux and we do not have a straightforward
  reason that tmux is wrong, the case should demote to a global skip instead of
  remaining permanent red noise.
- Track those exceptions in `docs/zmux-test-exceptions.md`.

## When to use each

- **Dev loop**: `zig build smoke` after any change that touches server, client, or command handling.
- **Pre-merge**: `zig build smoke-all` for broader coverage including oracle comparison.
- **Soak / stability work**: `zig build smoke-soak` when investigating leaks or long-running behavior.
- **Attach/detach work**: `zig build smoke-recursive-attach` for nested mux edge cases.

## Pass / fail

The runner prints one line per case and a final summary. The exit code is
non-zero if any case failed, timed out, hit a cleanup problem, or ended with
another harness error. Output and retained artifacts live in the kept sandbox
for that case.

A test exits 77 to indicate SKIP (missing binary, unsupported feature, or a
documented oracle-known-bad exception).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TEST_ZMUX` | `zig-out/bin/zmux` | Path to the zmux binary under test |
| `TEST_ORACLE_TMUX` | `/usr/bin/tmux` | Path to the oracle tmux binary |
| `SMOKE_ARTIFACT_ROOT` | `/tmp` | Base directory for ephemeral test sockets and logs |
| `ZMUX_TEST_TIMEOUT_MULTIPLIER` | `1.0` | Multiply the checked-in case timers when a slower host needs more slack |
| `SMOKE_CONTAINMENT_BACKEND` | `auto` | Containment backend for `run-contained.py`: `auto`, `systemd`, `disciplined`, `systemd-disciplined`, or `off` |
| `SMOKE_TEST_SHELL` | (system default) | Override the shell used in deterministic-env tests |

## Running tests directly

You can run the compatibility shim with a suite argument:

```
sh regress/run-all.sh fast
sh regress/run-all.sh oracle
sh regress/run-all.sh soak
sh regress/run-all.sh recursive
sh regress/run-all.sh docker
sh regress/run-all.sh all
```

Or call the root runner directly:

```
python3 regress/test_orchestrator.py smoke-fast
python3 regress/test_orchestrator.py smoke-fast --case-filter smoke-shell:session-group-resize
python3 regress/test_orchestrator.py smoke-oracle
```

To regenerate the checked-in case timers from local measurements, use:

```
python3 regress/calibrate_timeouts.py --suite smoke-fast --json-report /tmp/zmux-smoke-fast.json
```

For ad hoc repros outside the root runner, `run-contained.py` is still
available, but it is no longer the normal smoke entrypoint.

For layered gdb/strace work on the grouped-session repro, see
[docs/session-group-lab.md](./session-group-lab.md).

Individual test scripts can be run standalone with `TEST_ZMUX` set:

```
TEST_ZMUX=./zig-out/bin/zmux sh regress/new-session-no-client.sh
```

# Smoke Tests

Smoke tests are end-to-end tests that exercise zmux as a built binary
through its command-line and client/server interfaces. They verify that
core functionality works: session lifecycle, client attach/detach, window
management, control mode, rendering, and clean exit behavior.

All smoke infrastructure lives in `regress/`. The harness (`run-all.sh`)
drives shell-based test scripts and a Python harness (`smoke_harness.py`).

## Suites

| Command | Suite | What it does |
|---|---|---|
| `zig build smoke` | fast | Quick end-to-end pass against `zig-out/bin/zmux`. Runs ~16 shell tests plus a command sweep and inside-session check. Finishes in under a minute. |
| `zig build smoke-oracle` | oracle | Same command sweep and inside-session tests, but run against `/usr/bin/tmux`. Verifies that the test expectations themselves are correct. |
| `zig build smoke-soak` | soak | Long-running stress-oriented tests against zmux. Checks for resource leaks (memory, FDs, client count) over sustained operation. |
| `zig build smoke-recursive-attach` | recursive | Characterization tests for nested recursive attach behavior. Opt-in; not included in `smoke-all`. Use when working on client/attach semantics. |
| `zig build smoke-docker` | docker | Docker + SSH harness against system tmux. Requires Docker. |
| `zig build smoke-all` | all | Runs fast + oracle + docker suites together. |

## When to use each

- **Dev loop**: `zig build smoke` after any change that touches server, client, or command handling.
- **Pre-merge**: `zig build smoke-all` for broader coverage including oracle comparison.
- **Soak / stability work**: `zig build smoke-soak` when investigating leaks or long-running behavior.
- **Attach/detach work**: `zig build smoke-recursive-attach` for nested mux edge cases.

## Pass / fail

The harness prints a summary line: `PASS=N  FAIL=N  SKIP=N`. The exit
code is non-zero if any test failed. Individual test output is captured
to a temp directory under `$SMOKE_ARTIFACT_ROOT` (default `/tmp`) and
printed on failure.

A test exits 77 to indicate SKIP (missing binary, unsupported feature).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TEST_ZMUX` | `zig-out/bin/zmux` | Path to the zmux binary under test |
| `TEST_ORACLE_TMUX` | `/usr/bin/tmux` | Path to the oracle tmux binary |
| `SMOKE_ARTIFACT_ROOT` | `/tmp` | Base directory for ephemeral test sockets and logs |
| `SMOKE_TEST_TIMEOUT` | `20` | Timeout in seconds for individual shell tests |
| `SMOKE_PYTHON_TIMEOUT` | `600` | Timeout in seconds for Python harness tests |
| `SMOKE_DOCKER_TIMEOUT` | `1200` | Timeout in seconds for Docker tests |
| `SMOKE_TEST_SHELL` | (system default) | Override the shell used in deterministic-env tests |

## Running tests directly

You can also run the harness directly with a suite argument:

```
sh regress/run-all.sh fast
sh regress/run-all.sh oracle
sh regress/run-all.sh soak
sh regress/run-all.sh recursive
sh regress/run-all.sh docker
sh regress/run-all.sh all
```

Individual test scripts can be run standalone with `TEST_ZMUX` set:

```
TEST_ZMUX=./zig-out/bin/zmux sh regress/new-session-no-client.sh
```

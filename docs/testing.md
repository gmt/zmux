Testing lanes:

- `python3 regress/test_orchestrator.py <suite>`
  Root timed runner. Every runnable case gets its own timer, sandbox,
  signal handling, cleanup pass, and summary entry. Existing build steps
  and wrapper scripts delegate here.

- `zig build test`
  Fast Zig unit lane for the normal warm-cache developer loop. Runs each
  Zig unit test individually through the root timed runner. This lane should
  not discover stress-only cases just to skip them.

- `zig build test-stress`
  Heavy Zig stress lane for subprocess, pipe/socket transport, and async shell
  tests that are too expensive for the main unit loop. Runs each stress
  test individually through the root timed runner.

- `zig build smoke`
  Fast end-to-end coverage against `zig-out/bin/zmux`. Shell smoke cases,
  sweep commands, and inside-session checks are all timed one by one.

- `zig build smoke-oracle`
  Oracle coverage against system tmux. If system tmux is unavailable, the
  museum build under `tmux-museum/out/gdb/tmux` is used automatically.

- `zig build smoke-soak`
  Heavy end-to-end soak coverage for long-lived or stress-oriented behavior.

- `python3 regress/test-watchdog.py`
  Compatibility wrapper for the timed Zig unit lane. It no longer adds a
  separate timeout layer; it delegates to the root runner and keeps timers
  enabled.

- `zig build test-compile`
  Compile the Zig unit test binary without running it.

- `zig build test-stress-compile`
  Compile the Zig stress test binary without running it.

- `zig build fuzz`
  Build the fuzz targets. They are also built by default as part of `install` so
  the replay lane can run without a feature flag; use `-Dfuzzing=false` to omit
  them when needed.

- `zig build smoke-fuzz`
  Timed corpus replay for each fuzz target and each seed in `fuzz/corpus/`.

Current intent:

- keep warm-cache `zig build test` under 15 seconds
- preserve heavyweight coverage in `test-stress` and soak, not by bloating the
  main unit lane

Exception policy:

- Prefer a failing test to a skip whenever the test expresses product truth.
- Keep skips for lane selection, external prerequisites, or oracle-known-bad
  cases only.
- Track every deliberate exception in `docs/zmux-test-exceptions.md`.

Timeout policy:

- `regress/test_timeouts.json` now carries an explicit timeout for every
  discovered runnable case.
- Ordinary suite runs require that explicit coverage; `--allow-default-timeouts`
  is reserved for calibration and bootstrap work only.
- `python3 regress/calibrate_timeouts.py ...` is the regeneration path for
  the per-case table. It records reports outside the repo and can merge updated
  proposals back into `regress/test_timeouts.json`.

Host capability policy:

- Smoke-family lanes may declare required host capabilities when the harness
  depends on external primitives rather than product behavior.
- The current capability gate is `AF_UNIX`, which tmux and zmux need for their
  local server socket.
- `python3 regress/test_orchestrator.py --af-unix {auto,require,skip}` controls
  whether missing `AF_UNIX` support becomes an environment skip or an immediate
  harness failure.

Namespace note:

- The timed zig-unit and zig-stress lanes launch test cases inside `unshare`
  user and pid namespaces, and now add `--mount-proc` so `/proc` agrees with
  namespace-local PIDs. This keeps tty foreground-process lookups and
  `/proc/<pid>` observations coherent inside the isolated test world.

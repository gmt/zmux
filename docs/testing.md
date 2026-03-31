Testing lanes:

- `zig build test`
  Fast Zig unit lane for the normal warm-cache developer loop. Heavy subprocess,
  transport, and async shell coverage is intentionally excluded.

- `zig build test-stress`
  Heavy Zig stress lane for subprocess, pipe/socket transport, and async shell
  tests that are too expensive for the main unit loop.

- `zig build smoke`
  Fast end-to-end harness against `zig-out/bin/zmux`.

- `zig build smoke-soak`
  Heavy end-to-end soak coverage for long-lived or stress-oriented behavior.

- `python3 regress/test-watchdog.py`
  Wraps `zig build test` with hang detection. Adaptive timeout based on
  historical runtime data (starts at 120s, converges to mean+3sigma after
  5 runs). On hang: escalates SIGINT/SIGTERM/SIGKILL, then does a
  diagnostic re-run to identify the specific hanging test.

- `zig build test-compile`
  Compile unit tests without running. Useful with `test-watchdog.py --direct`.

- `zig build fuzz -Dfuzzing=true`
  Fuzz target build.

Current intent:

- keep warm-cache `zig build test` under 15 seconds
- preserve heavyweight coverage in `test-stress` and soak, not by bloating the
  main unit lane

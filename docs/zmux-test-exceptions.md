# Zmux Test Exceptions

Use this file for deliberate test exceptions only.

- Prefer a failing test to a skip whenever the test expresses product truth.
- Keep skips for lane selection, external prerequisites, or oracle-known-bad cases.
- If a case is red against tmux and we do not have a straightforward reason that tmux is wrong, demote it to `skip-global` until the harness is repaired.

## Registry

| Case or Group | Lanes | Handling | Reason | Retirement path |
| --- | --- | --- | --- | --- |
| `cmd-run-shell` async shell/view-mode tests except `parse captures shell command argument` | `zig-stress` | `stress-only` | These cases exercise subprocess, libevent, delayed queue, and large-output behavior that the warm lane intentionally avoids. | Keep them running in `zig build test-stress`; do not rediscover them in `zig build test`. |
| `cmd-source-file.test.source-file waits for detached client reads and loads remote content` | `zig-stress` | `stress-only` | Uses detached peer read-open/read-done transport and stdin handoff. | Leave in `zig-stress` unless the warm-lane budget is explicitly expanded. |
| `cmd-save-buffer` detached peer transport cases | `zig-stress` | `stress-only` | Covers write-open/write-ready/write-close handshakes and detached/control transport. | Leave in `zig-stress`; keep attached-mode cases in the warm lane. |
| `job` shared-process runtime cases (`job shared shell runner`, `job_free`, `job_kill_all`, `job server reaper async shell`, `job_run streams output via bufferevent`) | `zig-stress` | `stress-only` | These cases depend on live child processes and libevent progress. | Leave in `zig-stress` unless a cheaper deterministic harness is added. |
| `file-write.test.client write handlers open, write, and close files` | `zig-stress` | `stress-only` | Exercises client-side write transport over a live socketpair. | Leave in `zig-stress`. |
| `format-async` shell job cases (`format async shell collects output…`, `…reports slow commands…`, `…completion order…`, `…rapid re-expansion…`, `…refreshes cached output…`, `…caches completed no-output jobs…`) | `zig-stress` | `stress-only` | These cases spawn real child processes via libevent and poll for async completion. | Leave in `zig-stress` unless a deterministic mock harness replaces the live job loop. |
| `cmd-pipe-pane` directionality and lifecycle cases (`pipe direction flags control write routing…`, `pane_pipe_close terminates child…`, `writing to a pipe whose remote end is closed…`, `rapid pipe open and close cycles…`, `pipe read direction feeds child output…`, `pane_pipe_read_ready is harmless when pipe_fd is already closed`) | `zig-stress` | `stress-only` | These cases exercise child-process pipe I/O through pane-io primitives. | Leave in `zig-stress`. |
| `smoke-sweep-oracle:display-menu` | `smoke-oracle` | `oracle-bug` | The tmux oracle control client still exits during the display-menu exercise, so the oracle lane is not a trustworthy baseline for this command today. | Tighten the oracle control-client exercise and restore the case once tmux is green. |
| `smoke-sweep-oracle:show-messages` | `smoke-oracle` | `oracle-bug` | The tmux oracle control client still exits during the show-messages exercise, so the oracle lane is not a trustworthy baseline for this command today. | Tighten the oracle control-client exercise and restore the case once tmux is green. |
| `os.linux.test.linux osdep_get_name and osdep_get_cwd observe pty foreground child` | `zig-unit` | `env-skip` | The test orchestrator runs each zig-unit case inside `unshare --pid --fork` without `--mount-proc`. Inside that namespace `tcgetpgrp` returns namespace-local PIDs but `/proc` still shows host PIDs, so the lookup always fails. The test detects this via `NSpid` in `/proc/self/status` and returns early. The test passes correctly when run directly outside the namespace. | Remove the guard once the orchestrator mounts a private `/proc` in the pid namespace, or once a mock pty harness replaces the live fork. |

## Notes

- This registry is not the place for ordinary zmux failures. Real product bugs should remain red.
- The current goal is that `zig build test` reports no deliberate skips. Lane-only cases should simply not be discovered there.

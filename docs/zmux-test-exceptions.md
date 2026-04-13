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
| `smoke-sweep:attach-session` | `smoke`, `smoke-oracle` | `skip-global` | The oracle control attach still leaves cleanup noise, so it is not a stable baseline today. | Repair the control attach harness and restore the case in both lanes. |
| `smoke-sweep:display-menu` | `smoke`, `smoke-oracle` | `skip-global` | The oracle run exits the control client immediately, so the exercise is not a trustworthy parity check today. | Tighten the control-client exercise and restore the case once tmux is green. |
| `smoke-sweep:display-panes` | `smoke`, `smoke-oracle` | `skip-global` | The oracle run leaks cleanup state during the control exercise. | Repair the control-client exercise and restore the case once tmux is green. |
| `smoke-sweep:show-messages` | `smoke`, `smoke-oracle` | `skip-global` | The oracle run exits the control client immediately, so the exercise is not a trustworthy parity check today. | Tighten the control-client exercise and restore the case once tmux is green. |
| `smoke-recursive:tmux-in-zmux` | `smoke-recursive` | `skip-global` | The tmux recursive attach timeout assumption is not a stable oracle baseline in this environment. | Rework the recursive harness to measure a stable tmux baseline, then restore. |
| `smoke-recursive:tmux-in-tmux` | `smoke-recursive` | `skip-global` | The pure tmux recursive case does not currently validate the timeout expectation. | Rework the recursive harness to measure a stable tmux baseline, then restore. |

| Broad `zig build test -- --test-filter "window"` reruns still pick up 1 pre-existing non-window-suite failure (`tty_draw_render_window_region clears clipped leading wide-cell padding`) | `zig-unit` | `red` | The harness filter matches unrelated suites whose names contain `window`; the new `window-test.zig` coverage passes, but this older failure still keeps the broad selector red. | Fix the underlying tty-draw bug or tighten the campaign rerun selector once that module has a dedicated green lane. |
| `zig build test-stress` during task 19 still reports pre-existing reds outside `cmd-run-shell-stress-test` (`tty-draw` clipped wide cells, `cmd-find_target @ requires a client`, `cmd-new-session`/`cmd-attach-session` attach flows, `cmd-save-buffer` attached view-mode cases, `os.linux` foreground child lookup) | `zig-stress` | `red` | Task 19's new `cmd-run-shell-stress-test` cases pass, but the full stress lane still exposes existing bugs already present elsewhere in the tree. | Fix the listed module bugs; once those pre-existing reds are gone, the task 19 stress additions no longer block a green `zig build test-stress`. |

## Notes

- This registry is not the place for ordinary zmux failures. Real product bugs should remain red.
- The current goal is that `zig build test` reports no deliberate skips. Lane-only cases should simply not be discovered there.

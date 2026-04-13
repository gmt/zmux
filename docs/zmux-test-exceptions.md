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

| `server-print` attached view-mode print cases matched by `zig build test -- --test-filter server` (4 cases, signal 11) | `zig-unit` | `red` | The shared attached/view-mode print path still segfaults in `server_client_print` and `server_client_close_view_mode`, so a broad `server` filter picks up pre-existing crashes outside the new `server-test.zig` suite. | Repair the `server-print` view-mode print path so the broad `server` filter can go green without narrowing the selector. |
| Broad `zig build test -- --test-filter "window"` reruns still pick up 4 pre-existing non-window-suite failures (`tty_draw_render_window_region clears clipped leading wide-cell padding`, `window-copy unknown window-copy commands surface a status message`, `cmd-set-option set-window-option exact matches win over longer prefixed names`, `cmd-respawn-window restarts the only pane in a window`) | `zig-unit` | `red` | The harness filter matches unrelated suites whose names contain `window`; the new `window-test.zig` coverage passes, but these older failures still keep the broad selector red. | Fix the underlying tty-draw, window-copy, cmd-set-option, and cmd-respawn-window bugs or tighten the campaign rerun selector once those modules have dedicated green lanes. |
| `format-async-stress-test.test.format async shell reports slow commands as not ready after one second` | `zig-stress` | `red` | The `#(...)` slow-job path hits a real allocator bug: `format_job_get()` formats `<'cmd' not ready>` with `xm.xasprintf`, then `expand_template()` frees that text with the caller allocator, which segfaults once the timeout branch is exercised. | Return timeout text with the caller allocator (or change `format_job_get()` ownership so every branch uses the same allocator), then rerun `zig build test-stress -- --test-filter format-async`. |
| `zig build test-stress` during task 19 still reports pre-existing reds outside `cmd-run-shell-stress-test` (`grid-test` multibyte cells, `input` incomplete UTF-8, `screen-write` wide glyphs, `tty-draw` clipped wide cells, `utf8` width/sanitize cluster, `window-copy` unknown command signal 11, `cmd-find_target @ requires a client`, `format-draw` wide-character width cases, `cmd-new-session`/`cmd-attach-session` attach flows, `cmd-set-option` pane style validation, `cmd-save-buffer` attached view-mode cases, `cmd-respawn-window` only-pane restart, `server-print` attached view-mode cases, `os.linux` foreground child lookup) | `zig-stress` | `red` | Task 19's new `cmd-run-shell-stress-test` cases pass, but the full stress lane still exposes existing bugs already present elsewhere in the tree. | Fix the listed module bugs; once those pre-existing reds are gone, the task 19 stress additions no longer block a green `zig build test-stress`. |

## Notes

- This registry is not the place for ordinary zmux failures. Real product bugs should remain red.
- The current goal is that `zig build test` reports no deliberate skips. Lane-only cases should simply not be discovered there.

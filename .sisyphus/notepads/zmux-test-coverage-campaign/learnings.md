## 2026-04-05T03:06:24Z Task: initialization
- Prioritize high-value behavioral coverage over vanity line coverage.
- Real source bugs exposed by tests must stay visible; do not skip or hide failing tests.
- Use worktrees for all mutating worker tasks and serialize merges to local `main`.
- Prefer `/goodz/work/agents/zmux` for persistent coordination state.
- Do not use the banned word in artifacts or worker prompts.
- Worktrees are effective for isolating doc changes.
- Cross-linking the tracker to the failure backlog improves visibility of intentional red tests.
- Using a clear append marker in the failure backlog doc makes it sprint-ready.
- Coordination state can live on `/goodz`, but worktrees should use a local filesystem such as `/tmp` to avoid NFS latency.

## 2026-04-12T00:00:00Z Task 5 layout dedicated suite
- tmux `layout_split_pane` keeps the invariant `left_or_top + 1 border + right_or_bottom = parent size`, and `SPAWN_BEFORE` only changes which side receives `size2`.
- tmux `layout_resize_pane_to` computes the sign from whether the resized branch is the last child in the matching ancestor, so a last child shrinks via a positive change applied to the previous sibling edge.
- `layout_spread_cell` is the parity seam behind even-layout behavior in `layout-set.c`; a good source-level check is that sibling widths settle to equal-or-off-by-one values without breaking parent offsets.
- The repo test orchestrator now requires explicit per-case timeouts for new Zig tests, so adding a dedicated suite also means registering new case IDs in `regress/test_timeouts.json`.

## 2026-04-04T00:00:00Z Task 11 control/file coverage map
- `src/control.zig` owns the narrow state seams worth targeting: pane lookup/off/on/pause/continue at `126-132` and `576-605`, output queueing at `244-350`, output escaping at `392-435`, and offset queries at `501-523`.
- The safest existing fixture homes are `src/control-test.zig` for pure control state, `src/file.zig` for local file helpers (`readResolvedPathAlloc` at `699-759`, `sendPeerStream` at `766-819`), `src/small-modules-test.zig` for `file_path.resolve_path`, `file_get_path`, and `shouldUseRemotePathIO` at `33-212`, and `src/server-client-test.zig` for remote file dispatch at `1395-1485`.
- `src/control-file-test.zig` is absent in this checkout, so the lowest-risk reproducer placement is the existing `src/control-test.zig` / `src/file.zig` / `src/server-client-test.zig` trio rather than inventing a new suite file.
- Missing coverage is concentrated in control output encoding/escaping and pane offset state transitions; keep assertions on public flags, offsets, and emitted payload text rather than internal list shape.
- Best focused rerun lane for this slice: `zig build test --summary all -- --test-filter "control_|readResolvedPathAlloc|sendPeerStream|file_path resolve_path|shouldUseRemotePathIO|server_client_dispatch_for_test routes read and read_done through file read pending map"`.

## 2026-04-04T00:00:00Z Task: harness audit before coverage expansion
- `zig build test --summary all` stayed green in a dedicated `/tmp/zmux-task3-fKDk5a` worktree, so the trust issue was isolated to the smoke harness.
- `regress/formatter-smoke.sh` was asserting `list-clients -F` output before any client attached; both `zig-out/bin/zmux` and `/usr/bin/tmux` returned empty output in that state.
- Attaching a temporary control client before the `list-clients` formatter assertion removed the false failure without hiding real product behavior.

## 2026-04-04T00:00:00Z Task: low-level foundation coverage expansion
- `options_scope_from_name` and `options_scope_from_flags` are high-value drift points because their failure mode text changes based on the chosen scope and target presence.
- `proc_event_cb` has important null-dispatch cleanup behavior on EOF and drained bad peers that is easy to miss without direct characterization tests.
- Formatter coverage benefits from checking `N`, `P`, and `L` modifiers together with multibyte width-vs-length behavior, because those paths combine parser branches with runtime context selection.
- `marked_pane.rebind_winlink` is safer to characterize through its public stored state and clear helpers than through `is_marked`, which intentionally revalidates against live session winlink mappings.

## 2026-04-04T00:00:00Z Task: task 4 landing repair
- A clean verification report is not enough for this campaign; the work is only done once the test changes are actually committed and merged onto local `main`.
- Reusing the existing `/tmp/zmux-task4-becvxO` worktree preserved the missing Task 4 edits, so the repair was to verify those edits again and land them properly instead of recreating the slice from scratch.

## 2026-04-04T00:00:00Z Task: task 5 format oracle foundation cases
- The highest-value portable `format-strings.sh` cases for a green foundation slice were plain escapes, conditional branch unescaping, one escaped-comma comparison, and `l:` literal round-trips.
- Porting those cases exposed one shared parser gap: escaped `#,`, `#}`, and `##` pairs were not being skipped consistently by plain template expansion and top-level format scanners.
- Once the scanners treated escaped pairs as literal content, the new upstream-inspired cases passed without needing any runtime-heavy harness setup beyond a copy-mode pane for `pane_in_mode`.

## 2026-04-04T00:00:00Z Task: window/session/layout coverage map
- `src/window.zig` is mostly a state-propagation surface: creation/adoption/removal at `122-265`, active-pane/history handling at `688-711`, resize at `809-848`, zoom at `999-1029`, and winlink lifecycle helpers at `2044-2153`.
- `src/window-test.zig` already covers option refresh, hit testing, active history, detach promotion, client reference cleanup, focus side effects, pane resize, rotation, zoom, split planning, detach-collapse, adopt, and a few direct compare/search cases at `53-659`.
- The highest-value gaps for task 8 are direct `window_resize`/pixel propagation, `window_destroy_all_panes`/`window_lost_pane` state cleanup, session-group-aware attach/detach synchronization, and one focused round-trip for zoomed layout restore semantics.
- `src/session.zig` has the state machinery at `81-223` and `490-618`, with existing coverage for `session_set_current`, `session_repair_current`, `session_alive`, and alert clearing at `858-1124`; the missing behavior is group synchronization around `session_group_add`, `session_group_synchronize_from/to`, and attached-count/last-window invariants.
- `src/layout.zig` already has inline coverage for split/close/size-check/zoom at `2032-2229`; for this slice it mainly serves as the backing layer for window resize and restore behavior, so keep any new assertions focused on public window state rather than internal tree shape unless the reproducer demands it.
- Tracker status guidance: advance the `src/window.zig` row from `unscanned` toward `testing`/`covered` after the slice; leave `src/layout.zig` as-is unless a new gap is found; only move `src/session.zig` if the worker adds direct session-group coverage instead of just using it as support.
- Verification lanes to hand off with the slice: focused rerun `zig test src/window-test.zig`; broad fast lane `./regress/run-all.sh fast`; broader plan lane `zig build test --summary all`.

## 2026-04-04T00:00:00Z Task: input/reply and tty winsz research
- `input_reply()` sends immediately unless `add` is set and `ictx->requests` is non-empty; in that case it creates an `INPUT_REQUEST_QUEUE` item and flushes it later through the request timer path.
- `input_parameter()`, `input_intermediate()`, and `input_input()` all flip `INPUT_DISCARD` on overflow; `input_exit_osc()`, `input_exit_apc()`, and `input_exit_rename()` bail out early when that flag is set.
- `input-buffer-size` is the exposed ceiling for `input_input()` growth; the default is `INPUT_BUF_DEFAULT_SIZE` (1048576), but the option can be lowered for a faster overflow test.
- `tty_keys_winsz()` only accepts replies after `TTY_WINSIZEQUERY` is set, treats `ESC` and `ESC[` as partial, and only clears the query flag after a pixel-size reply (`4;ypixel;xpixel t`) not a character-size reply (`8;rows;cols t`).
- `tty_keys_next()` keeps partial sequences pending behind `escape-time`, and it stretches the wait when active queries or request traffic are in flight.
- Local regress coverage already exercises `escape-time` and meta-key mapping in `src/regress/input-keys.sh`, but not fragmented winsz replies or discard-triggering oversized OSC/APC payloads.

## 2026-04-04T00:00:00Z Task 6 input parsing / reply-buffer map
- `src/input.zig:47-66` is the reply write path. `input_reply` uses a fixed 512-byte stack buffer and silently returns on formatting overflow, so any overlong formatted reply is dropped rather than queued or truncated.
- `src/input.zig:120-153` is the clipboard reply path. It allocates exact size on the heap and writes through `input_send_reply`, so it is not bounded by the 512-byte stack buffer.
- `src/input.zig:200-229` and `232-329` are the only queueing paths in this file. `input_request_timer_cb` and `input_request_reply` both treat `ir.idx` as the byte length for queued payloads and send `bytes[0..idx]` without extra validation.
- `src/input.zig:338-486` is the input accumulation / compaction path. `input_pending` stores unfinished bytes across calls and the parser compacts the remaining tail after each pass.
- `src/input.zig:1817-3183` holds the current focused characterization tests. There is no `src/input-test.zig` file in the repo right now, so the next worker will either extend `src/input.zig` tests or add that dedicated file as the plan requests.
- Existing tests already cover incomplete CSI/UTF-8/OSC/DCS/APC pending behavior and clean consumption of OSC 4/8/10/11/12/52/104/110/111/112/133 plus DCS/APC/SOS cases; the missing gap is specifically overlong reply handling and queue-length edge cases.

## 2026-04-05T00:00:00Z Tasks 8-9: shared state and top-of-stack behavior
- `tmux-museum/src/regress/session-group-resize.sh` is the clearest upstream-style reproducer for Task 8: it proves `window-size=latest` follows the latest attached client size when a grouped session switches to a window, and it exercises both `switch-client` and `selectw` code paths.
- The resize semantics live in `tmux-museum/src/resize.c:resize_window()` and `tmux-museum/src/session.c:session_group_synchronize_from()` / `session_group_synchronize1()`: layout is resized first, then the window, and grouped sessions copy winlinks, current-window position, last-window stack, and alert flags from the source session.
- `session_attach()` and `session_detach()` both call `session_group_synchronize_from()`, so a good Task 8 test should cover attach/detach plus a follow-up assertion that the peer session keeps matching window indices and current/previous state after a link change.
- `tmux-museum/src/tmux.1` says grouped sessions share the same window set while current/previous window state stays independent; `server_link_window()` also rejects linking sessions already in the same group, so a local test should keep that invariant visible rather than smoothing it over.
- For Task 9, the highest-value stack is `spawn.c:spawn_window()` / `spawn_pane()` plus `alerts.c:alerts_queue()` and `alerts_check_session()`: spawn/respawn updates still sync the group, and alerts are queued per window then fanned out to each session/window link.
- `window_update_activity()` queues activity alerts, `input.c` queues bell alerts, and `alerts_check_*()` marks winlinks plus session status messages; a focused pane-runtime test should verify the alert flag reaches the right grouped winlinks instead of only checking a redraw side effect.
- Suggested concrete worker scenarios: (1) grouped sessions plus `window-size=latest` resize immediately after `switch-client` and `selectw`; (2) adding/removing a linked window preserves current-window and last-window state in the peer session; (3) spawn/respawn in a grouped session keeps the new window linked everywhere; (4) activity/bell on one pane marks the corresponding winlink alert state and session alert formatting for every attached session in the group.

## 2026-04-05T00:00:00Z Task 9 upstream pane/runtime research
- Direct source anchors: `tmux-museum/src/spawn.c:spawn_window()` and `spawn_pane()` drive new window/pane creation, respawn, linked-window removal, and the final `session_group_synchronize_from(s)` call; the command wrappers are `cmd-new-window.c`, `cmd-split-window.c`, `cmd-respawn-window.c`, and `cmd-respawn-pane.c`.
- `spawn_window()` respawn path is a useful deterministic target: it rejects respawn while a live pane still exists unless `-k` is set, destroys the old layout/panes, reinitializes the surviving pane, and reuses the existing window object.
- `spawn_pane()` is the pane-state seam: it preserves or rebuilds cwd, history limit, argv, environment, and `TMUX_PANE`, then chooses between fresh pane creation, split-pane insertion, or respawn reuse.
- `tmux-museum/src/resize.c:resize_window()` is the upstream resize contract: clamp size, unzoom if needed, resize layout first, then window, then notify/redraw, and finally clear `WINDOW_RESIZE`.
- `tmux-museum/src/window.c:window_update_activity()` queues `WINDOW_ACTIVITY`; `tmux-museum/src/input.c:1296-1299` queues `WINDOW_BELL`; `alerts.c:alerts_queue()` and `alerts_check_bell()/alerts_check_activity()` fan those flags out to each winlink in the session group and set session alert state/messages.
- `tmux-museum/src/session.c:session_attach()`, `session_detach()`, and `session_group_synchronize_from()/1()` are the shared-state boundary: winlinks are recreated, `curw` and `lastw` are repaired, and alert flags are copied across linked sessions.
- Best deterministic Task 9 candidates first: respawn rejection/acceptance, pane reuse after respawn, linked-window removal preserving peer session state, and a direct alert-flag propagation check on one grouped window.
- Runtime-heavier cases to leave later: end-to-end control-client size changes, multi-client group fanout, and visual/redraw-only assertions that do not prove the alert flag or linked-session state.
- Upstream regression reference: `tmux-museum/src/regress/session-group-resize.sh` is the clearest existing script for the shared-state resize pattern; there is no equally direct regress script in-tree for alerts, so alert coverage should likely start as focused source-level characterization.

## 2026-04-04T00:00:00Z Task 7 tty winsz parser coverage
- A dedicated `src/tty-keys-test.zig` suite is the repo-native place to keep winsz fragmentation coverage narrow while still exercising the real `tty_keys_next` state machine from `src/tty.zig`.
- `tty_keys_winsz()` already leaves `ESC`, `ESC[`, and incomplete `8;...` / `4;...` payloads unconsumed, so the missing behavior is not the helper parser itself but the higher-level gating around when a completed winsz reply is allowed to take effect.
- The helper did have one tiny local bug worth fixing in-slice: unsupported `CSI ... t` payloads were reporting consumed length before the parser knew they were valid `4;` or `8;` winsz replies.
- The current port accepts unsolicited winsz replies because `src/types.zig` and `src/tty.zig` do not yet carry tmux's `TTY_WINSIZEQUERY` state, so the slice should keep that bug visible rather than silently broadening into a tty state rewrite.

## 2026-04-04T00:00:00Z Task 6 input parsing / reply-buffer behavior
- Keeping this slice in `src/input.zig` was the least risky repo-native choice: dedicated `*-test.zig` suites only run once `src/zmux.zig` imports them, while `input.zig` already hosts the focused parser characterizations.
- `input_reply` needed two small product fixes together to make the risky path honest: fall back to heap formatting for replies beyond the 512-byte stack buffer, and queue `add=true` replies behind outstanding requests instead of sending them out of order.
- `input_request_reply` also needed to drain any immediately following `.queue` items once the matched request completed; otherwise deferred replies stayed stuck until the stale-request timer despite the triggering request having already been satisfied.
- The queue flush paths intentionally trust `InputRequest.idx` as the send length, so the narrow coverage should assert that truncation is real and visible rather than smoothing it over.

## 2026-04-04T00:00:00Z Task 8 window/session/layout coverage landing
- `src/window-test.zig` can cover high-value shared state without runtime-heavy harness setup by combining direct `window_resize`, `window_destroy_all_panes`, `window_lost_pane`, and `window_push_zoom`/`window_pop_zoom` assertions with one grouped-session attach/detach scenario.
- The safest grouped-session characterization is to assert peer sessions keep their own `curw` when that index survives synchronization, and that `lastw` entries are pruned automatically when a synchronized detach removes the old index.
- `window_push_zoom` is a good public-state seam for round-trip coverage because it temporarily restores split visibility and geometry before `window_pop_zoom` reapplies zoom on the active pane.

## 2026-04-04T00:00:00Z Task 6 dedicated suite compliance
- The smallest repo-native wiring for a dedicated input suite is to add `src/input-test.zig` and import it from the root `test {}` block in `src/zmux.zig`; that keeps the build-provided libc/C bridge/options wiring intact without changing the harness shape.
- The trustworthy focused command for this dedicated suite is `zig build test --summary all -- --test-filter "input_"`, which now reaches the task-6 reply-buffer tests from `src/input-test.zig` under the normal repo test runner.

## 2026-04-05T00:00:00Z Task 9: pane/runtime alert and spawn research
- Alert propagation starts in `window_update_activity()` (`src/window.zig:2012-2017`), which stamps `activity_time` and queues `WINDOW_ACTIVITY`; `alerts_queue()` (`src/alerts.zig:69-85`) resets silence state, sets the alert bit, queues one libevent callback, and keeps a window ref until `alerts_callback_cb()` drains the queue.
- `alerts_check_*()` (`src/alerts.zig:131-246`) only fan out to linked sessions/windows when the relevant monitor option is enabled, and they set both `WINLINK_*` flags and `SESSION_ALERTED` before calling `alerts_set_message()`.
- Spawn/respawn is split cleanly: `spawn_window()` (`src/spawn.zig:83-172`) attaches the new window to the session, initializes the first pane, then optionally runs the child; `respawn_pane()` (`src/spawn.zig:205-237`) reuses the live pane after stopping the old process, clearing pane state in `prepare_pane_for_respawn()` (`src/spawn.zig:455-460`).
- Resize is similarly layered: `resize_window()` (`src/resize.zig:35-64`) resizes layout first, then the window, then any layout-less panes, and finally emits the shared window notifications.
- Existing focused coverage already hits `window_resize`, `window_pane_resize`, `window_push_zoom`, grouped attach/detach sync, and respawn-window/pane happy paths in `src/window-test.zig:625-805`, `src/cmd-respawn-window.zig:80-169`, and `src/cmd-respawn-pane.zig:141-232`.

## 2026-04-04T00:00:00Z Task 13 tty-winsz-query-gate
- The real winsz bug was in `src/tty.zig`: `tty_keys_next_inner()` consumed completed `CSI 8;...t` replies without checking whether a winsize query was active.
- The minimal faithful repair is a `TTY_WINSIZEQUERY` tty flag: character-size replies (`CSI 8;...t`) apply the new rows/cols but keep the gate set, while pixel-size replies (`CSI 4;...t`) apply cell pixels and clear the gate.

## 2026-04-04T00:00:00Z Task 9 pane/spawn/resize/alert research
- `src/pane-runtime-test.zig` is not present in this checkout, so the current coverage is split across `src/pane-io.zig`, `src/spawn.zig`, `src/resize.zig`, `src/alerts.zig`, and `src/window-test.zig`.
- The safest fixture pattern repeats everywhere: set global options, init window/session globals, create a window, add panes, and destroy with `window_remove_pane()`/registry cleanup in a `defer` block.
- For alert propagation, the useful assertion is on the flag/state transition (`WINDOW_ACTIVITY`, `WINLINK_ACTIVITY`, `SESSION_ALERTED`) rather than only redraw side effects.
- The intended focused rerun for this slice is `zig test src/pane-runtime-test.zig`; until that suite exists, the closest adjacent source-level checks are the individual runtime files.

## 2026-04-04T00:00:00Z Task 9 pane runtime suite landing
- A dedicated `src/pane-runtime-test.zig` suite works cleanly through the repo harness once it is imported from `src/zmux.zig`; the reliable focused lane is `zig build test --summary all -- --test-filter pane_runtime`.
- The highest-value deterministic cases stayed narrow and source-level: `pane_io_display()` for activity fanout, direct `alerts_queue(... WINDOW_BELL)` for bell fanout, grouped `spawn_window()` synchronization, and `resize_window()` queue/state delivery on a shared window.

## 2026-04-04T00:00:00Z Task 10 redraw/tty runtime map
- There is no `src/redraw-test.zig` in this checkout; redraw coverage currently lives in `src/screen-redraw.zig` tests at `286-428` and the adjacent runtime helpers there.
- The safest fixture shape for this slice is the existing pattern: set global options, init session/window globals, create a window + panes, feed pane data with `pane_io_feed()`, and tear everything down explicitly in `defer` blocks.
- For fragile visible behavior, prefer assertions on public payload/state (`tty_draw_render_*` output, `CLIENT_REDRAW*` flags, `screen.cursor_visible`, `window_pane_options_changed()` side effects) over implementation churn.

## 2026-04-05T00:00:00Z Task 10 tty/redraw runtime coverage details
- Current coverage: `tty-term.zig` already checks capability table sync/load/lookup and reduced-term fallbacks at `549-640` and `1273-1419`; `tty.zig` covers `tty_append_mode_update`, `tty_set_title`, `tty_clipboard_query`, `tty_cursor*`, and `tty_try_colour` / `tty_force_cursor_colour` at `1419-1689` and `3440-3858`; `status.zig` covers reduced status/prompt rendering and overlay sizing at `72-147`, `203-245`, `417-421`, and `664-852`; `screen-redraw.zig` only proves redraw dispatch does not crash with visible panes at `54-237` and `286-390`.
- Fragile seams: `tty_term.isVt100Like()` keys off `xt` or a `clear` prefix (`1056-1086`) before `tty_send_requests()` decides whether to emit DA/XDA and OSC 10/11 probes (`99-133`); `tty_try_colour()` chooses `setaf`/`setab` or `setrgbf`/`setrgbb` and otherwise falls back to SGR (`1422-1458`); `tty_set_title()` requires `TTY_STARTED` plus `supportsTty(.title)` and prefers `tsl`/`fsl` over OSC 2 (`1608-1620`); `screen_redraw_screen()` always does `tty_sync_start()`, `tty_update_mode()`, pane drawing, and `tty_reset()`, while borders/status/overlay are still logged-only TODOs (`205-237`).
- Missing coverage: no focused assertion yet for actual redraw payloads from `screen_redraw_screen()` / `screen_redraw_pane()`, no terminfo-specific test for `tty_set_title()` when `tsl` / `fsl` exist, no payload check for `tty_try_colour()` / `tty_force_cursor_colour()` fallback selection, and no test that `tty_send_requests()` suppresses probes on non-VT100-like terminals or that `tty_sync_start()` / `tty_sync_end()` emit `Sync`.
- Best focused rerun lane for this slice: `zig build test -- --test-filter screen_redraw --test-filter tty_draw --test-filter tty_term --test-filter window_`.

## 2026-04-05T00:00:00Z Task 10 upstream tmux references for redraw/status/terminfo
- Deterministic upstream regress refs to port first: `regress/style-trim.sh` exercises `status-style` + `status-format[0]` rendering and compares captured client output after a short sleep; the source seam is `status_redraw()` in `status.c`, which is called from `screen-redraw.c` when there is no message/prompt overlay.
- Another good first-pass reference is `regress/am-terminal.sh`: it forces `terminal-overrides ',*:am@'`, sets `status-right`, `status-left`, and `window-status-current-format`, then captures pane output after attach. That makes it a strong template for terminfo-driven status redraw parity.
- Source hooks that matter for Task 10 semantics: `screen_redraw_draw_borders()` / `screen_redraw_draw_status()` in `screen-redraw.c`, `status_redraw()` in `status.c`, `tty_draw_pane()` and `tty_write()` in `tty.c` / `screen-write.c`, and `tty_term_override_next()` plus `tty_term_has()` / `tty_term_apply_overrides()` in `tty-term.c`.
- Best verification ideas from those refs: assert visible status text changes after option updates; capture redraw output around border/status changes rather than only checking flags; and add terminfo override cases that prove `am@` changes wrapping-sensitive output without crossing into command ownership.
- Later/runtime-heavier candidates: end-to-end redraw payload checks for `screen_redraw_screen()`, terminal-title probing via `tty_set_title()`, and color fallback/probe suppression in `tty_try_colour()`, `tty_force_cursor_colour()`, and `tty_send_requests()`.

## 2026-04-04T00:00:00Z Task 10 dedicated redraw suite landing
- A new `src/redraw-test.zig` suite works cleanly through the normal repo harness once it is imported from `src/zmux.zig`; the supported focused lane is `zig build test --summary all -- --test-filter redraw_`.
- The highest-value deterministic cases stayed below command ownership: visible status payload changes after a `status-format` update, direct border payload output from `tty_draw_render_borders()`, VT100-like vs non-VT100 request gating in `tty_send_requests()`, and full redraw sync-state cleanup in `screen_redraw_screen()`.
- The suite exposed one direct local redraw bug worth fixing in-slice: `screen_redraw_screen()` and `screen_redraw_pane()` started tty sync but never called `tty_sync_end()`, leaving `TTY_SYNCING` set after redraw.

## 2026-04-05T00:00:00Z Task: tty winsz HOL rejection analysis
- The current port does have a real front-of-buffer block: `server_client_dispatch_stdin()` only keeps decoding while `tty_keys_next()` returns true (`src/server-client.zig:252-262`), but `tty_keys_next_inner()` returns false for a complete winsz reply whenever `TTY_WINSIZEQUERY` is clear (`src/tty.zig:2114-2116`), so the unsolicited `CSI ... t` bytes stay at `tty.in_buf[0]` and pin later input behind them.
- That is not reviewer overreach. Upstream tmux rejects unsolicited winsz before parsing it as a reply (`tmux-museum/src/tty-keys.c:673-675`) and then falls through to ordinary key handling (`tmux-museum/src/tty-keys.c:844-900`) instead of leaving the reply buffered at the front.
- Smallest faithful repair surface: `src/tty.zig` plus `src/tty-keys-test.zig`. For unsolicited winsz, the bytes should be reclassified into the normal key path (closest narrow local match: consume `ESC [` as the same immediate meta-`[` fallback tmux uses), not left buffered and not silently drained as a whole reply.

## 2026-04-05T00:00:00Z Task 11 upstream control/file research
- Control-mode first-pass refs: `tmux-museum/src/regress/control-client-size.sh` proves `refresh -C` updates control-client size live, and `tmux-museum/src/regress/control-client-sanity.sh` drives `refresh-client -C`, `selectp`, `splitw`, `neww`, `swapp`, and `killw` while checking `%pane_id` / `window_layout` output.
- Source seams for that behavior are `tmux-museum/src/cmd-refresh-client.c:cmd_refresh_client_control_client_size()`, `cmd_refresh_client_update_subscription()`, and `cmd_refresh_client_update_offset()`, plus `tmux-museum/src/server-client.c:server_client_dispatch()` and `server_client_set_path()`.
- The most useful notify hooks to mirror are `tmux-museum/src/control-notify.c:control_notify_window_layout_changed()`, `control_notify_window_linked()`, `control_notify_window_unlinked()`, `control_notify_session_window_changed()`, and `control_notify_client_session_changed()`.
- File/path refs: `tmux-museum/src/cmd-source-file.c:cmd_source_file_exec()`, `cmd_source_file_done()`, `cmd_source_file_quote_for_glob()`, and `tmux-museum/src/file.c:file_get_path()`; upstream scripts `src/regress/conf-syntax.sh`, `new-session-environment.sh`, `if-shell-error.sh`, and `new-session-no-client.sh` are the best narrow examples for cwd/glob/`source` behavior.
- Deterministic candidates first: control-client resize/subscription bookkeeping and source-file cwd/glob expansion. Heavier later: broad control-session fanout and end-to-end client/server path updates.
- Local suite targets already exist for this slice: `src/control-test.zig`, `src/server-client-test.zig`, `src/cmd-source-file.zig`, and `src/file-path.zig` / `src/small-modules-test.zig`; extend those before creating anything new unless the reproducer demands it.

## 2026-04-04T00:00:00Z Task 11 control/server-client landing
- `src/control-file-test.zig` still was not needed; the clean local homes were `src/control-test.zig` for pane-output encoding/flush behavior and `src/server-client-test.zig` for active-pane path/session notification seams.
- High-value landed cases: `control_write_output` now has a source-level characterization that proves `%output` escaping and pending-offset flush for pane bytes, `server_client_set_path` now follows the active pane `screen.path` and clears when that path disappears, and `server_client_set_session` now proves `%client-session-changed` reaches a control peer.
- The focused control test exposed one real local fix in Task 11 territory: `control_encode_output` was still using the old `std.ArrayList` API and would not compile under the repo harness until it was updated to allocator-passing calls.
- Reliable rerun lanes for this landing were `zig build test --summary all -- --test-filter "control_write_output flushes escaped pane data"`, `zig build test --summary all -- --test-filter "server_client_set_path follows"`, `zig build test --summary all -- --test-filter "server_client_set_session emits control notification"`, and `./regress/run-all.sh fast`.

## 2026-04-04T00:00:00Z Task 11 local coverage map
- Already covered in `src/server-client-test.zig`: `server_client_resolve_cwd` at `61-77`; identify plumbing at `106-147` and `1865-1891` (`identify_ttyname`, `identify_stdout`, `identify_cwd`, `identify_environ`, `identify_clientpid`, `identify_features`, `identify_done`); remote file dispatch at `1395-1485` (`.read`/`.read_done`); command dispatch at `791-833` and `1945-1990`; cwd precedence at `1192-1221`; and the suspend/resize/shell branches at `1487-1665`.
- Already covered outside that file: `src/file.zig:699-759` (`readResolvedPathAlloc`), `src/file.zig:766-819` (`sendPeerStream`), `src/small-modules-test.zig:33-212` (`file_path.resolve_path`, `file_get_path`, `shouldUseRemotePathIO`), `src/control-test.zig:84-105` and `405-419` (`control_notify_*` empty-registry smoke + `control_ready`), `src/notify.zig:505-713` (`%layout-change` and `%session-window-changed` control fanout), and `src/status-runtime.zig:301-364` (control-client `%message` routing).
- Focused adjacent gaps: `server_client_set_path` at `860-872`, `server_client_set_title` at `844-858`, `server_client_print` control/detached routing at `887-909`, `window_pane_read_callback` to `control_write_output` at `src/window.zig:1977-1983 -> src/control.zig:244-282`, `server_client_check_pane_buffer` control offset accounting at `src/server-client.zig:2379-2459`, and `server_client_set_session` notification emission at `916-940`.
- Candidate test names: `server_client_set_path updates client path from active pane`, `window_pane_read_callback forwards pane data to control clients`, and `server_client_set_session emits client-session-changed for control peers`.

## 2026-04-05T00:00:00Z Task 12 compliance repair
- The Task 12 acceptance text is strict about file paths: the command families are only plan-compliant once the exact suites exist at `src/cmd-buffer-env-options-test.zig`, `src/cmd-session-window-test.zig`, and `src/cmd-client-ui-test.zig`.
- The clean repair is structural: new family suites should import the existing per-command behavior files and own the umbrella parse/smoke tests, while the old broader homes stay empty and no longer claim those families.

## 2026-04-04T00:00:00Z Task 12 command-family upstream research
- Task item: `12. Add command-family coverage in coherent slices rather than one giant cmd sweep`.
- Send-keys / copy-mode: upstream refs are `tmux-museum/src/regress/copy-mode-test-vi.sh`, `tmux-museum/src/regress/copy-mode-test-emacs.sh`, `src/cmd-send-keys.c:cmd_send_keys_exec()/cmd_send_keys_inject_key()/cmd_send_keys_inject_string()`, and `src/window-copy.c:window_copy_init()/window_copy_view_init()/window_copy_cursor_next_word()/window_copy_cursor_previous_word()`.
- Port first: `copy-mode`, `send-keys -X`, motion/selection boundaries, and `show-buffer` outputs; keep raw key injection, `-K`, and `-M` for later.
- Buffer / env / options: upstream refs are `src/cmd-set-buffer.c`, `src/cmd-save-buffer.c` (`show-buffer`), `src/cmd-load-buffer.c`, `src/cmd-paste-buffer.c`, `src/cmd-set-environment.c`, and `src/cmd-set-option.c`.
- Port first: buffer create/append/delete/rename, paste newline handling, `set-environment` unset/clear/hidden, and `set-option` scope resolution with `-u/-U/-o/-a`; keep file IO and selection sync via `-w` for later.
- Session / window: upstream refs are `tmux-museum/src/regress/session-group-resize.sh`, `src/cmd-new-session.c`, `src/cmd-new-window.c`, `src/cmd-select-window.c`, `src/cmd-move-window.c`, `src/cmd-kill-window.c`, `src/cmd-kill-session.c`, `src/cmd-rename-session.c`, and `src/cmd-rename-window.c`.
- Port first: grouped-session resize after `switch-client`/`selectw`, window move/link/renumber, and rename/status hooks; keep attach/detach fanout cases for later.
- Client / UI: upstream refs are `tmux-museum/src/regress/control-client-size.sh`, `tmux-museum/src/regress/control-client-sanity.sh`, `src/cmd-display-message.c`, `src/cmd-display-panes.c`, `src/cmd-refresh-client.c`, `src/cmd-command-prompt.c`, `src/cmd-confirm-before.c`, `src/cmd-display-menu.c`, `src/cmd-switch-client.c`, `src/cmd-detach-client.c`, and `src/cmd-list-clients.c`.
- Port first: `display-message -p/-F` format expansion, `refresh-client -C` sizing/offset/subscription handling, and `display-panes` selection dispatch; keep prompt/menu callbacks and full client switching for later.
- Verification ideas: `zig test src/cmd-send-keys-test.zig`, `src/window-copy-test.zig`, `src/cmd-buffer-env-options-test.zig`, `src/cmd-session-window-test.zig`, and `src/cmd-client-ui-test.zig`; run `./regress/run-all.sh oracle` after a family lands.

## 2026-04-04T00:00:00Z Task 12 family (a) send-keys/copy-mode landing
- The most valuable bounded `send-keys` addition is an integration test that enters real `copy-mode` on a pane, then drives `send-keys -X -N` through the active runtime and checks the resulting copy-mode cursor position.
- For `window-copy`, the cleanest upstream-style boundary check here is the immediate `select-word` anchor/end state (`selrx` and `endselrx`) around session `word-separators`, without broadening into later follow-up selection-sync behavior.
- The reliable repo verification lane for this family is harness-based: explicit `zig build test --summary all -- --test-filter ...` reruns for the focused send-keys/copy-mode cases plus `./regress/run-all.sh oracle`.

## 2026-04-04T00:00:00Z Task 12 family (b) buffer/env/options landing
- The smallest clean homes stayed split by command ownership: env visibility/state in `src/cmd-set-environment.zig` and `src/cmd-show-environment.zig`, option mutation in `src/cmd-set-option.zig`, and the broader buffer files remained untouched because their local coverage was already coherent.
- High-value additions for this slice were command-level checks for `set-environment -r` versus `-u`, hidden environment entries with `-h`, `show-environment` visibility and shell-output rendering for cleared entries, and `set-option -a` on an existing string option.
- The reliable family-(b) rerun lane is `zig build test --summary all -- --test-filter "cmd-breadth|set-buffer|save-buffer|load-buffer|paste-buffer|list-buffers|set-option|show-options|set-environment|show-environment"`, followed by `./regress/run-all.sh oracle`; both passed for this landing.

## 2026-04-04T00:00:00Z Task 12 family (c) session/window landing
- The cleanest family-(c) homes remained the existing per-command files: grouped-session resize coverage fit naturally in `src/cmd-select-window.zig`, and the grouped link invariant belonged in `src/cmd-move-window.zig`; a new `src/cmd-session-window-test.zig` file was not needed.
- The highest-value bounded grouped-session check here is `window-size=latest` on a shared window after `select-window`: asserting the shared window's `latest` client pointer and visible `sx`/`sy` proves the resize path without absorbing broader client/UI ownership.
- A useful command-surface invariant to keep visible is that `link-window` still rejects sessions already in the same group even when the destination index is otherwise valid; keeping that at the command layer complements the lower-level `server_link_window` test.
- Reliable verification for this slice was `zig build test --summary all -- --test-filter "cmd-session-lifecycle|new-session|select-window|kill-window|move-window|swap-window|resize-window|resize-pane|split-window|join-pane"`, explicit reruns of the two new test names, and `./regress/run-all.sh oracle`.

## 2026-04-04T00:00:00Z Task 12 family (d) client/UI landing
- The cleanest homes stayed per-command: `src/cmd-display-message.zig` for `-p/-F` behavior and `src/cmd-display-panes.zig` for selection dispatch; `src/cmd-client-ui-test.zig` was still unnecessary.
- The high-value `display-message` seam was attached-client print mode with `-p -F`: checking the pane view-mode grid row proved real format expansion reached the shared print path instead of only asserting mode activation.
- `display-panes` command templates are a single argv field, so the bounded dispatch coverage should pass one command string and then assert the chosen pane id is substituted into `%1` before queue execution.
- Trustworthy verification for this slice was the touched-home harness reruns (`zig build test --summary all -- --test-filter "display-message"` and `"display-panes"`) plus `./regress/run-all.sh oracle`; all were green.

## 2026-04-05T00:00:00Z Task: tty winsz HOL repair
- The narrow local repair is to consume only the unsolicited reply prefix as ordinary `M-[` input when `TTY_WINSIZEQUERY` is clear; that keeps active query handling intact while preventing `server_client_dispatch_stdin()` from stalling on a complete `CSI ... t` reply at `tty.in_buf[0]`.
- The focused regression needs two checks together: unsolicited winsz must leave tty size unchanged and must let a trailing byte drain after the reply bytes are reclassified through the normal key path.

## 2026-04-13 Task 0: Baseline validation learnings
- Worktree infra confirmed working: `zig build test` runs from `/tmp/zmux-test-probe` identically to main
- Pre-existing failures are in utf8/grid/input/screen-write/tty-draw/window-copy — NOT in campaign target modules
- Use `zig build test -- --test-filter "<module>"` to isolate new tests from pre-existing noise
- Both warm lane (`zig build test`) and stress lane (`zig build test-stress`) have same pre-existing failures
- Evidence files written to `.sisyphus/evidence/task-0-*`

## 2026-04-12T00:00:00Z Task 1 zmux-protocol wire coverage
- `src/zmux-protocol-test.zig` covers the wire contract best when each extern struct is checked with `@sizeOf`, `@alignOf`, `@offsetOf`, and a raw-byte round-trip.
- The zig-unit orchestrator rejects new test cases until they are added to `regress/test_timeouts.json`; short 5s entries were enough for the new protocol cases.
- A 15 KiB envelope payload is a good boundary value here because it stays under the imsg cap while still exercising large tail handling.

## Task 2: format-draw-test.zig (2026-04-12)

- format-draw.zig public API: `format_trim_left`, `format_trim_right`, `format_width`, `format_draw`, `format_draw_ranges`, `format_draw_many`, `format_leading_hashes`, `format_is_type`
- Screen test pattern: `screen_mod.screen_init(width, 1, 0)` + `T.ScreenWriteCtx{ .s = screen }` + defer free
- Cell readback: `grid.get_cell(screen.grid, row, col, &cell)` then `cell.payload().bytes()`, `.bg`, `.isPadding()`
- Test timeout registry: `regress/test_timeouts.json` needs entries for both `zig-unit:` and `zig-stress:` prefixes
- Test names in the orchestrator use the source file name (e.g., `format-draw-test`) not the module
- Wide char width bug: UTF-8 decoder returns width 1 for CJK/emoji; this is a known pre-existing issue affecting inline tests too
- Squash-merging the tranche branches into local main kept the tracker edits and test evidence easy to verify in order.
- format-draw still has the documented wide-character width bug; the tracker should stay on known-fail until that decoder issue lands.

## 2026-04-12T00:00:00Z Task 7 format core coverage
- The zig-unit orchestrator rejects new warm-lane tests until each exact case name is added to `regress/test_timeouts.json`; short 5s entries were enough for these formatter cases.
- Direct missing keys stay incomplete and preserve the original `#{...}` text, but nested conditionals can safely probe missing or empty values by wrapping them in their own inner expansions.
- Recursive `#{E:option}` self-reference bottoms out as an incomplete preserved expression at the format loop limit, so the honest characterization uses `format_expand` rather than `format_require_complete`.

## 2026-04-12T00:00:00Z Task 11 server dedicated suite
- `tmux-museum/src/server.c:server_signal()` handles `SIGTERM`, `SIGINT`, `SIGCHLD`, `SIGUSR1`, and `SIGUSR2` only; there is no `SIGHUP` branch, so a no-op characterization is the honest parity check in `src/server-test.zig`.
- `src/server-test.zig` can cover signal and lifecycle behavior without touching `src/server.zig` by importing public server helpers and declaring `extern fn server_signal(...)` for the exported signal entry point.
- The repo test orchestrator also requires explicit timeout entries for new dedicated suites here; adding `src/server-test.zig` meant registering both `zig-unit:` and `zig-stress:` case IDs in `regress/test_timeouts.json`.
- The broad `zig build test -- --test-filter server` lane currently also selects pre-existing `server-print` view-mode cases, which still crash with signal 11 and need their own follow-up repair.

## 2026-04-12T00:00:00Z Task 13 window lifecycle/state coverage
- `window-linked` and `window-unlinked` hooks are a reliable public seam for window lifetime ordering: after `session_attach()` the queued notify callback holds one extra window ref, and after `session_destroy()` the window stays alive until the notify queue drains.
- `cmd-options.apply_target_side_effects()` is the narrow source-level path that fans a window option change out to every pane without needing command parsing in `window-test.zig`.
- `resize.resize_window()` needs session globals initialized even in a direct unit test because it emits `notify_window(...)`, which walks `sess.sessions`.
- A broad `zig build test -- --test-filter "window"` rerun still discovers unrelated legacy failures from other suites whose names contain `window`, so focused reruns are useful to prove the new `window-test.zig` cases themselves are green.

## 2026-04-12T00:00:00Z Task 17 tranche-3 merge cleanup
- Squash-merging the tranche-3 worktrees into local `main` kept the new coverage grouped by module and the tracker row updates isolated to tranche 3.
- `server-client` intentionally stays `known-fail` for the `CLIENT_EXIT` dispatch bug; the pre-existing `server-print` signal-11 cases remain visible and should not be hidden.
- When two branches both touch `regress/test_timeouts.json`, keep all timeout entries from both sides so later reruns still discover every case.
- After cleanup, only the local repo and the existing `lab/wacky-experiment` worktree should remain.

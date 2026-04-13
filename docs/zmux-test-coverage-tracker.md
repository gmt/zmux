# Zmux Test Coverage Tracker

## Purpose

Track the scary semantics, not a flat percentage.

## Tracker Workflow

1. Scan the module or sub-component.
2. Audit the scary facets.
3. Prioritize the real risk.
4. Add tests or log honest failures.
5. Update the row instead of hiding the problem.

## Scary Signals

- transactional or stateful behavior
- async or streamed triggers
- protocol-visible semantics
- lifecycle ordering
- cross-module side effects
- parser or formatter edge cases
- port logic that looks suspiciously approximate compared with tmux

## Legend

- `Status`
  - `unscanned`
  - `scanned`
  - `testing`
  - `covered`
  - `known-fail` (tracked in [docs/zmux-test-exceptions.md](zmux-test-exceptions.md))
  - `self-evident`
- `Lane`
  - `test`
  - `test-stress`
  - `doc-only`

## Tracker

> [!IMPORTANT]
> Log all `known-fail` status entries in [docs/zmux-test-exceptions.md](zmux-test-exceptions.md).

| Subsystem | Module | Facet | Scary Signals | Tmux Anchor | Current Tests | Lane | Priority | Status | Owner | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Format | `src/format.zig` | core expansion, conditionals, substitutions, loops | formatter edge cases; protocol-visible semantics | `tmux-museum/src/format.c` | `src/format-test.zig` | `test` | high | covered |  | multiple facets expected |
| Format | `src/format.zig` | async `#(...)` shell jobs and cache lifetime | async triggers; transactional behavior | `tmux-museum/src/format.c` | `src/format-test.zig` | `test-stress` | high | known-fail |  | allocator mismatch in timeout path |
| Format | `src/format-resolve.zig` | scope resolution and child context inheritance | stateful behavior; approximate port risk | `tmux-museum/src/format.c` | `src/format-resolve-test.zig` | `test` | high | covered |  | multiple facets expected |
| Format | `src/format-draw.zig` | width trimming, list clipping, style-aware rendering | formatter edge cases | `tmux-museum/src/format-draw.c` | existing inline | `test` | high | known-fail |  | use for rendering/output fidelity |
| Format | `src/cmd-format.zig` | command-facing format consumers | user-visible semantics; parser edge cases | `tmux-museum/src/format.c` | `src/cmd-format-test.zig` | `test` | high | covered |  | seed from format core |
| Format | `src/cmd-list-panes.zig` | list-panes / list-clients shared formatter path | user-visible semantics; ordering | `tmux-museum/src/cmd-list-panes.c` | existing inline + `src/cmd-session-window-test.zig` | `test` | high | covered |  | command consumer of format |
| Format | `src/cmd-display-message.zig` | message rendering through shared formatter | protocol-visible semantics; output shape | `tmux-museum/src/cmd-display-message.c` | existing inline + `src/cmd-client-ui-test.zig` | `test` | medium | covered |  | focused family suite now owns the umbrella coverage |
| Control | `src/control-subscriptions.zig` | change detection and emission rules | streamed triggers; protocol-visible semantics | `tmux-museum/src/control.c` | `src/control-test.zig` | `test` | high | covered |  | multi-facet likely |
| Control | `src/control-notify.zig` | event mapping to control messages | protocol-visible semantics; ordering | `tmux-museum/src/control-notify.c` | `src/control-notify-test.zig` | `test` | high | covered |  | pair with subscriptions; 1:1 tmux parity confirmed |
| Control | `src/cmd-refresh-client.zig` | subscription wiring and control-side deltas | protocol-visible semantics; ordering | `tmux-museum/src/cmd-refresh-client.c` | existing inline | `test` | high | covered |  | should mirror live delta behavior |
| Control | `src/zmux-protocol.zig` | wire protocol structs and round-trips | protocol-visible semantics | `tmux-museum/src/tmux-protocol.h` | `src/zmux-protocol-test.zig` | `test` | high | covered |  | keep wire layout honest |
| Control | `src/server-client.zig` | client/server dispatch and peer state | protocol-visible semantics; side effects | `tmux-museum/src/server-client.c` | `src/server-client-test.zig` | `test` | high | known-fail |  | likely intertwined with protocol rows |
| Input/TTY | `src/input.zig` | partial sequences and mode transitions | streamed triggers; parser edge cases | `tmux-museum/src/input.c` | existing inline + `src/input-test.zig` | `test` | high | covered |  | dedicated suite now covers overlong reply formatting plus deferred reply queue flush/truncation edges |
| Input/TTY | `src/input-keys.zig` | client-side sequence parsing and replies | streamed triggers; parser edge cases | `tmux-museum/src/input-keys.c` | existing inline | `test` | high | covered |  |  |
| Input/TTY | `src/tty-keys.zig` | key decode/encode compatibility | protocol-visible semantics | `tmux-museum/src/tty-keys.c` | existing inline + `src/tty-keys-test.zig` | `test` | medium | covered |  | dedicated winsz fragmentation coverage is in place, and `src/tty.zig` now emits `18t/14t` queries when pixel dimensions are missing, then gates winsz consumption on `TTY_WINSIZEQUERY` with char-vs-pixel clear semantics |
| Async seams | `src/cmd-run-shell.zig` | detached/attached output semantics | async triggers; side effects | `tmux-museum/src/cmd-run-shell.c` | existing inline | `test-stress` | high | covered |  |  |
| Async seams | `src/cmd-pipe-pane.zig` | pipe directionality and lifecycle | async triggers; fd semantics | `tmux-museum/src/cmd-pipe-pane.c` | existing inline | `test-stress` | high | covered |  |  |
| Async seams | `src/cmd-source-file.zig` | detached reads, cwd resolution, glob behavior | async triggers; parser/format edge cases | `tmux-museum/src/cmd-source-file.c` | existing inline | `test-stress` | high | covered |  |  |
| Runtime | `src/server.zig` | signal/lifecycle behavior | transactional behavior; lifecycle ordering | `tmux-museum/src/server.c` | `src/server-test.zig` | `test` | high | covered |  |  |
| Runtime | `src/session.zig` | session lifecycle and side effects | transactional behavior | `tmux-museum/src/session.c` | existing inline + `src/window-test.zig` + `src/session-test.zig` | `test` | medium | covered |  | direct grouped-session attach/detach sync now covers peer current/last-window invariants |
| Runtime | `src/window.zig` | window lifecycle and state propagation | transactional behavior; side effects | `tmux-museum/src/window.c` | `src/window-test.zig` + existing inline | `test` | high | covered |  | covers resize pixel semantics, destroy/lost-pane cleanup, and zoom push/pop round-trip state |
| Runtime | `src/layout.zig` | layout mutation semantics | transactional behavior | `tmux-museum/src/layout*.c` | `src/layout-test.zig` | `test` | medium | covered |  |  |
| Command sweep | `src/cmd-*.zig` | scary semantic buckets | varies | matching tmux command file | `src/cmd-send-keys-test.zig`, `src/window-copy-test.zig`, `src/cmd-buffer-env-options-test.zig`, `src/cmd-session-window-test.zig`, `src/cmd-client-ui-test.zig` | `test` / `test-stress` | medium | covered |  | family suites now own the umbrella command sweep by risk bucket |

## Notes

- Add multiple rows for a module when it clearly has multiple scary facets.
- Mark units `self-evident` when they were scanned and genuinely do not merit new tests.
- Point every intentional red test at [docs/zmux-test-exceptions.md](zmux-test-exceptions.md).
- If a module spans both warm-lane and stress-lane behavior, split it into separate rows.

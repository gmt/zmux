# Command Family Suite Audit — Sweep Notes

Audit of the 5 existing command family test suites for semantic coverage gaps.

## Suite 1: cmd-send-keys-test.zig (41 tests)

**Verdict: Excellent coverage. No scary gaps found.**

Covers all major flags: `-l` (literal), `-H` (hex), `-R` (reset), `-K` (key-table
dispatch), `-M` (mouse), `-X` (copy-mode command), `-F` (format), `-N` (repeat),
`-c` (target client). Also covers error paths (repeat count too small/large,
read-only client, missing mouse target), mode table bindings, mode key fallback,
synchronized panes, triggering-key replay, and the `Any` wildcard key.

Minor non-scary gaps:
- No test for multi-byte UTF-8 key arguments (low risk — key encoding is tested
  elsewhere in input-keys).
- No test for empty `-H` argument list (edge case, not a semantic gap).

## Suite 2: window-copy-test.zig (47 tests)

**Verdict: Excellent coverage. No scary gaps found.**

Covers: backing screen sync, history rows, navigation (history-top/bottom,
page-down, scroll-down, cursor motions), wrapped-line motions, word/space motions
with custom separators, select-word, jump-char (forward/backward/to/again/reverse),
paragraph motions, goto-line, mouse drag (start/update/edge-scroll/timer/scrollbar),
marks (set-mark/jump-to-mark), selection (begin/clear/rectangle/copy-selection),
search (forward/backward/regex/incremental/search-again), built-in command
validation, view mode (init/add/re-entry/resize/format/refresh/tail), clipboard
export, and resize rewrap.

Minor non-scary gaps:
- `scroll-up` not tested directly (covered indirectly via history-top and
  page-down-and-cancel patterns).
- `other-end` (swap selection endpoints) not tested (low risk — selection
  mechanics are well-covered by begin-selection + cursor-right tests).
- `middle-line` not tested (cosmetic cursor placement, not a data-integrity risk).

## Suite 3: cmd-buffer-env-options-test.zig (7 tests → 8 tests)

**Verdict: Weakest umbrella. Zero exec tests before this audit.**

The umbrella file only had parse-level tests (`parseName` checks). All exec
coverage came from inline tests in the individual command files:
- `cmd-set-buffer.zig`: 4 inline exec tests (set, append, rename, delete)
- `cmd-set-environment.zig`: 3 inline exec tests (set, clear/unset, hidden)
- `cmd-show-environment.zig`: 3 inline exec tests (render, hidden, shell)
- `cmd-set-option.zig`: ~20 inline exec tests
- `cmd-show-options.zig`: ~6 inline exec tests

**Gap filled**: Added `set-environment -g exec stores a variable in the global
environ` — exercises the set-environment → environ_find round-trip through
cmd_execute in the umbrella, verifying both set and unset (-u) paths.

## Suite 4: cmd-session-window-test.zig (19 tests → 21 tests)

**Verdict: Good exec coverage for core commands. Two gaps filled.**

Had exec tests for: start-server, new-window, list-clients (sort, filter, scope),
list-sessions (empty, format). Individual command files provide thorough inline
exec tests for kill-window, select-window, move-window, swap-window, resize-*,
split-window, join-pane, break-pane, respawn-*.

**Gap 1 filled**: `list-sessions output includes created session names` — the
existing format test only checked return value, not output content. New test
creates two sessions and verifies both names appear in `list-sessions -F
#{session_name}` output via capture_stdout.

**Gap 2 filled**: `show-messages command entry succeeds on attached client` —
show-messages had zero coverage in the umbrella (not even in the smoke test
list in cmd-client-ui-test.zig). New test exercises the exec path with an
attached client.

## Suite 5: cmd-client-ui-test.zig (6 tests)

**Verdict: Adequate smoke coverage. No changes needed within ownership scope.**

The smoke test exercises: display-panes, break-pane, pipe-pane, respawn-pane,
respawn-window, command-prompt, confirm-before, copy-mode, choose-tree,
display-menu. The bogus-flag test covers parse rejection.

Commands not in the smoke test: show-messages, show-prompt-history,
switch-client, refresh-client. However:
- show-messages gap was filled in cmd-session-window-test.zig (above).
- switch-client and refresh-client have thorough inline exec tests in their
  own files (cmd-switch-client.zig: 12 tests, cmd-refresh-client.zig: 16 tests).
- show-prompt-history has 3 inline exec tests in cmd-show-prompt-history.zig.
- display-message tests are owned by Task 23.

## Summary of Changes

| Suite | Before | After | Tests Added |
|-------|--------|-------|-------------|
| cmd-buffer-env-options-test.zig | 7 | 8 | +1 (set-environment exec) |
| cmd-session-window-test.zig | 19 | 21 | +2 (list-sessions output, show-messages exec) |
| cmd-send-keys-test.zig | 41 | 41 | 0 (no gaps found) |
| window-copy-test.zig | 47 | 47 | 0 (no gaps found) |
| cmd-client-ui-test.zig | 6 | 6 | 0 (gaps filled via other suites) |
| **Total** | **120** | **123** | **+3** |

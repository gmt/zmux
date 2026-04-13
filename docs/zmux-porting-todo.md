# zmux Porting TODO

Live tmux-parity gaps only.

## Rules

- This file is for functional or capability gaps where zmux does not yet match
  tmux.
- Keep only live entries. When a gap is fixed, delete the entry. Do not leave
  behind `FIXED`, `RESOLVED`, strike-through sections, or historical cemeteries.
- Do not put Zig cleanup, refactors, naming work, type-shape cleanup, or API
  cleanup here. That belongs in `docs/zig-porting-debt.md`.
- Prefer one section per gap with three bullets:
   - `tmux:` what behavior exists upstream
   - `zmux:` what is currently missing or approximate
   - `likely files:` where the repair probably lives

## cmd_find_target crashes when queue item has no client

- `tmux:` `cmd_find_target` with `@` returns an error when the
  command-queue item carries no client context.
- `zmux:` SIGSEGV — null client pointer is dereferenced instead of
  producing a graceful `-1` return.
- `likely files:` `src/cmd-find.zig`

## show-buffer attached view-mode path crashes (4 tests)

- `tmux:` `show-buffer` renders buffer contents through the shared
  view-mode print path on attached clients.
- `zmux:` All four attached-view-mode tests SIGSEGV: basic rendering,
  utf8 payload preservation, key dismiss, and control-byte escaping.
- `likely files:` `src/cmd-save-buffer.zig`, `src/server-print.zig`

## linux osdep pty foreground child lookup fails

- `tmux:` `osdep_get_name` and `osdep_get_cwd` resolve the foreground
  process name and working directory of a pty's controlling child.
- `zmux:` The assertion in the test fails — the pty introspection does
  not observe the forked child's identity or cwd in time.
- `likely files:` `src/os/linux.zig`

## cmd UI exec smoke crashes on attached client

- `tmux:` UI commands (menus, prompts, confirm dialogs) execute on
  attached clients without issue.
- `zmux:` SIGSEGV when the cmd-client-ui smoke test exercises UI
  command dispatch on an attached client fixture.
- `likely files:` `src/cmd-client-ui-test.zig` and the command
  implementations it exercises

## select-pane crashes on invalid pane styles

- `tmux:` `select-pane` rejects invalid style strings gracefully,
  returning an error to the caller.
- `zmux:` SIGSEGV instead of a clean error return when the style
  parser encounters an invalid pane-style argument.
- `likely files:` `src/cmd-select-pane.zig`, `src/style.zig`

# Coverage Status

This file is a coarse status snapshot, not a live queue.


## Summary

- reviewed: 148
- covered: 3
- justified: 1
- partial: 96
- missing: 48

## Subsystems

| area | current state | next pressure |
|---|---|---|
| core entry and IPC | partial coverage across client, proc, server, and `tmux.c` | keep queue/runtime seams honest and avoid reviving local command glue |
| options, env, and command scaffolding | mostly partial but broadly present | widen shared parsers and table-driven metadata instead of command-local forks |
| server, session, window, and pane runtime | broad partial coverage | keep shared ownership and redraw/runtime seams moving downward |
| layout and interactive UI modes | still mostly missing | treat layout and mode work as real substrate, not cleanup |
| grid, screen, tty, and UTF-8/display | partial shared substrate with ordinary queue work reopened | finish consumer adoption and the remaining display/runtime seams |
| minimum smoke-harness commands | broadly partial | keep landing truthful reduced command behavior on shared runtime seams |
| full deferred command surface | many partial files and a smaller set of missing files | prefer queue-shaped canonical tasks over planner prose |
| optional features and platform surface | mostly missing or gated | keep these out of the main parity path until core runtime is steadier |

## Current Intent

- keep the visible queue small and canonical
- grow the shared display/runtime stack before reopening more UTF-8-sensitive
  command work
- use docs for current state and future intent only

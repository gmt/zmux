# zmux Architecture

This file is the canonical in-repo blueprint for the port.

Truth split:
- `tmux` is the behavioral oracle.
- this file defines the intended stack shape and the rules for extending it.
- `docs/status/*.md` describe the current truthful state and future intent.

Documentation rules:
- DOCS MAY DESCRIBE ONLY THE CURRENT STATE AND FUTURE INTENT.
- NEVER DOCUMENT PAST CHANGES OR PROJECT HISTORY IN DOCS.
- keep docs small and topic-shaped; do not grow a new omnibus planner.

## Consumer Surface

Consumers should eventually rely on one shared text/cell model instead of
rolling their own byte-oriented or command-local logic.

Target surface:
- decode terminal input bytes into key or glyph candidates
- represent one display glyph or cell payload
- measure display width with one shared policy
- trim and pad by display cells rather than raw bytes
- write one glyph or cell into grid and screen state
- compare and search stored cell payloads
- edit prompt and status text in display-cell terms

Named surfaces are allowed to stay thin while the lower layers catch up:
- `utf8.Decoder`
- `utf8.WidthPolicy`
- `utf8.Glyph`
- `utf8.CellBuffer`
- `displayWidth`, `trimDisplay`, `padDisplay`
- `screen_write.putGlyph`, `putCell`, or equivalent shared cell-aware entry
  points

## Stack

The stack should stay top-down and explicit:

1. consumer adapters
2. grid and screen-write integration
3. glyph and cell payload storage
4. combine policy
5. width policy and overrides
6. byte decode and conversion backend

If a consumer needs missing semantics, extend the lower layer that owns them.
Do not patch around the gap locally.

## Current Foundation Focus

The active queue head is `foundation:utf8-consumer-adoption`.

Current truthful substrate:
- `src/types.zig` provides `Utf8Data`, `utf8_char`, `UTF8_SIZE`, and shared
  grid-adjacent payload types.
- `src/utf8.zig` owns decode helpers, width helpers, width overrides, and the
  shared string-facing UTF-8 helpers.
- `src/utf8-combined.zig` owns the reduced combine policy helpers.
- `src/grid.zig` and `src/screen-write.zig` already have a real cell-aware seam
  instead of pure ASCII storage.
- `src/status-prompt.zig`, `src/format-draw.zig`, and `src/status.zig` already
  touch the shared path, but the broader runtime is still reduced.

Open semantic gap:
- broader prompt, status, message, search, and editor consumers do not yet all
  share the same display-cell model
- `screen-write` is still reduced relative to tmux `screen_write_cell`
- runtime-side redraw, mode, and tty behavior still rely on reduced seams in
  several places

That means the next honest work is not "more Unicode helpers." It is wider
consumer adoption of the shared cell stack plus the remaining lower-layer
runtime truth needed to support it.

## Seal Rules

The UTF-8/display foundation tranche uses these guardrails:

- no new UTF-8, width, combine, or rendering hacks outside the declared stack
- no new command-local text logic when a lower shared seam can own it
- queue notes stay SMS-scale; longer context belongs in a small doc under
  `docs/`
- docs over the size cap are reverted automatically by the Ralph proxy
- history language in docs is a warning condition and should be cleaned up when
  touched

`utf8proc` policy:
- it may be used as a backend helper for width or conversion behavior
- it is not the semantic source of truth
- the semantic model stays tmux-shaped and display-oriented

## Exit Gate

UTF-8-sensitive parity work should reopen only when these are materially
truthful together:

- shared decode and width policy
- shared cell payload storage
- live `screen-write` cell path
- shared prompt and status consumers
- reduced tty and redraw runtime that no longer forces local display hacks

Until then, queue items in the UTF-8/display space should keep building the
shared stack rather than reopening command-local parity slices.

## Temporary Ralph Adjustments

These are foundation-tranche rules, not permanent doctrine:

- the queue is allowed to start with `foundation:*` tasks
- foundation-mode prompts relax per-commit verification expectations
- the loop stops at the end of the foundation tranche instead of rolling
directly into ordinary slices

These should be revisited once the foundation rows are materially green.

This rule is permanent and should not be unwound:
- first `Ctrl-C` is a clean pause boundary, not a dirty WIP pause

# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## Sixel Draw Path

- `tty_draw_images` / `append_sixel_images` in tty-draw.zig emit
  fallback text (`im.fallback`) instead of real sixel data. The
  TtyCtx needs to carry `im.data` as `ctx.si` through the draw
  dispatch so `tty_cmd_sixelimage` can call `sixel_print`.
- `sixel_to_screen` (fallback cell grid for non-sixel terminals)
  is not ported.

## Input Request Queue

- The request timer and request reply functions require a TAILQ
  of `InputRequest` structs on both `WindowPane` (input context)
  and `Client`. tmux uses this to match incoming terminal replies
  (palette, clipboard) against outstanding queries and dispatch
  them in order. ~150 lines of infrastructure to port from
  tmux-museum/src/input.c (lines 3294-3480).

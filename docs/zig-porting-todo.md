# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## Sixel Draw Path

- `tty_draw_images` / `append_sixel_images` in tty-draw.zig emit
  fallback text (`im.fallback`) instead of real sixel data. The
  TtyCtx needs to carry `im.data` as `ctx.si` through the draw
  dispatch so `tty_cmd_sixelimage` can call `sixel_print`.
- `sixel_to_screen` (fallback cell grid for non-sixel terminals)
  is not ported.

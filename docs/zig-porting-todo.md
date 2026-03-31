# Porting TODO

Functional gaps where zmux does not yet match tmux behavior.

## Sixel Draw Path

- `tty_cmd_sixelimage` has the real sixel output path (calls
  `sixel_scale` + `sixel_print`) but `tty_draw_images` /
  `append_sixel_images` in tty-draw.zig still emit fallback
  text (`im.fallback`) instead of real sixel data. The TtyCtx
  needs to carry `im.data` as `ctx.si` through the draw dispatch.
- `sixel_to_screen` (fallback cell grid for non-sixel terminals)
  is not yet ported.

## Input Timers (stubs)

- `input_start_ground_timer` (4 callers): DCS/OSC/APC/rename
  ground timeout needs libevent timer integration.
- `input_start_request_timer` (2 callers): request timeout
  needs libevent timer integration.
- `input_request_reply` (2 callers): tty-keys clipboard/palette
  reply forwarding needs client request queue infrastructure.

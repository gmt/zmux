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

## Sixel image duplicated in scrollback after partial scroll

- tmux: rendering a sixel (e.g. `chafa --format sixel --size 80x40 ...`) and
  then partially scrolling it past the top of the viewport (`yes "" | head
  -15`) leaves a single intact rendering of the surviving image rows when you
  scroll back into history.
- zmux: the same sequence shows two visually distinct copies of the source
  image in scrollback — the upper copy showing the *lower* rows of the source,
  the lower copy showing the *upper* rows, separated by a band of
  image-occupied cells. Reproduced on `main`; the rgba-uplift branch shows
  the same artifact, so the bug is pre-existing and not introduced by the RGBA
  canonical store work. The dimensional invariant test added in 4d1d29d covers
  width/height of the cropped image but does not catch the duplication, since
  the duplication is in the render path rather than in `image_scroll_up`.
  Pinned by `regress/sixel-scroll-deduplication.sh`, which currently fails
  with two-or-more DCS sixel emits on attach/resize redraws where exactly one
  surviving image emit is expected; wire it into `FAST_CASES` once repeated
  redraws stop resending the same cropped image into the terminal scrollback.
- likely files: `src/image.zig` (`image_scroll_up` only crops, so the
  duplication is downstream); `src/server-client.zig` and `src/tty-draw.zig`
  (attach/resize redraw sequencing and payload image emission); `src/tty.zig`
  (`tty_draw_images` is the tmux-shaped reference path for future cleanup).

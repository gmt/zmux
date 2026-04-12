# Mental model for zmux text rendering

tmux and zmux operate, conceptually, on a grid of display cells, rather than strings:

- utf8 bytes are decoded into cell payloads
- the cells live in 2d *grids* which live in *screens*
- higher-level UI elements such as prompt, status, and messages render onto these screens 

tty output is only the transport for those already-rendered screens, essentially a wire protocol for tmux to communicate its model of screen state to a terminal. 

If something still goes wrong, the question is usually not "is UTF-8 broken?" but rather, "which layer made the wrong display decision?"

## The Stack

### Bytes and decode

`src/utf8.zig` owns the basic byte-to-display substrate, built around `Utf8Data` type.

This layer is about interpreting incoming bytes and reasoning about display width, not about where text eventually appears on screen.

#### Bytes and decode | Byte Combine Policy

UTF-8 has some messy bits. A critical correctness factor that can "lurk" undetected is the right mapping from codepoints to glyphs. Mostly these are one-to-one but quite a few many-to-one mappings exist along with some other structural complexities. To get it right we must answer the questions:

- Should this new codepoint merge with the previous glyph?

- If it merges, what display width does the combined thing occupy?

- How should cursor movement, trimming, selection, and redraw treat the result?

Examples of less simple mappings:

1) emoji + skin-tone modifier should behave like one displayed glyph even though, lexically, these are represented as two emojis in the data-stream, one for type of emoji and one for skin-tone.

2) Furthermore within a lexical utf-8 character, there can also be *variation selectors* which, for example, differentiate old-style black-and-white from color emoji. These codepoints modify the preceding glyph in the stream instead of taking their own cell.

3) Two regional indicators can combine into one flag glyph

4) ZWJ sequences can join multiple emoji into one visible unit

5) Hangul jamo can compose into one syllabic unit

In the code-base that lives mostly in `src/utf8-combined.zig`'s `utf8_should_combine` and the Hangul helpers. It feeds the wider display-cell machinery in `src/utf8.zig`.

### Display-cell utilities

- `src/utf8.zig` also exposes the shared consumer helpers like
  `displayWidth`, `trimDisplay`, `padDisplay`, `CellBuffer`, and
  `CellBufferReader`.
- These are the helpers higher layers should use when they need display width,
  trimming, word motion, or range walking.
- This is the layer where codepoint-width, combining, and word-boundary bugs
  usually live.

### Grid and screen storage

- `src/grid.zig` stores actual cells, not abstract strings.
- `src/screen.zig` wraps a grid with cursor state, style state, selection,
  hyperlinks, and other terminal-facing screen metadata.
- `src/screen-write.zig` is the shared mutation path for writing cells into a
  screen and copying between screens.
- This is the runtime substrate for "what is in the buffer", independent of how or whether it is visible.

### UI renderers

- `src/status-prompt.zig` owns prompt editing state, prompt-local scrolling,
  cursor position within the input, and prompt history/edit behavior.
- `src/status.zig` owns status rendering and the prompt/message overlay draw
  logic.
- `src/status-runtime.zig` owns lifetime of the prompt/message overlay screen
  and the related timers.
- After the recent convergence work, this now follows the tmux shape closely:
  `status.screen` is the persistent base status screen, and `status.active` is
  the overlay screen used while a prompt or message is active.

### TTY and payload transport

- `src/tty-draw.zig` turns already-rendered screens into ANSI payloads.
- `src/server-client.zig` assembles pane, border, scrollbar, status, and
  overlay payloads for attached clients.
- `src/tty.zig` handles terminal mode and cursor-style/colour negotiation.
- `src/server-print.zig` is the direct output path for attached view-mode and
  detached/control-client printing, and it now shares the sanitized escaped-byte
  path with the rest of the runtime.

This last layer should not be deciding text semantics. It should be moving
already-decided display cells to the outer terminal.

## The Status / Prompt / Message Path

This is the part that was structurally wrong before and now has the right
implementation shape.

### Base status

- `status_redraw` updates `client.status.screen`
- that screen is the persistent base status screen
- status-format expansion and clickable ranges are cached there

### Prompt or message overlay

- entering a prompt or message pushes `client.status.active`
- redraw starts by copying `client.status.screen` into `client.status.active`
  with `screen_write_fast_copy`
- prompt or message content is then drawn on top of the copied base
- `status.render` renders whichever screen is currently authoritative:
  `active` if an overlay is present, otherwise `screen`

This matters because prompt/message rendering is no longer a parallel ad hoc
temporary-screen story. It is now literally "base screen plus overlay", just
like tmux.

### Prompt formatting

- prompt label expansion and prompt input geometry now share the same
  `message-format` expansion path
- `prompt_input` is a real format variable now, instead of being faked through
  `message_text`
- prompt cursor style and colour now live on the overlay screen, so payload
  output and cursor behavior come from the same render state

That means prompt width, visible input window, and final cursor position are
all computed from one consistent model instead of parallel approximations.

## What This Fixes Conceptually

Before this work, a status or prompt bug could come from two very different
causes:

- lower UTF-8 / display-width logic was wrong
- status/prompt/message were taking different runtime paths and disagreeing

Now the second class is much smaller.

That does not mean every Unicode-sensitive edge case is solved. It means the
remaining bugs are much more likely to be honest lower-layer parity bugs rather
than architecture drift.

## Where Bugs Are Still Most Likely

If we hit more issues here, they will probably look like one of these:

- width disagreements for emoji, combining sequences, or ambiguous-width
  characters
- clipping or trimming mistakes at line edges
- cursor placement drift around wide or combining text
- prompt editing or search boundaries that disagree with tmux on multicodepoint
  input
- cell-combine policy mismatches in the lower substrate

Those are real bugs, but they are narrower and easier to localize than the old
"status runtime shape is wrong" class.

## How To Debug A Future Text Bug

When something looks wrong, walk down this ladder:

1. Is the input being decoded into the right display cells?
   Check `src/utf8.zig`.
2. Is width or trimming wrong?
   Check `displayWidth`, `trimDisplay`, `padDisplay`, `CellBuffer`, and
   `format_width`.
3. Is the screen storing the right cells?
   Check `src/grid.zig`, `src/screen.zig`, and `src/screen-write.zig`.
4. Is the UI renderer building the right screen?
   Check `src/status-prompt.zig`, `src/status.zig`, or the relevant mode.
5. Is the transport faithfully emitting that screen?
   Check `src/tty-draw.zig`, `src/server-client.zig`, or `src/server-print.zig`.

That order matters. If we start at the tty layer for a prompt-width bug, we
usually waste time.

## Current Bottom Line

- The implementation shape is now correct enough that tmux and zmux are telling
  the same kind of story about text rendering.
- The remaining z-to-t gap is mostly lower-level parity detail, not major
  runtime architecture.
- Future UTF-8-sensitive bugs should be treated as focused parity fixes in the
  relevant layer, not as evidence that a separate display-cell adoption project
  is still unfinished.

## Library Rule

`utf8proc` may help as a backend width or conversion helper, but it should not
become the semantic model. The semantic model stays tmux-shaped and
display-oriented.

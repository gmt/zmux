# Kitty Graphics Protocol Support

Universal image protocol support for zmux: kitty and sixel clients
transparently muxed/demuxed across kitty and sixel backends.

## Goal

Any combination of {kitty, sixel} client talking through zmux to
{kitty, sixel} terminal works. Multiple clients with mixed capabilities
attached to one session each get the right protocol.

## Strategy: lowest-common-denominator first

Rather than building the full kitty protocol vertically (parse, then
serialize, then bridge), we start horizontally: deliver the feature set
common to both kitty and sixel end-to-end, across all protocol
combinations, before touching anything kitty-specific.

The LCD between kitty and sixel is: "transmit raster pixel data and
display it at a cursor position with given dimensions."  No image IDs,
no z-layering, no virtual placements, no animation, no shared-memory
transport, no delete-by-ID.  Just pixels-at-a-position.  This covers the
real-world use case of inline image display (`chafa`, `timg`, `viu`,
`imgcat`, etc.) and exercises every layer of the mux pipeline.

## Security posture

Images are complex user-controlled data embedded in complex
user-controlled data (VT escape sequences).  tmux sessions can sit at
trust boundaries: VPS providers exposing shells to customers, MUD
clients wrapping untrusted game servers, shared-screen pairing sessions.
The image pipeline must assume the byte stream is not fully friendly:

- Strict bounds checking on declared image dimensions vs actual payload
  size — reject or truncate, never overrun.
- Memory caps enforced before allocation, not after.
- Malformed or truncated payloads handled without panicking — drop the
  image, log a warning, keep going.
- No file-path or shared-memory transmission modes in phase I (those
  open local filesystem/IPC attack surface).

These aren't theoretical: a naughty VPS customer sending a 2³² × 2³²
pixel kitty image to OOM the mux, or a crafted sixel with a palette
index overflow, are the kinds of things that will happen.

## Reference implementations

- **tmux** (`tmux-museum/src/`): sixel pipeline — parse, store, re-serialize
- **Ghostty** (`ghostty-kitty-summary.md`): kitty graphics — full protocol
  except animation. License-compatible; vendored code should be marked as
  such and kept distinct from adapted code.

## Phase I — Kitty/sixel LCD parity

End-to-end image mux for the feature set both protocols share.  By the
end of this phase, a kitty `imgcat` works through zmux to a sixel
terminal and vice versa.

### I.1 — Internal representation uplift

Generalize `Image`/`SixelImage` to hold RGBA pixel data as the canonical
internal format.  Sixel input upconverts on parse; sixel output
downconverts (quantize) on emit.  Existing sixel I/O keeps working
through the new representation — nothing user-visible changes yet.

Key work:
- RGBA u8×4 per pixel as the universal format
- Colour quantization strategy for RGBA → indexed sixel output
- Memory budget: the 20-image global LRU is a count cap; we'll also need
  a byte cap since RGBA images can be much larger than sixel's indexed
  format.  Details TBD but the cap must be enforced pre-allocation.

Likely files: `image.zig`, `image-sixel.zig`, `types.zig`

### I.2 — Kitty basic input parser

Parse kitty APC sequences (`ESC _ G ... ESC \`) for the LCD subset only.
Adapt from Ghostty's `graphics_command.zig` parser.

LCD scope:
- Command parsing (key=value pairs + base64 payload)
- Transmit action: **direct only** (`t=d` or unspecified) — no file,
  temp-file, or shared-memory
- Pixel format: RGB (`f=24`) and RGBA (`f=32`)
- Chunked transfer (`m=1` continuation)
- Query action (`a=q`) — respond with image-received or error
- Display action (`a=T` or `a=t` then `a=p`) at cursor position
- Response encoding back to PTY

Explicitly deferred:
- Image IDs and placement IDs (accept and ignore)
- Delete actions (accept and ignore)
- File/temp-file/shared-memory transmission
- Virtual placements (U+10EEEE)
- Animation frames
- Z-layering / composition modes

Likely files: `input.zig`, new `image-kitty.zig`

### I.3 — Capability advertisement

Detect whether each attached client's terminal supports kitty graphics,
sixel, or neither.  Communicate the supported backend representations so
the output path knows what to emit.

Mechanisms:
- Kitty: query/response (`a=q` with `i=31` and check response), or
  `TERM`-based heuristic (`xterm-kitty`, `xterm-ghostty`)
- Sixel: existing detection path (DA2 response / terminfo `Sxl`)
- Expose per-client capability flag in the tty/client structure

Likely files: `tty.zig`, `tty-term.zig`, `tty-features.zig`

### I.4 — Kitty basic output serializer

Emit kitty APC sequences for clients whose terminal advertises kitty
graphics support.  LCD scope only: direct RGBA transmission, display at
cursor position.

- APC framing from stored RGBA data
- Chunking for large images (kitty's 4096-byte chunk limit)
- Integration with existing `tty-draw.zig` image rendering path:
  `append_sixel_images` becomes protocol-aware, dispatching kitty APC or
  sixel DCS per client

Likely files: `tty-draw.zig`, new or extended `image-kitty.zig`

### I.5 — Cross-protocol bridging and multi-client fan-out

The point of the whole exercise: a kitty image in → sixel image out (and
vice versa), with N clients getting the right format.

- **Kitty in → sixel out**: zmux acts as the kitty server.  Synthesize
  OK response locally.  Store as RGBA.  Emit as sixel DCS (via
  quantization from I.1).
- **Sixel in → kitty out**: Parse sixel, upconvert to RGBA.  Emit as
  kitty APC.
- **Mixed clients**: each `tty_cmd` image render dispatches per-client
  based on capability flags from I.3.

This is mostly wiring — the parsers and serializers from I.2/I.4 do
the real work; this step routes to the right one per attached client.

Likely files: `tty-draw.zig`, `image.zig`

## Phase II — Full kitty scope definition

Before implementing kitty features beyond the LCD, figure out what "full
kitty for zmux" actually means.  Not all kitty features make sense in a
multiplexer context, and some have no sixel analogue at all.

Questions to resolve:
- **Image IDs and placement IDs**: zmux needs to namespace these per-pane
  and rewrite them on output.  What does that mapping look like?
- **Z-layering**: kitty allows images behind and in front of text.  How
  does this interact with pane borders and status lines?
- **Virtual placements (U+10EEEE)**: do these even survive multiplexing,
  or does zmux need to resolve them to real placements on output?
- **Delete actions**: delete-by-ID, delete-by-position, delete-all —
  which are meaningful through a mux and which are ambiguous?
- **Shared-memory / file transmission**: opens local filesystem surface.
  Meaningful in a mux?  Or always translate to direct on the way out?
- **Animation**: punt?  Ghostty stubs it too.
- **Memory limits**: per-pane byte budget?  Per-session?  Global?
  Ghostty defaults to 320MB.

Deliverable: an updated version of this doc with specific decisions for
each feature and a phase III implementation plan.

## Phase III — Full kitty for zmux

Implement whatever phase II decided on.  This is where image IDs,
z-layering, virtual placements, and any other kitty-specific features
get built, based on concrete design decisions rather than speculative
scope.

## zmux-native protocol: don't re-serialize on every redraw

tmux has no protocol-level concept of an image.  On every redraw —
pane switch, scroll, resize, client attach — the server re-serializes
stored pixel data into a fresh sixel DCS byte stream and writes it to
the client's fd.  Same image, same client, full re-encode every time.
`TTY_NOBLOCK` keeps it from stalling the event loop, but the work and
bandwidth are still spent.

In zmux-native mode (not tmux compat) we can do better: make images
protocol objects.  The server transmits pixel data once, keyed by
content hash; subsequent redraws reference the cached image by ID.
Clients hold a local image cache and do their own format-appropriate
serialization (sixel DCS, kitty APC, or whatever they need) from
cached RGBA.

This moves the per-client format decision — and the serialization
cost — to the client where the terminal capability knowledge already
lives, and eliminates redundant retransmission of unchanged pixel data.

Not a phase I concern, but the RGBA canonical store from I.1 is what
makes it possible.  Worth revisiting once the LCD pipeline works.

This also isn't purely optional: full kitty features (image IDs,
z-layering, delete-by-ID, virtual placements) have no representation
in the existing tmux wire protocol.  Extending the protocol for
kitty-specific semantics is unavoidable in phase III — at which point
fixing the re-serialization problem is incremental rather than a
separate project.

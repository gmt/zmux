# Kitty Graphics Protocol Support

Universal image protocol support for zmux: kitty and sixel clients
transparently muxed/demuxed across kitty and sixel backends.

## Goal

Any combination of {kitty, sixel} client talking through zmux to
{kitty, sixel} terminal justworks. Multiple clients with mixed
capabilities attached to one session each get the right protocol.

## Reference implementations

- **tmux** (`tmux-museum/src/`): sixel pipeline — parse, store, re-serialize
- **Ghostty** (`ghostty-kitty-summary.md`): kitty graphics — full protocol
  except animation. License-compatible; vendored code should be marked as such
  and kept distinct from adapted code.

## Phase 1 — Internal representation uplift

Generalize `Image`/`SixelImage` to hold RGBA pixel data as the canonical
internal format. Sixel input upconverts on parse; sixel output downconverts
(quantize) on emit. Existing sixel I/O keeps working through the new
representation — nothing user-visible changes yet.

Key decisions:
- RGBA u8×4 per pixel as the universal format
- Colour quantization strategy for RGBA → indexed sixel output
- Memory budget (kitty images can be large; current 20-image LRU may need
  rethinking)

## Phase 2 — Kitty input parser

Parse kitty APC sequences (`ESC _ G ... ESC \`). Adapt from Ghostty's
`graphics_command.zig` parser. Wire into `input.zig` DCS/APC dispatch.

Covers:
- Command parsing (key=value pairs + base64 payload)
- Transmit actions: direct, file, temp-file, shared-memory
- Chunked transfer (`m=1` continuation) with `LoadingImage` accumulation
- Query action (`a=q`)
- Display and delete actions
- Response encoding back to PTY

## Phase 3 — Kitty output serializer

Emit kitty APC sequences for clients whose terminal advertises kitty
graphics support. Per-client format selection in the tty rendering layer.

Covers:
- Kitty capability detection (query/response or terminfo)
- APC image transmission from stored RGBA data
- Placement semantics (position, z-index)
- Integration with existing `tty-draw.zig` image rendering path

## Phase 4 — Cross-protocol translation

The interesting part: protocol bridging.

- **Kitty client → sixel backend**: zmux acts as the kitty server. Synthesize
  responses locally. Flatten z-layers. Discard IDs on output; re-serialize as
  sixel DCS.
- **Sixel client → kitty backend**: Invent image/placement IDs for positional
  sixel images. Emit as kitty APC with appropriate placement.

Lossy edges to handle gracefully:
- Kitty features with no sixel equivalent (z-layering, virtual placements,
  explicit delete-by-ID)
- Sixel colour model vs RGBA true colour

## Phase 5 — Multi-client fan-out

N clients with mixed capabilities on one session. Each `tty_cmd` image
render dispatches per-client: kitty APC, sixel DCS, or fallback text,
based on that client's advertised capabilities.

This is mostly wiring — the per-protocol serializers from phases 1–3 do
the real work; this phase routes to the right one per attached client.

## Open questions

- Animation frames: punt for now? Ghostty stubs them too.
- Virtual placements (U+10EEEE): worth supporting in phase 2 or defer?
- Should zmux advertise kitty support upstream to clients before the
  backhaul is known, or only when at least one attached terminal supports it?
- Memory limits: per-screen byte budget (like Ghostty's 320MB default)
  vs global image count cap (current 20)?

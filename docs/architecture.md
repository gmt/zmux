# zmux Architecture

This file is the canonical architecture/spec note for the current port. It is
where we describe the stack we want, the semantic gap between that stack and
the current code, and the order in which the remaining substrate should be
built.

`/goodz/work/agents/zmux/utf8-midgame-brainstorm.md` is background and
inspiration only. If it disagrees with this file, this file wins.

## Truth split

There are a few different "sources of truth" in this tranche, and they do not
all answer the same question:

- `/home/greg/src/tmux` is the behavioral oracle. When we need to know what
  tmux does today, read the C.
- this file decides the new stack shape, the allowed seams between layers, and
  the rule against local UTF-8/rendering hacks.
- `/goodz/work/agents/zmux/porting-planning.md` is the queue and reduced-seam
  ledger. If the architecture teaches us something material, record it there.
- `/goodz/work/agents/zmux/TODO.md` is where ugly-but-ported fallout belongs
  once a slice has landed honestly.
- `/goodz/work/agents/zmux/utf8-midgame-brainstorm.md` is noncanonical
  inspiration only.
- `/goodz/work/agents/zmux/NOTES.md` is archival context only. Do not let it
  silently regain authority by accretion.

The split matters because the UTF-8 foundation tranche is not deciding whether
tmux's behavior exists; tmux already answers that. The tranche is deciding
where that behavior should live in the Zig stack so later slices stop solving
Unicode problems locally.

## Current UTF-8 / display problem

The project already has a substantial tmux-shaped UTF-8 substrate:

- `src/types.zig` has `Utf8Data`, `utf8_char`, and `UTF8_SIZE`.
- `src/utf8.zig` has decode helpers, width cache logic, `codepoint-widths`
  overrides, and the shared string/escape helpers.
- `src/utf8-combined.zig` has the ZWJ/variation-selector/Hangul/emoji combine
  policy helpers.
- `src/tty-acs.zig` already owns a reduced ACS-vs-UTF-8 drawing policy seam.

The real semantic gap is below the consumers:

- `src/grid.zig` still behaves like an ASCII-first grid with `set_ascii` /
  `ascii_at`.
- `src/screen-write.zig` still writes byte-at-a-time text with `putc`.
- the live write path does not yet consume the combine helpers from
  `src/utf8-combined.zig`.
- prompt/status/format consumers still lean on a mixture of truthful UTF-8
  helpers and local reduced assumptions.

The refactor goal is therefore not "replace everything with a shiny Unicode
framework." It is:

1. define the top consumer-facing API we actually want,
2. make the lower layers satisfy that API honestly,
3. forbid new local UTF-8/rendering hacks outside that stack while the work is
   underway.

## Build-from-these-materials note

Think of the current code as the material pile:

- hammers and nails: `Utf8Data`, width-cache machinery, `codepoint-widths`,
  `utf8-combined`, `tty-acs`, partial UTF-8 key decoding
- planks of wood: `grid.zig`, `screen.zig`, `screen-write.zig`, and the prompt
  / input / format consumers that already touch text
- blueprints: the stack and matrix below

The instruction to implementers is:

- reuse the existing UTF-8-shaped material wherever it is already truthful
- move consumer behavior onto the stack below instead of inventing new local
  text logic
- if a consumer needs missing semantics, extend the lower layer instead of
  patching around it locally

No new UTF-8, display-width, combine, or rendering workaround should be added
outside the declared stack until the seal matrix says the relevant row is
materially built.

## Current gap ledger

This slice exists to name the real seam in the current code, not just restate
the target API. The lower layers already contain useful truthful substrate, but
that truth still stops before the live grid/write path.

| behavior / seam | already truthful today | still missing before reopen |
|---|---|---|
| byte decode into Unicode key candidates | `src/utf8.zig` already owns `utf8_open`, `utf8_append`, and `utf8_from_data`, and `src/input-keys.zig` already uses them for attached-key decode and encode | there is still no shared consumer-facing `utf8.Decoder` or glyph object, so other consumers can still drift back into local byte handling |
| width policy and overrides | `src/utf8.zig` already owns width cache logic, `codepoint-widths`, `utf8_cstrwidth`, and the trim/pad helpers used by existing string consumers | the live grid/write path still does not preserve width consequences, so width truth currently stops at strings and key helpers |
| combine policy | `src/utf8-combined.zig` already ports tmux's ZWJ, variation-selector, Hangul Jamo, and emoji combine checks | `src/screen-write.zig` never calls that layer, so combined-cell behavior is still unreachable from live pane writes |
| cell payload representation | `src/types.zig` and `src/grid.zig` now expose tmux-shaped `GridCell` payload storage directly: extended-cell offsets, padding-cell storage, `get_cell`/`set_cell`, `cells_equal`, and `line_length` all sit on the same `Utf8Data` and `utf8_char` model | the live write path and most readers still only exercise ASCII compatibility shims, so storage truth exists below them but is not yet the shared end-to-end path |
| live screen-write integration | `src/input.zig` already routes terminal parser events through shared `screen-write` entry points instead of writing directly into panes | those entry points are still byte-at-a-time `putc`/`putn` helpers over `grid.set_ascii`/`ascii_at`, so they collapse glyph semantics back to ASCII storage |
| consumer adapters | `src/format.zig`, `src/input-keys.zig`, and `src/tty-acs.zig` already reuse shared UTF-8 helpers instead of rolling their own width tables | `src/status-prompt.zig` still edits raw UTF-8 byte buffers, and there is no shared display-cell editing/search surface for prompt/status consumers yet |
| ACS / tty output policy | `src/tty-acs.zig` already owns the reduced ACS-versus-UTF-8 border lookup seam | `tty-term` and richer capability runtime are still missing, so this remains a reduced lower seam rather than the full tty output policy layer |

The practical reopen gate is therefore not "add more UTF-8 helpers." It is
finishing the remaining ASCII-only write/consumer seam in
`src/screen-write.zig`, `src/input.zig`, and the prompt/status consumers now
that `src/grid.zig` can already preserve truthful cell payloads underneath
them.

The seal matrix below stays conservative on purpose: lower-layer truth does not
reopen anything by itself. A row is only sealed when the future shared
consumer-facing surface exists and the row stays truthful all the way through
storage, live write-path integration, and the final adapter or tty seam.

## Target stack

### Highest layer: consumer-facing text/cell operations

Consumers should eventually be able to ask for these operations without caring
which low-level helpers make them work:

- decode terminal input bytes into key/glyph candidates
- represent one display glyph or cell payload
- measure display width with the same policy everywhere
- trim or pad text by display cells, not raw bytes
- write one glyph/cell into a screen/grid
- compare and search grid cells by their stored payload
- edit prompt/status text in display-cell terms

The target consumer surface should converge on a small set of shared entry
points, even if the first implementation is just a façade over existing code:

- `utf8.Decoder`
- `utf8.WidthPolicy`
- `utf8.Glyph` or `utf8.CellPayload`
- `screen_write.putGlyph` or an equivalent cell-aware write path
- `displayWidth`, `trimDisplay`, and `padDisplay`
- prompt/key helpers that consume the same width/glyph model

The current foundation checkpoint now lands the named façade in code:

- `src/utf8.zig` exports `utf8.Decoder`, `utf8.WidthPolicy`,
  `utf8.Glyph`/`utf8.CellPayload`, and the top-level `displayWidth`,
  `trimDisplay`, and `padDisplay` entry points
- `src/types.zig` now gives `Utf8Data` and `GridCell` small payload-oriented
  helpers so future grid work can stay on the same model instead of reaching
  into raw fields everywhere

That landing is intentionally thin. `utf8.Glyph` is still a wrapper around the
tmux-shaped `Utf8Data` payload rather than a new ownership layer, and
`utf8.WidthPolicy` is currently a façade over the shared global width cache and
`codepoint-widths` override machinery that already lived below it. The point of
this slice is to name the top of the stack explicitly so later work can build
under it, not to claim that the lower rows are suddenly sealed.

The next checkpoint down is now also landed in code:

- `src/grid.zig` stores `GridCell` payloads through a tmux-shaped direct cell
  API with extended-cell offsets, padding-cell storage, cell equality, and
  line-length helpers
- the legacy `set_ascii` / `ascii_at` entry points remain only as compatibility
  shims over that storage so the rest of the tree can keep moving while
  `screen-write` and higher consumers are rebuilt

That storage landing removes the old ASCII-only grid format blocker, but it
still does not seal the live write or consumer rows by itself because the main
writers and readers have not adopted the richer path yet.

### Lower layers: what the top layer sits on

The stack beneath the consumer surface should be understood in this order:

1. byte decode / scalar conversion
2. width policy and overrides
3. combine policy
4. glyph / cell payload representation
5. grid and screen-write integration
6. consumer adapters

`utf8proc` may be used only as a backend helper for width/property/convert
behavior. It must not become the semantic model. The semantic model stays
tmux-shaped.

### Ownership by layer

The stack above is directional. Consumers may depend downward; they should not
grow their own Unicode sub-engines sideways.

| layer | owns | must not do |
|---|---|---|
| consumer-facing operations | `displayWidth`, trim/pad, prompt/status editing contracts, key/glyph-facing APIs | call width/combine logic ad hoc or stash local rendering exceptions |
| consumer adapters | `status-prompt`, `input-keys`, future `format-draw`/`status` call sites | invent an alternate glyph model or bypass shared cell semantics |
| grid and screen-write integration | live write-path combination, padding-cell consequences, cell-aware writes | treat text as raw bytes once a glyph/cell payload exists |
| glyph / cell payload | `Utf8Data`, `utf8_char`, `GridCell.data`, compact cell storage decisions | embed consumer-specific policy or tty capability decisions |
| width / combine / decode helpers | byte decode, scalar conversion, width cache, `codepoint-widths`, combine checks | patch over missing grid or consumer behavior locally |
| tty output policy | ACS-versus-UTF-8 output choice and capability-sensitive emission | redefine glyph width/combine semantics owned by the shared stack |

When a consumer needs a missing semantic, add it at the lowest truthful layer
that can serve every caller above it, then pull the caller onto that shared
path. Do not fix the immediate consumer in place and promise to clean it up
later.

## Seal matrix

This matrix is the anti-demon seal. If a row is not sealed, do not solve that
consumer with a local hack.

Legend:

- `Y`: this layer already serves the row truthfully today
- `B`: this layer is a live blocker or collapse point today
- `-`: this row does not materially depend on that layer

The named top-of-stack façade now exists in `src/utf8.zig`, but the matrix
stays conservative: giving the shared path names does not by itself repair the
ASCII-first grid, live write path, or raw-byte prompt editor beneath it. Rows
seal only when callers actually ride that façade through truthful lower layers.

| behavior row | decode / convert | width policy | combine policy | glyph / cell storage | grid / screen-write | consumer adapter | current seal |
|---|---|---|---|---|---|---|---|
| decode byte stream into Unicode key or glyph candidates | `Y` | `-` | `-` | `Y` | `-` | `Y` | open: `utf8.Decoder` now names the shared path, but only a narrow set of callers materially depend on it yet |
| compute width with cache and `codepoint-widths` overrides | `Y` | `Y` | `-` | `Y` | `B` | `Y` | open: width truth exists for strings, but the live grid/write path still drops it |
| append zero-width / ZWJ / VS / Hangul / emoji modifiers into the prior cell | `Y` | `Y` | `Y` | `Y` | `B` | `-` | open: combine logic is ported below, but `screen-write` never calls it and there is no padding-cell path yet |
| store one display glyph in one grid cell | `-` | `-` | `-` | `Y` | `B` | `-` | open: direct grid storage now preserves extended and padding cells, but no live writer or higher consumer materially depends on that path yet |
| write/render cells through the live `screen-write` path | `-` | `Y` | `Y` | `Y` | `B` | `-` | open: the write path is still `putc`/`putn` over ASCII shims even though the grid can now preserve richer cells underneath |
| trim, pad, and search by display cells | `Y` | `Y` | `-` | `Y` | `B` | `Y` | open: string trim/pad is shared and the grid now has truthful cell equality/length substrate, but shared search/edit consumers still stay byte-oriented |
| edit prompt/history/status text by display cells | `Y` | `Y` | `Y` | `B` | `-` | `B` | open: prompt/status editing still operates on raw UTF-8 byte buffers instead of shared cell payloads |
| choose ACS versus UTF-8 output honestly | `-` | `-` | `-` | `Y` | `-` | `B` | open: `tty-acs.zig` owns a reduced lookup seam, but `tty-term` capability/runtime truth is still missing |

The current read of the matrix is deliberately blunt:

- row 1 now has a named shared façade, but it is not sealed until real caller
  adoption stops local byte handling from creeping back in
- rows 2 and 3 are still unsealed because the live grid/write path collapses
  width and combine truth before they reach stored cells
- row 4's storage blocker is gone for direct grid callers, but it is not
  sealed until a real writer and reader ride the shared path instead of the
  compatibility shims
- rows 5 through 7 are now blocked mainly by the ASCII live-write and
  prompt/status consumer seams rather than the raw cell storage format itself
- row 8 is a truthful reduced helper, not yet the full tty output policy layer

The foundation tranche is finished enough to reopen UTF-8-sensitive parity work
only when the relevant rows are substantively checked off in code and tests,
not just described here.

## Recommended implementation order

1. Keep the shared consumer-facing façade stable and explicit while the lower
   layers move underneath it.
2. Make grid/cell storage stop being ASCII-first.
3. Make `screen-write` consume cell-width/combine semantics.
4. Rewire prompt/status/format consumers onto the shared stack.
5. Only then resume ordinary low-hanging work on files such as
   `format-draw.c`, `status.c`, `tty-keys.c`, and remaining `utf8.c` fallout.

## Ralph foundation-mode contract

During the UTF-8 foundation tranche:

- coherent breaking commits are allowed
- focused build/test green is welcome but not mandatory for every checkpoint
- the planner and this architecture note must stay honest every round
- `ACCEPT: yes` is not allowed from foundation tasks
- no new local UTF-8/rendering hacks outside this stack
- soft pause boundaries must still end clean: either a commit or a hard reset

The foundation queue should therefore lead with:

1. architecture/spec canonicalization
2. semantic gap + seal matrix
3. consumer-facing façade definition
4. grid/cell storage rewrite
5. `screen-write` combine/width integration
6. consumer adoption

Only after that should UTF-8-sensitive tmux file slices come back to the head
of the line.

## Foundation-tranche adjustments to unwind later

The current Ralph loop and planner carry a few deliberate temporary
adjustments so this tranche can proceed as a bounded refactor instead of a
normal parity march. Do not let these turn into invisible permanent policy.

When the UTF-8 foundation tranche is materially complete, review and either
remove or deliberately keep each of these:

1. `foundation:*` queue items at the head of
   `/goodz/work/agents/zmux/porting-planning.md`.
   - Temporary purpose: keep Ralph building the declared stack before ordinary
     UTF-8-sensitive tmux slices reopen.
   - Unwind action: replace the foundation queue head with ordinary low-hanging
     file slices once the matrix says those files are fair game again.
2. Foundation-mode prompt relaxations in
   `/goodz/work/agents/zmux/tools/ralph/gmt3-proxy.py` and
   `/goodz/work/agents/zmux/tools/ralph/attic/ralph-legacy`.
   - Temporary purpose: allow coherent breaking checkpoints, optional focused
     verification, and mandatory `ACCEPT: no` while the substrate is being
     rebuilt.
   - Unwind action: restore normal Ralph slice expectations for the affected
     area so UTF-8-sensitive parity work returns to the same acceptance and
     verification discipline as the rest of the port.
3. The controller-side tranche boundary stop in
   `/goodz/work/agents/zmux/tools/ralph/gmt3-proxy.py`.
   - Temporary purpose: stop the loop after the foundation tranche even if
     ordinary low-hanging work still exists, so we can inspect the result
     before rejoining the main war path.
   - Unwind action: remove or replace that stop once we are ready for UTF-8
     follow-on work to flow back into the ordinary queue.
4. The "brainstorm is noncanonical" split between this file and
   `/goodz/work/agents/zmux/utf8-midgame-brainstorm.md`.
   - Temporary purpose: let us mine ideas without letting the brainstorm note
     silently overrule the real spec.
   - Unwind action: either archive the brainstorm note or fold any surviving
     useful ideas into this document so future work is not haunted by both.

The clean-pause rule is intentionally not on this unwind list. First `Ctrl-C`
ending at a clean boundary is generally useful and should stay unless it proves
harmful outside the UTF-8 tranche.

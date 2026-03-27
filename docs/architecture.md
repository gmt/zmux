# zmux Architecture

This file is the canonical architecture/spec note for the current port. It is
where we describe the stack we want, the semantic gap between that stack and
the current code, and the order in which the remaining substrate should be
built.

inspiration only. If it disagrees with this file, this file wins.

## Truth split

There are a few different "sources of truth" in this tranche, and they do not
all answer the same question:

- `tmux` is the behavioral oracle. When we need to know what
  tmux does today, read the C.
- this file decides the new stack shape, the allowed seams between layers, and
  the rule against local UTF-8/rendering hacks.
  ledger. If the architecture teaches us something material, record it there.
  once a slice has landed honestly.
  inspiration only.
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

The real semantic gap is now mostly at the consumer and side-effect seams:

- `src/grid.zig` can now store truthful `GridCell` payloads, but broader
  reader/search/editor consumers still have not all adopted that shared cell
  model.
- `src/screen-write.zig` now writes through `putGlyph` / `putCell` /
  `putBytes` and consumes `src/utf8-combined.zig` during live pane writes,
  but it is still reduced relative to tmux `screen_write_cell` side effects.
- prompt/status/format consumers now share the default status-row renderer,
  but the broader prompt runtime, persisted range consumers, and the remaining
  status/message runtime still lean on reduced assumptions.

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
| byte decode into Unicode key candidates | `src/utf8.zig` now owns the named `utf8.Decoder`/`utf8.Glyph` façade on top of `utf8_open`, `utf8_append`, and `utf8_from_data`, and `src/input.zig` plus `src/input-keys.zig` now materially use that shared decode model | prompt/status and the remaining display consumers still have not all adopted the same shared decode surface, so local byte handling can still creep back in above the writer |
| width policy and overrides | `src/utf8.zig` already owns width cache logic, `codepoint-widths`, `utf8_cstrwidth`, and the trim/pad helpers used by existing string consumers, and live pane writes now preserve those width consequences through shared glyph writes | prompt/status/search/edit consumers still stop width truth from sealing end to end because they do not yet operate on shared display cells |
| combine policy | `src/utf8-combined.zig` already ports tmux's ZWJ, variation-selector, Hangul Jamo, and emoji combine checks, and `src/screen-write.zig` now calls that layer during live pane writes | the reduced writer still lacks fuller tmux `screen_write_cell` side effects, so combined-cell reachability exists for live writes but is not yet the full reopen gate |
| cell payload representation | `src/types.zig` and `src/grid.zig` now expose tmux-shaped `GridCell` payload storage directly: extended-cell offsets, padding-cell storage, `get_cell`/`set_cell`, `cells_equal`, and `line_length` all sit on the same `Utf8Data` and `utf8_char` model, and live pane writes now materially store through that path | most readers and prompt/status consumers still have not adopted the same shared cell payload model end to end |
| live screen-write integration | `src/screen-write.zig` now owns `putGlyph`, `putCell`, and `putBytes`, and `src/input.zig` feeds printable terminal bytes through that shared path so live pane writes preserve decoded width, padding, and combine consequences | this is still a reduced `screen_write_cell` seam: insert-mode parity, selected-cell styling, tty draw collection, tab-cell treatment, and non-input consumer adoption are still missing |
| consumer adapters | `src/format.zig`, `src/input-keys.zig`, and `src/tty-acs.zig` already reuse shared UTF-8 helpers instead of rolling their own width tables; `src/status-prompt.zig` now stores prompt input through a shared `utf8.CellBuffer`; `src/options-table.zig` now provides a real default `status-format` array entry; `src/format-draw.zig` + `src/status.zig` now render the default status row through shared list alignment, list markers, translated style ranges, and shared cell writes; `src/status-prompt.zig` now owns cursor-aware prompt editing, vi prompt command mode, and quote-next/control rendering over that shared cell buffer; `src/status-runtime.zig` now owns the reduced shared saved-screen/message-timer lifetime seam; `src/server-fn.zig` now clears active status messages on the attached key path before pane input; `src/alerts.zig` now routes visual alert messages through that shared message runtime; and `src/cmd-command-prompt.zig` now supplies command/target completion vocabulary through a consumer-side callback instead of local byte surgery | there is still no broader shared display-cell search/edit surface for prompt/status consumers, translated style ranges are not yet persisted into a shared hit-test consumer, and the remaining status/message runtime gaps are now broader producer adoption, message-log/write-side plumbing, multiline/runtime fidelity, and the rest of the `status.c` surface |
| ACS / tty output policy | `src/tty-acs.zig` already owns the reduced ACS-versus-UTF-8 border lookup seam | `tty-term` and richer capability runtime are still missing, so this remains a reduced lower seam rather than the full tty output policy layer |

The practical reopen gate is therefore not "add more UTF-8 helpers." It is
finishing the remaining reduced screen-write and prompt/status seam now that
live pane writes no longer collapse back to ASCII storage: the current writer
still lacks fuller tmux `screen_write_cell` side effects, and the adopted
prompt path is still only a reduced shared-cell editor/runtime: cursor
motion, history navigation, completion, and shared cursor-window rendering now
exist on the shared path, and prompt command mode plus the reduced
timer/saved-screen lifetime seam now also ride that shared runtime, but
persisted hit-test consumers, broader message-producer adoption, and broader
display-consumer reach are still open.

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
- `utf8.Glyph`, `utf8.CellPayload`, or `utf8.CellBuffer`
- `screen_write.putGlyph` or an equivalent cell-aware write path
- `displayWidth`, `trimDisplay`, and `padDisplay`
- prompt/key helpers that consume the same width/glyph model

The current foundation checkpoint now lands the named façade in code:

- `src/utf8.zig` exports `utf8.Decoder`, `utf8.WidthPolicy`,
  `utf8.Glyph`/`utf8.CellPayload`, `utf8.CellBuffer`, and the top-level
  `displayWidth`, `trimDisplay`, and `padDisplay` entry points
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

That storage landing removed the old ASCII-only grid format blocker. The next
checkpoint down is now also landed in reduced form:

- `src/screen-write.zig` exports `putGlyph`, `putCell`, and `putBytes` over
  the shared `utf8.Decoder`, combine helpers, and direct grid cell API so live
  pane writes can preserve wide/padding/combined cells without dropping back
  to ASCII shims
- `src/input.zig` now feeds printable terminal runs through that shared writer
  and keeps incomplete UTF-8 pending across parser calls instead of forcing the
  live path back into byte-at-a-time writes

That landing makes live pane writes materially depend on the shared glyph
stack, but it is still reduced relative to tmux `screen_write_cell`: insert
mode, selected-cell styling, tty write-list collection, and some edge
conditions remain open, and prompt/status consumers still sit above the shared
cell model.

The next checkpoint down is now also landed in reduced consumer form:

- `src/utf8.zig` now exports `utf8.CellBuffer` as the shared editable
  display-cell surface for prompt-like consumers, built on `utf8.Decoder`,
  `utf8.Glyph`, and tmux-shaped `Utf8Data`
- `src/status-prompt.zig` now stores prompt input through that shared
  cell-buffer model instead of editing raw UTF-8 byte arrays directly
- `src/input-keys.zig` now routes multibyte key decode through the shared
  `utf8.Decoder` path instead of a local `utf8_open`/`utf8_append` loop

That landing removes the raw-byte prompt-storage blocker, but it is still a
reduced consumer checkpoint rather than a reopen gate: the prompt path still
had no status-line renderer, prompt command mode, or timer/overlay runtime,
and `format-draw`/`status`-style display consumers still did not ride the
same shared cell surface.

The next checkpoint down is now also landed in fuller display-consumer form:

- `src/format-draw.zig` now gives format/status consumers a shared renderer
  that handles tmux-style aligned list sections, list markers, fill behavior,
  and translated style ranges while still writing through the shared
  `screen-write` cell path instead of treating expanded formats as byte
  strings
- `src/options-table.zig` and `src/options.zig` now give the session scope a
  truthful default `status-format` array entry so the shared status renderer
  can start from the tmux-shaped consumer contract instead of a local
  left/right stitch-up
- `src/status.zig` now builds the default status/prompt surface on temporary
  shared screens, expands `status-format` and `message-format` through the
  shared formatter, and renders those rows via the same shared cell path
- `src/tty-draw.zig` now emits stored `GridCell` UTF-8 payload bytes to the
  attached client path instead of flattening those cells back to ASCII bytes,
  and `src/server-client.zig` now redraws attached clients on status-only
  invalidations so the reduced status/prompt renderer is materially reachable

That landing makes the default `format-draw`/`status` status-row path ride the
shared cell model with real window-list/list-marker semantics and translated
style ranges, but it is still well short of tmux reopen criteria: those
ranges are not yet persisted into a shared hit-test consumer, and the rest of
the prompt editor/runtime was still open.

The next checkpoint down is now also landed in shared prompt-editor form:

- `src/utf8.zig` now extends `utf8.CellBuffer` with cursor-facing range,
  delete, and visible-window helpers so prompt/runtime consumers can stay on
  shared display-cell storage instead of reaching back into raw byte edits
- `src/status-prompt.zig` now owns shared cursor motion, delete-at-cursor,
  word motion, history traversal, completion replacement, and cursor-window
  rendering over that shared cell buffer instead of an append/backspace-only
  byte editor
- `src/cmd-command-prompt.zig` now supplies command and target completion
  vocabulary through a consumer-side callback while still relying on the
  shared prompt editor for word finding and replacement
- `src/status.zig` now renders prompt input through the shared prompt cursor
  window instead of assuming append-at-end input visibility

That landing materially closes the old cursor/history/completion gap for the
prompt editor, but it is still not a reopen gate for `status.c` or the
broader prompt runtime: prompt command mode, quote-next/control rendering
parity, message timers, saved-screen overlay behavior, persisted range
consumers, and the rest of the status/message runtime remain reduced.

The next checkpoint down is now also landed in reduced shared prompt/message
runtime form:

- `src/status-runtime.zig` now owns the reduced saved-screen reference-count,
  prompt/message freeze+cursor lifetime, and message timer arm/clear seam so
  prompt and message consumers stop inventing their own overlay lifetime
- `src/status-prompt.zig` now keeps vi prompt command mode and
  quote-next/control rendering on the shared `utf8.CellBuffer` path instead of
  reopening local byte surgery to fake those display semantics
- `src/status.zig` now renders prompt command mode through
  `message-command-style` and escapes ignored message styles on the shared
  formatter path instead of treating those runtime differences as local paint
  hacks
- `src/server-fn.zig` now clears visible status messages before attached pane
  input delivery on the shared key path, and `src/alerts.zig` now routes
  visual alert text through the same shared status-message runtime instead of
  stopping at bells

That landing materially closes the old prompt command mode, quote-next/control
rendering, and timer/saved-screen lifetime gap, but it is still not a reopen
gate for `status.c`: translated ranges are still not persisted into a shared
hit-test consumer, the broader message-log and message-producer write path is
still not shared, and the rest of the multiline/overlay/status runtime remains
reduced.

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
ASCII-first grid, live write path, or the still-reduced prompt/status consumer
layers beneath it. Rows seal only when callers actually ride that façade
through truthful lower layers.

| behavior row | decode / convert | width policy | combine policy | glyph / cell storage | grid / screen-write | consumer adapter | current seal |
|---|---|---|---|---|---|---|---|
| decode byte stream into Unicode key or glyph candidates | `Y` | `-` | `-` | `Y` | `-` | `Y` | open: `utf8.Decoder` now names the shared path, but only a narrow set of callers materially depend on it yet |
| compute width with cache and `codepoint-widths` overrides | `Y` | `Y` | `-` | `Y` | `Y` | `Y` | open: width truth now reaches live pane writes, but prompt/status/search/edit consumers and fuller screen-write parity still stop the row from sealing end to end |
| append zero-width / ZWJ / VS / Hangul / emoji modifiers into the prior cell | `Y` | `Y` | `Y` | `Y` | `Y` | `-` | open: combine logic now reaches live pane writes with padding-cell consequences, but the reduced writer still lacks fuller tmux side effects and higher consumer adoption |
| store one display glyph in one grid cell | `-` | `-` | `-` | `Y` | `Y` | `-` | open: direct grid storage now has a real live writer, but there is still no broader shared reader/search/editor surface above it |
| write/render cells through the live `screen-write` path | `-` | `Y` | `Y` | `Y` | `Y` | `-` | open: live pane writes now use `putGlyph`/`putBytes` over truthful storage and attached-client row emission now preserves stored UTF-8 cell payload bytes, but the writer/runtime is still a reduced seam without tmux's fuller insert/selection/tty collection path |
| trim, pad, and search by display cells | `Y` | `Y` | `-` | `Y` | `B` | `Y` | open: string trim/pad is shared and the reduced status/prompt renderer now consumes those width rules, but shared search/read/edit consumers are still missing and grid-reader-style search remains byte-oriented |
| edit prompt/history/status text by display cells | `Y` | `Y` | `Y` | `Y` | `-` | `B` | open: the shared prompt editor now stores shared cell payloads through `utf8.CellBuffer`, owns cursor motion/history traversal/completion replacement plus prompt command mode/quote-next rendering on that shared path, and the reduced status/message runtime now owns timer and saved-screen lifetime, but persisted range consumers, broader message-producer adoption, and fuller display-consumer reach are still missing |
| choose ACS versus UTF-8 output honestly | `-` | `-` | `-` | `Y` | `-` | `B` | open: `tty-acs.zig` owns a reduced lookup seam, but `tty-term` capability/runtime truth is still missing |

The current read of the matrix is deliberately blunt:

- row 1 now has a named shared façade, but it is not sealed until real caller
  adoption stops local byte handling from creeping back in
- rows 2 through 5 now materially reach the live pane writer, but they remain
  unsealed because the reduced writer still stops short of fuller tmux
  `screen_write_cell` parity and the higher consumer rows have not adopted the
  same shared cell model
- row 4's raw storage blocker is gone and row 5's ASCII collapse is gone for
  live pane writes; the remaining blockers are now fuller reader/editor
  adoption and the reduced side effects around the writer
- row 7's raw prompt-storage blocker is gone, shared cursor/history/completion
  now ride the prompt editor, prompt command mode and the reduced
  timer/saved-screen lifetime seam now ride that same stack, and the default
  status row now rides shared list/range rendering, but the row remains open
  because persisted range consumers, broader message-producer adoption, and
  fuller overlay/runtime semantics are still missing
- rows 6 and 7 are now blocked mainly by remaining prompt/status consumer
  seams rather than by the underlying grid storage format itself
- row 8 is a truthful reduced helper, not yet the full tty output policy layer

The foundation tranche is finished enough to reopen UTF-8-sensitive parity work
only when the relevant rows are substantively checked off in code and tests,
not just described here.

## Recommended implementation order

1. Keep the shared consumer-facing façade stable and explicit while the lower
   layers move underneath it.
2. Make grid/cell storage stop being ASCII-first.
3. Keep the reduced `screen-write` checkpoint honest while the remaining tmux
   side effects are pulled down underneath it.
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
   - Temporary purpose: keep Ralph building the declared stack before ordinary
     UTF-8-sensitive tmux slices reopen.
   - Unwind action: replace the foundation queue head with ordinary low-hanging
     file slices once the matrix says those files are fair game again.
2. Foundation-mode prompt relaxations in
   - Temporary purpose: allow coherent breaking checkpoints, optional focused
     verification, and mandatory `ACCEPT: no` while the substrate is being
     rebuilt.
   - Unwind action: restore normal Ralph slice expectations for the affected
     area so UTF-8-sensitive parity work returns to the same acceptance and
     verification discipline as the rest of the port.
3. The controller-side tranche boundary stop in
   - Temporary purpose: stop the loop after the foundation tranche even if
     ordinary low-hanging work still exists, so we can inspect the result
     before rejoining the main war path.
   - Unwind action: remove or replace that stop once we are ready for UTF-8
     follow-on work to flow back into the ordinary queue.
4. The "brainstorm is noncanonical" split between this file and
   - Temporary purpose: let us mine ideas without letting the brainstorm note
     silently overrule the real spec.
   - Unwind action: either archive the brainstorm note or fold any surviving
     useful ideas into this document so future work is not haunted by both.

The clean-pause rule is intentionally not on this unwind list. First `Ctrl-C`
ending at a clean boundary is generally useful and should stay unless it proves
harmful outside the UTF-8 tranche.

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

- `src/grid.zig` can now store truthful `GridCell` payloads and now also owns
  a reduced `string_cells` seam that capture-style consumers can reuse, but
  broader reader/search/editor consumers still have not all adopted that
  shared cell model.
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
| cell payload representation | `src/types.zig` and `src/grid.zig` now expose tmux-shaped `GridCell` payload storage directly: extended-cell offsets, padding-cell storage, `get_cell`/`set_cell`, `cells_equal`, `line_length`, and a reduced `string_cells` byte-render seam all sit on the same `Utf8Data` and `utf8_char` model, and live pane writes now materially store through that path | most readers and prompt/status consumers still have not adopted the same shared cell payload model end to end |
| live screen-write integration | `src/screen-write.zig` now owns `putGlyph`, `putCell`, and `putBytes`, and `src/input.zig` feeds printable terminal bytes through that shared path so live pane writes preserve decoded width, padding, and combine consequences | this is still a reduced `screen_write_cell` seam: insert-mode parity, selected-cell styling, tty draw collection, tab-cell treatment, and non-input consumer adoption are still missing |
| consumer adapters | `src/format.zig`, `src/input-keys.zig`, and `src/tty-acs.zig` already reuse shared UTF-8 helpers instead of rolling their own width tables; `src/status-prompt.zig` now stores prompt input through a shared `utf8.CellBuffer`; `src/options-table.zig` now provides a real default `status-format` array entry; `src/format-draw.zig` + `src/status.zig` now render the default status row through shared list alignment, list markers, translated style ranges, shared cell writes, and a persisted per-client status-range cache that shared hit-test consumers can query; `src/server-print.zig` now gives `cmdq`, attached show-buffer consumers, and target-pane `run-shell` output one reduced shared attached-output/view-mode seam instead of isolated local writers, now also owns a shared control-client `%message` emission seam, and now also sanitizes reduced direct detached/control print output for non-UTF-8 clients beneath that same lower seam instead of leaving cmdq-style consumers on raw writes; `src/status-prompt.zig` now owns cursor-aware prompt editing, vi prompt command mode, and quote-next/control rendering over that shared cell buffer, and now also routes prompt-side redraw requests through the shared per-client `server_status_client` seam instead of toggling `CLIENT_REDRAWSTATUS` locally; `src/status-runtime.zig` now owns the reduced shared saved-screen/message-timer lifetime seam, logs shared status messages into `server.message_log`, now also owns the shared attached-client message-presentation seam that async `if-shell`/`run-shell`/`cmd-command-prompt` parse or spawn errors reuse instead of writing locally, now also routes those reduced no-item async or parse failures through the shared control-client `%message` path instead of raw stderr writes, now also owns the direct attached command-dispatch parse-error producer instead of leaving that path on raw stderr writes, and now also gives single-result consumers a shared null-target log-only status-message seam instead of queue-client print fallbacks; `src/cmd-queue.zig` now routes reduced command logging plus attached/detached command output through the same shared message-log/write-side seam and now also routes broad command-queue error producers through the shared `status-runtime` presenter so attached overlays, control `%message`, detached sanitized stderr fallbacks, and direct shared print consumers stop forking locally; `src/job.zig` now gives async shell consumers one reduced shared job registry, summary, and `/bin/sh -c` launcher seam with optional captured output or merged stderr, `src/cmd-run-shell.zig` plus `src/cmd-if-shell.zig` now reuse that lower launch/status layer instead of keeping separate child-spawn loops above the stack, and `src/cmd-show-messages.zig` now reports `-J` over that lower seam instead of erroring locally while `-T` now reports the effective shared tty-feature mask instead of raw passthrough bits; `src/server.zig` plus `src/server-fn.zig` now expose a shared pane-only redraw invalidation seam instead of forcing pane-local producers back onto full-window redraws; `src/window-mode-runtime.zig` now owns the reduced pane-mode entry/exit redraw, border, and status invalidation seam that `src/server-print.zig` uses for attached view-mode fallout, while `src/cmd-select-pane.zig`, `src/cmd-send-keys.zig`, and `src/cmd-resize-pane.zig` continue routing pane-local style/reset/history fallout through that shared pane redraw path instead of stopping at `PANE_REDRAW` bits with no attached-runtime follow-through; `src/server-fn.zig` now clears active status messages on the attached key path before pane input, now also applies `focus-follows-mouse` after shared target resolution instead of inventing a local mouse path, now also routes unclaimed pane mouse through the shared pane encoder instead of dropping it, and now also exposes shared border-only redraw invalidation so border-affecting callers stop collapsing onto local status-only glue; `src/alerts.zig` now routes visual alert messages through that shared message runtime; `src/cmd-display-message.zig` now routes the primary `display-message` producer through the shared formatter, attached status runtime, shared `-p` print seam, and control-client `%message` path instead of bypassing the stack; `src/cmd-list-keys.zig` now routes single-line attached-client output and the null-target single-result path through that same shared status-message runtime instead of falling back to ordinary print semantics; `src/cmd-select-pane.zig` and `src/cmd-rename-window.zig` now route pane-title, pane-style, input-off, and rename border fallout through that shared border invalidation seam instead of treating those producers as status-only; `src/cmd-capture-pane.zig` now routes visible-grid and saved-primary-grid capture through the shared `grid.string_cells` seam so stored combined and wide `GridCell` payloads stop collapsing back to `ascii_at` on one more consumer path; `src/window.zig` now gives mouse/runtime consumers one shared full-size pane geometry plus pane/border hit-test helper layer and now also owns shared scrollbar slider geometry plus attached-draw scrollbar layout data; `src/mouse-runtime.zig` now gives attached input plus queued `{mouse}` consumers one reduced shared session/window/pane hit-test and target-resolution seam, including click-sequence and drag-end translation over that lower layer, and now also computes the reduced outer tty mouse-mode request from the active runtime, including `focus-events`, instead of leaving that negotiation implicit; `src/tty-draw.zig` now paints reduced attached scrollbar columns from that shared layout, now also owns reduced border-only and scrollbar-only draw payloads under the shared redraw path, now also owns a reduced full-window multi-pane redraw seam instead of pretending those cells do not exist, and now also exposes reduced dirty-pane payload builders so pane-local runtime producers can repaint only their own bounds; `src/tty-term.zig` now gives the attached client/server path one selected-capability terminfo seam via `identify_terminfo`; `src/tty-features.zig` now derives mouse/bracketed-paste/title/focus truth from that lower seam plus explicit feature bits instead of term-name heuristics, and `src/zmux.zig` now routes `-2`/`-T` requests through that shared parser instead of silently dropping them; `src/tty.zig` now owns the reduced outer tty mouse, bracketed-paste, and focus toggle negotiation plus title emission through that lower seam instead of emitting those sequences unconditionally; `src/cmd-send-keys.zig` now routes queued pane mouse through the same shared pane encoder instead of keeping a mode-only seam; and `src/cmd-command-prompt.zig` now supplies command/target completion vocabulary through a consumer-side callback instead of local byte surgery | there is still no broader shared display-cell search/edit surface for prompt/status consumers, the remaining status/message runtime gaps are now the rest of the multiline/runtime surface plus broader producer coverage beyond the current alerts/cmdq/display-message/list-keys set and the currently adopted async-shell/command-dispatch producers, the new shared job layer is still only a reduced registry plus launcher seam rather than tmux's full bufferevent and file-backed `job.c` runtime, the prompt runtime still lacks a broader shared search/edit surface above the now-shared status-only invalidation seam, `capture-pane` still lacks tmux's fuller history/mode/pending capture semantics, and the new mouse/runtime seam is still reduced relative to tmux `server-client.c` because the redraw matrix is still far smaller than tmux's per-pane/status/overlay machinery, the new border-only, dirty-pane, and scrollbar-only primitives still repaint reduced shared geometry rather than tmux's full screen-redraw matrix, and the tty runtime still exposes only a selected-capability `tty-term` seam rather than tmux's full terminal registry/query surface |
| ACS / tty output policy | `src/tty-acs.zig` already owns the reduced ACS-versus-UTF-8 border lookup seam, `src/tty-term.zig` now gives that seam selected `U8` and `acsc` capability truth from attached-client terminfo, and `src/tty-features.zig` now gives `src/tty.zig` a reduced capability-aware gate for mouse/bracketed-paste/focus/title emission over that same lower seam, with `tty.zig` preferring recorded toggle strings before falling back to standard escape sequences | tmux's richer `tty-term` registry, feature application, string formatting, and broader tty runtime are still missing, so this remains a reduced lower seam rather than the full tty output policy layer |

The practical reopen gate is therefore not "add more UTF-8 helpers." It is
finishing the remaining reduced screen-write and prompt/status seam now that
live pane writes no longer collapse back to ASCII storage: the current writer
still lacks fuller tmux `screen_write_cell` side effects, and the adopted
prompt path is still only a reduced shared-cell editor/runtime: cursor
motion, history navigation, completion, and shared cursor-window rendering now
exist on the shared path, and prompt command mode plus the reduced
timer/saved-screen lifetime seam now also ride that shared runtime. The
remaining open seam is now narrower and more structural: status-row ranges and
message-log/write-side producers now persist on the shared path, but the
broader multiline status/runtime surface, fuller mouse/runtime consumers, and
the rest of the display reach are still open.

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
  API with extended-cell offsets, padding-cell storage, cell equality,
  line-length helpers, and a reduced `string_cells` byte-render helper for
  capture-style consumers
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
  delete, visible-window, and reduced word-reader helpers so prompt/runtime
  consumers can stay on shared display-cell storage instead of reaching back
  into raw byte edits
- `src/status-prompt.zig` now owns shared cursor motion, delete-at-cursor,
  word motion, word deletion, completion replacement boundaries, history
  traversal, and cursor-window rendering over that shared cell buffer instead
  of an append/backspace-only byte editor
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
rendering, timer/saved-screen lifetime gap, persisted status-range cache gap,
and the first shared message-log/write-side producer gap, but it is still not
a reopen gate for `status.c`: the new hit-test consumer still stops at cached
status rows because tmux-style mouse/runtime plumbing is not ported yet, the
shared `server-print`/message-log seam is still reduced relative to tmux's
full `server_client_print` + `file.c` + `window-copy` stack, and the rest of
the multiline/overlay/status runtime remains reduced.

The next checkpoint down is now also landed in reduced multiline/producer form:

- `src/server-print.zig` now owns a small shared control-client `%message`
  writer so status/message producers do not have to hand-roll control-mode
  output
- `src/cmd-display-message.zig` now routes the default attached-client overlay
  path through the shared formatter plus `status-runtime`, reuses the shared
  attached `server-print` view-mode seam for `-p`, and uses that shared
  control `%message` helper for control clients instead of bypassing the
  lower stack
- `src/status.zig` now carries focused regression coverage that pins
  nonzero-`message-line` placement over multi-row status surfaces so the
  shared runtime has an honest multiline checkpoint beneath those producers

That landing narrows the old multiline/runtime-fidelity plus broader-producer
gap, but it is still not a reopen gate for `status.c`: `display-message`
still lacks tmux's `-a`/`-I`/`-v` surface, the rest of the status/message
producer family has not all moved onto the shared path yet, the shared print
seam is still reduced relative to the full `file.c`/window-copy stack, and
fuller mouse/runtime hit-testing plus the remaining overlay/runtime semantics
are still open.

The next checkpoint down is now also landed in reduced mouse/runtime
follow-through form:

- `src/input-keys.zig` now decodes old-style and SGR mouse escape sequences
  into shared `MouseEvent` payloads with per-client last-position/button
  tracking instead of leaving attached mouse input opaque above the decoder
- `src/window.zig` now owns the shared full-size pane geometry and pane versus
  border hit-test helpers that the mouse/runtime consumers share instead of
  recomputing pane extents locally
- `src/mouse-runtime.zig` now owns the reduced attached mouse target
  normalization seam: raw mouse events are translated through persisted
  status-row ranges plus shared pane or border hit testing into shared
  session/window/pane ids and targeted mouse keys, and the same seam now also
  owns click-sequence state plus drag-end translation instead of leaving that
  runtime in `server-fn` callers
- `src/server-client.zig` now owns only the click-timer arm or dispatch
  plumbing for that lower seam instead of growing another mouse classifier
- `src/server-fn.zig` now routes raw attached pane mouse through that shared
  seam into active pane-mode callbacks and shared mouse key bindings and now
  also applies `focus-follows-mouse` after shared target resolution instead of
  leaking raw escape bytes into pane input
- `src/cmd-find.zig` and `src/cmd-send-keys.zig` now resolve `{mouse}` and
  queued mouse targets through the same shared session/window/pane helpers
  rather than maintaining separate pane-id-only shims

That landing makes cached status ranges and active pane-mode mouse handlers
materially reachable from the attached input path and closes the old
double-click timing, drag-end, and border-target gaps, but it is still not a
reopen gate for `status.c` or `server-client.c`: scrollbar hit testing is
still reduced until slider geometry is populated by the draw/runtime path, the
outer tty mouse-mode runtime is still missing, and the coordinate-rich pane
mouse encoder is still missing, so the shared mouse seam deliberately drops
unbound pane mouse instead of pretending that plain pane forwarding is real.

The next checkpoint down is now also landed in narrower producer plus pane
mouse follow-through form:

- `src/input-keys.zig` now owns a shared pane mouse encoder that converts the
  resolved `MouseEvent` plus pane-relative coordinates into SGR, UTF-8, or
  legacy mouse bytes based on the current pane screen mode instead of leaving
  that protocol choice to callers
- `src/server-fn.zig` and `src/cmd-send-keys.zig` now both route unclaimed
  pane mouse through that shared encoder instead of stopping at mode callbacks
  and then dropping the event
- `src/window.zig` now populates shared scrollbar slider geometry from the
  current pane runtime state, and `src/server-client.zig` refreshes that
  geometry on the attached redraw path so hit testing no longer depends on
  preseeded slider values
- `src/cmd-list-keys.zig` now routes single-line attached-client output
  through the shared status-message runtime instead of always writing through
  the print path

That landing narrows the old remaining-producer and pane-encoder gap, but it
is still not a reopen gate for `status.c` or `server-client.c`: the broader
producer family is still not all on the shared runtime, the attached draw path
still does not paint scrollbar columns, and the outer tty mouse-mode runtime
is still missing.

The next checkpoint down is now also landed in narrower attached redraw plus
outer-mode form:

- `src/status-runtime.zig` now owns the direct attached command-dispatch parse
  error producer through the same shared attached-client presentation seam
  instead of leaving that path on raw stderr writes
- `src/window.zig` now exposes shared attached-draw scrollbar layout data on
  top of the existing slider geometry so the draw path consumes the same lower
  seam as hit testing
- `src/tty-draw.zig` now paints reduced attached scrollbar columns from that
  shared layout instead of rendering only pane-text cells
- `src/mouse-runtime.zig` now computes a reduced outer tty mode request from
  the current session options plus pane runtime state instead of leaving mouse
  negotiation implicit in the caller
- `src/tty.zig` now owns the reduced outer tty mouse and bracketed-paste
  sequence negotiation, and `src/server-client.zig` now applies that lower
  seam before attached writes instead of inventing local escape pushes

That landing narrows the old scrollbar-draw and outer-mode gap, but it is
still not a reopen gate for `status.c` or `server-client.c`: broader
status/message producer adoption is still open, the attached redraw path is
still only an active-pane reduced renderer rather than tmux's fuller
multi-pane and scrollbar-only redraw machinery, and the tty runtime still
stops at reduced mouse/bracketed-paste negotiation instead of the full
capability-driven mode surface.

The next checkpoint down is now also landed in narrower shared target-pane
print plus multi-pane redraw form:

- `src/window.zig` now exposes shared attached-draw pane bounds over the same
  full-size geometry that mouse/runtime consumers already use, including the
  left-scrollbar footprint, instead of leaving draw-side offset math private
- `src/tty-draw.zig` now owns a reduced full-window renderer over those
  shared visible-pane bounds so attached draw can place multiple panes at
  truthful offsets instead of assuming the active pane fills the whole client
- `src/server-client.zig` now keeps the cached single-pane fast path only when
  that reduced assumption is actually true and otherwise falls back to the
  shared full-window renderer, so attached redraw stops inventing local
  per-pane geometry below the stack
- `src/server-print.zig` now owns shared target-pane view-mode writes, and
  `src/cmd-run-shell.zig` now reuses that lower seam instead of carrying a
  second raw-output renderer for pane-targeted shell output

That landing narrows the old active-pane-only redraw gap and one concrete
duplicated print seam, but it is still not a reopen gate for `status.c` or
`server-client.c`: broader status/message producer adoption is still open,
the multi-pane draw path is still a reduced full-window clear-and-repaint
renderer rather than tmux's finer border/status-only/scrollbar-only redraw
machinery, and the shared print seam is still reduced relative to tmux's full
`server_client_print` + `file.c` + `window-copy` runtime.

The next checkpoint down is now also landed in narrower shared status-only
redraw form:

- `src/server.zig` now distinguishes shared `server_status_session` and
  `server_status_window` invalidations from full window redraw instead of
  collapsing both onto `CLIENT_REDRAWWINDOW`
- `src/server-fn.zig` now routes status-only callers through that lower seam
  instead of treating status producers as full redraws by default
- `src/server-client.zig` now skips pane-body rendering on pure status
  refreshes, restores the active-pane cursor from shared window geometry when
  only the overlay/status surface changed, and therefore stops forcing the
  multi-pane attached path back through a full-window clear when the shared
  runtime only asked for status/message work

That landing narrows one concrete part of the old redraw/runtime gap: shared
status/message producers can now stay on a real status-only invalidation path
without immediately collapsing multi-pane attached redraw back into the
full-window clear checkpoint. Keep it partial because border-only and
scrollbar-only invalidations still are not lower-layer draw primitives yet,
full redraw still re-renders the reduced status rows opportunistically rather
than through tmux's finer redraw matrix, and the outer tty runtime is still
only a reduced capability/mode seam.

The next checkpoint down is now also landed in reduced border-producer and
tty-capability form:

- `src/server.zig` now exposes shared `server_redraw_window_borders`
  invalidation instead of forcing border-affecting producers to pretend they
  were only status work
- `src/server-fn.zig` now routes that lower seam to callers, and
  `src/cmd-select-pane.zig` plus `src/cmd-rename-window.zig` now use it for
  pane-title, pane-style, input-off, and rename fallout instead of leaving
  those producers on status-only redraw
- `src/server-client.zig` now records client `identify_features` into shared
  `term_features` state instead of dropping that runtime context on the floor
- `src/tty-features.zig` now gives `src/tty.zig` one reduced capability table
  and term-name inference seam, and `src/tty.zig` now gates outer
  mouse/bracketed-paste/title emission through that lower layer instead of
  unconditionally sending those sequences

That landing narrows another honest part of the redraw/runtime gap: some
border-affecting producers now at least land on a shared border invalidation
flag, and outer tty negotiation now depends on one lower capability seam
instead of hard-coded emission in the draw path. Keep it partial because the
attached draw path still does not treat border-only or scrollbar-only work as
true lower draw primitives, the capability layer still leans on reduced
term-name heuristics until `tty-term` lands, and the rest of tmux's tty
feature/runtime surface is still missing.

The next checkpoint down is now also landed in reduced draw-primitive and
selected-capability `tty-term` form:

- `src/client.zig` now ships a selected `identify_terminfo` capability list to
  the server instead of leaving the attached runtime with only term-name
  guesses
- `src/tty-term.zig` now owns the reduced attached terminfo seam: selected
  string and number capabilities can be captured once, queried from `tty`,
  and reused by ACS and outer-mode callers without reopening caller-local
  heuristics
- `src/tty-features.zig`, `src/tty.zig`, and `src/tty-acs.zig` now consume
  that lower seam for mouse/bracketed-paste/title/focus and `U8`/`acsc` truth
  instead of leaning on term-name inference or local `Tty` fields
- `src/tty-draw.zig` now owns reduced border-only and scrollbar-only draw
  payloads, and `src/server-client.zig` now composes those lower draw
  primitives on `CLIENT_REDRAWBORDERS` and `CLIENT_REDRAWSCROLLBARS` instead
  of collapsing both back onto pane-body redraw

That landing narrows two more honest pieces of the redraw/runtime gap:
border-only and scrollbar-only invalidations now have real lower draw entry
points, and attached tty capability truth now enters through one lower
selected-capability seam instead of term-name guesses. Keep it partial
because the redraw matrix is still much smaller than tmux's pane-flag and
overlay machinery, the new border and scrollbar primitives still repaint
reduced shared geometry rather than tmux's full `screen-redraw.c` surface,
and `tty-term` is still only a selected-capability slice instead of tmux's
full terminal registry/query/runtime layer.

The next checkpoint down is now also landed in reduced `show-messages`
formatter and terminal-reporting form:

- `src/format.zig` now resolves shared `message_time` and `message_number`
  fields, and the shared `#{t/...}` modifier now supports tmux-style pretty
  time rendering instead of forcing message-log consumers back onto local time
  formatting
- `src/cmd-show-messages.zig` now renders the default message log through that
  shared formatter path instead of keeping a command-local pretty-time printer
- `src/tty-term.zig` now describes the selected recorded terminfo capability
  slice so `show-messages -T` can report the attached runtime through the same
  lower tty-term seam instead of inventing a second ad hoc terminal dump

That landing narrows one more honest part of the broader producer/runtime gap:
message-log consumers now ride the shared format stack for message fields and
pretty-time semantics, and terminal reporting now reuses the lower selected-
capability tty seam. That checkpoint kept `show-messages -J` blocked until the
missing `job.c`/`file.c` runtime existed, and it stayed partial because the
tty report was still only the selected-capability slice rather than tmux's
full terminal registry and the rest of the broader status/message producer
family still had not all moved onto the shared runtime.

The next checkpoint down is now also landed in reduced shared job-launcher
form:

- `src/job.zig` now owns one shared async job registry with tmux-shaped
  command, fd, pid, and status summary fields, now also owns a reduced
  shared `/bin/sh -c` launcher with optional captured output or merged stderr,
  now also owns a reduced shared async completion bridge over that launcher so
  `run-shell` and `if-shell` stop keeping separate thread-plus-pipe wakeups
  above the stack, and now also owns tmux-shaped kill-on-free plus
  server-exit bulk termination for live reduced jobs instead of leaving async
  shell cleanup to whichever caller happened to notice shutdown first
- `src/cmd-run-shell.zig` and `src/cmd-if-shell.zig` now register reduced job
  lifecycle there and now also reuse that lower launch/status seam instead of
  keeping separate child-spawn or completion loops above the stack
- `src/cmd-show-messages.zig` now reports `-J` through that lower summary seam
  and can combine it with the reduced `-T` report instead of treating job
  summaries as a command-local unsupported branch

That landing narrows another honest part of the broader producer/runtime gap:
`show-messages -J` no longer needs a command-local lie, async shell consumers
now have one shared lower summary plus launch seam instead of disappearing
from the runtime, and reduced live jobs now also die through that same lower
layer on free or server exit instead of depending on consumer-local cleanup.
Keep it partial because the new layer is still far smaller than tmux's full
`job.c` surface: the shared completion bridge is still a reduced
thread-plus-pipe wakeup inside `src/job.zig` rather than tmux's bufferevent
job runtime, there are still no streaming job buffers, no `file.c`-backed
print or read runtime under those jobs, and the broader status/message
producer family plus redraw matrix follow-through are still open.

The next checkpoint down is now also landed in reduced targeted
`refresh-client` redraw form:

- `src/server.zig` now exposes a shared `server_status_client` invalidation
  helper beside the existing session and window status seams instead of
  forcing single-client status refreshes back into command-local flag writes
- `src/cmd-refresh-client.zig` now routes plain refresh and `-S` through the
  shared full-redraw and status-only invalidation seams for the target client
  instead of a current-client-only local redraw shortcut
- `src/cmd-refresh-client.zig` now keeps the supported control-client `-C`
  path explicit and narrow: simple `XxY` or `X,Y` sizes resize the target
  control client through the shared tty/runtime path, while pane offsets,
  subscriptions, clipboard queries, flag twiddles, reports, and window-
  specific control sizes stay honestly unsupported until the lower runtime
  exists

That landing narrows another honest part of the broader redraw/runtime gap:
single-client full redraw and status-only refresh now sit on the same shared
invalidations as the wider runtime instead of reopening a command-local path.
Keep it partial because tmux's pan-mode, subscription, clipboard, report, and
per-control-window size surface are still missing, and the redraw matrix is
still far smaller than tmux's full per-pane/status/overlay machinery.

The next checkpoint down is now also landed in reduced grouped-session
redraw/status form:

- `src/session.zig` now synchronizes grouped session window membership on the
  shared `session_attach` and `session_detach` seams instead of leaving that
  follow-through to `spawn.zig` or ad hoc command-local patches
- `src/server.zig` plus `src/server-fn.zig` now expose shared
  `server_redraw_session_group` and `server_status_session_group`
  invalidation seams instead of collapsing grouped-session fallout back onto
  one session at a time
- `src/cmd-select-window.zig` now routes detached `new-window` fallout
  through the shared group status-only seam and selected `new-window` fallout
  through the shared group redraw seam instead of a single-session redraw
  shortcut

That landing narrows another honest part of the broader redraw/runtime gap:
grouped `new-window` behavior and shared unlink fallout now sit on shared
session attach or detach sync plus shared group invalidation seams instead of
command-local redraw shortcuts. Keep it partial because other grouped-session
mutation paths still need the same follow-through, and the redraw matrix is
still far smaller than tmux's full per-pane/status/overlay machinery.

The next checkpoint down is now also landed in reduced pane-local redraw form:

- `src/server.zig` plus `src/server-fn.zig` now expose a shared
  `server_redraw_pane` invalidation seam for attached clients looking at the
  current pane window instead of forcing pane-local producers back onto
  full-window redraws
- `src/tty-draw.zig` now exposes reduced dirty-pane payload builders on top of
  the existing pane bounds and scrollbar layout data so the attached runtime
  can repaint just the touched pane region without a whole-window clear
- `src/server-client.zig` now consumes `CLIENT_REDRAWPANES` plus `PANE_REDRAW`
  as a distinct attached redraw path, clearing those pane-dirty bits only
  after the reduced pane payload actually lands
- `src/server-print.zig`, `src/cmd-select-pane.zig`,
  `src/cmd-send-keys.zig`, and `src/cmd-resize-pane.zig` now route pane-local
  view-mode/style/reset/history fallout through that shared pane redraw seam
  instead of leaving those producers to set local pane bits without attached
  runtime follow-through

That landing narrows another honest part of the broader redraw/runtime gap:
pane-local producers no longer have to pretend they are full-window redraws,
and the attached path can now repaint one dirty pane worth of shared cell
output without reopening command-local draw logic. Keep it partial because the
new pane-only path still repaints reduced pane bounds rather than tmux's full
per-pane/status/overlay redraw matrix, border and scrollbar work still lives
on separate reduced primitives, and the rest of the runtime still lacks tmux's
pan/subscription/report/control-window refresh surface.

The next checkpoint down is now also landed in narrower alert and shared
view-mode redraw fidelity form:

- `src/alerts.zig` now routes winlink-alert fallout back through the shared
  `server_status_session` seam instead of forcing attached clients onto
  `CLIENT_REDRAWWINDOW` when only status indicators changed
- `src/server-print.zig` now lets shared pane-targeted view-mode writes rely
  on the existing `server_redraw_pane` plus `PANE_REDRAW` path instead of
  widening that producer back to a full-window redraw flag after the lower
  pane seam already exists

That landing narrows another honest part of the broader redraw/runtime gap:
alert flag propagation and shared view-mode output now stay on the smaller
status-only and pane-only seams that the current redraw stack can already
honor. Keep it partial because the overall redraw matrix is still far smaller
than tmux's `status.c` plus `server-client.c` surface, the reduced print seam
still stops well short of the full `server_client_print` + `file.c` +
`window-copy` runtime, and broader producer coverage is still open.

The next checkpoint down is now also landed in reduced shared `file.c`
follow-through form:

- `src/file.zig` now owns one shared reduced file seam over the existing
  detached write IPC slice plus a new synchronous read helper, instead of
  leaving `load-buffer`, `save-buffer`, and config consumers to each reinvent
  path resolution and local file IO
- `src/cmd-load-buffer.zig`, `src/cmd-save-buffer.zig`, `src/client.zig`, and
  `src/server-client.zig` now consume that shared file seam for path
  resolution, detached write runtime handoff, and write-message dispatch
  instead of importing the write-only helper directly or keeping command-local
  read or write branches
- `src/cfg.zig` now reads `source-file` content through the same shared file
  seam, so reduced stdin-backed config loading and the existing relative-path
  behavior stop living behind a config-local "not supported yet" fork

That landing narrows another honest part of the broader print/runtime gap:
buffer and config consumers now share one lower file seam instead of carrying
separate synchronous IO stories above the stack. Keep it partial because this
is still much smaller than tmux's full `file.c` surface: `MSG_READ_*`,
callback-driven completion, shared `client_file` ownership and backpressure,
and the rest of the `server_client_print` + `window-copy` runtime are still
missing.

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
| trim, pad, and search by display cells | `Y` | `Y` | `-` | `Y` | `B` | `Y` | open: string trim/pad is shared and prompt word/search boundaries now ride the lower `utf8.CellBufferReader` surface, but broader shared search/read consumers are still missing and grid-reader-style grid search remains byte-oriented |
| edit prompt/history/status text by display cells | `Y` | `Y` | `Y` | `Y` | `-` | `B` | open: the shared prompt editor now stores shared cell payloads through `utf8.CellBuffer`, owns cursor motion/history traversal/completion replacement plus prompt command mode/quote-next rendering on that shared path, and now also reuses the lower `utf8.CellBufferReader` seam for word motion and delete-word behavior, but persisted range consumers, broader message-producer adoption, and fuller display-consumer reach are still missing |
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
  timer/saved-screen lifetime seam now ride that same stack, the default
  status row now rides shared list/range rendering, and `display-message` now
  uses that shared producer/runtime path, the reduced async-shell and
  command-dispatch failures now also reach control clients through the same
  shared lower `%message` seam, and attached mouse plus `{mouse}` targets now
  reach that cache through a shared lower seam, but the row remains open
  because broader message-producer adoption beyond the current
  alerts/cmdq/display-message/list-keys plus the adopted async-shell and
  command-dispatch set,
  fuller redraw fidelity beyond the reduced active-pane scrollbar path, the
  rest of the tty capability runtime, and fuller overlay/runtime semantics are
  still missing
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

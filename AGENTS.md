Please read COPYING and be sure to add headers to code files as Greg Turner with email gmt@be-evil.net

## tmux-museum: implementation oracle and tmux microscopy

- `tmux-museum/src/` is and must remain an unmodified archive of the
tmux source tree from https://github.com/tmux/tmux

- Do not run autotools (autogen.sh, configure, make) against it
- Do not generate cscope, tags, or any other artifacts inside it
- Do not add, remove, or edit any files in it
- To update it, replace the entire tree with a fresh `git archive` from upstream

In addition to the source, the museum has several "exhibits" which can be built
from the tmux source to help with analsysis of tmux and the how it works.

These "exhibits" may be built using  `tmux-museum/bin/refresh-museum.sh`,
which clones the tmux sources to `tmux-museum/build/src/` and builds from there
in order to keep the `tmux-museum/src/` tree pristene.

## Keeping track of porting

This is for now the hardest problem we face. We need a way to structure our planning without
overstating things in a way that leads to agentic fixation and/or conflicting imperatives.

zmux is a means to an end. That end is: a body of known-good zig terminal multiplexing capability code that is reasonably modular and can be easily vendored or depended on by other zig projects; the means is to start out with a complete and test-driven port of tmux, and then to massage that into a more idiomatic and modular zig terminal interface and multiplexing engine library, while maintaining zmux's initial position downstream of tmux as functional and heavily test-instrumented clone; in short the objective is to learn all of tmux's tricks by firstly being tmux, and thereby stealing all of it's incredible accumulated knowledge of how real-world modern ansi engines work, and secondly, it is hoped, by keeping up with tmux as an upstream and avoiding regressions as this evolution toward a modular library is underway.

To that end there is a two-phase plan; we are currently in the first phase: to port tmux as faithfully as possible. The second phase will be the "evolution" part. We remain in the first phase until the day that our tmux clone implementation is feature complete in every function aspect. This means that everything you could do with tmux, you can now do with zmux, and that, except perhaps for minor timing and naming differences, everything else about those two projects is identical. In other words, again once naming differences have been accounted for, one could take a system with tmux, remove tmux from it, install zmux, run a trivial sed script against the tmux configurations on the system, and continue using it precisely as before. Not just "a" system, of course, but a *any given* system, regardless of which aspects of tmux were relied upon, would need to be able to do this, no matter how obscure the tmux feature. The only exception would be if tmux had a bug: in this case, we would not prefer to duplciate the bug, but rather to help the tmux fix the bug upstream, if at all possible.

In phase two it may be permissible to extend zmux with featues tmux lacks; for now, that is neither an objective nor a planned eventuality. Again, it seems to me to be a bit strange to extend zmux rather than improve tmux, given that we are so nearly a fork, except for the "implementation detail" of being coded in Zig instead of C.

The following rules should be seen in light of the above objectives: they are there to help keep the project on track towards its phase I object of becoming a fully functioning tmux clone with no missing functionality or features:

## `-todo` vs. `-debt`

There are two prominent files in `docs/` which track various sequelae: `docs/zig-porting-todo.md` and `zig-porting-debt.md`. These should be the only two large `*.md` files in `docs/` and they cleanly represent a separation of phase I and phase II porting issues respectively. That is to say:
- anything *not yet ported* from C to Zig goes in `-todo`. There are considered prerequisites to declaring zmux to be a full clone and port of tmux.
- anything *beyond just porting the code* goes in `-debt`. For example right now a ton of very C-shaped and C-flavored code has been created due to aping what tmux is doing. This is by desgin and not a mistake, but neither is it idiomatic or "great" zig code. Making it great would be a phase II question. Making it run bug free with full functionality would be a phase I question. Keeping this straight is ESSENTIAL to keeping our heads screwed on straight about what we are supposed to be working on in this project.

Most shiny things belong in `-debt`. Most boring bugs and, "once disenfrobulation is implemented in zmux, come back and wire dis() to it as tmux does in frobulation.c line 55" types of expressions belong in `-todo`.

to help maintain this and other invariants about our porting effort please also respect the following strict rules about how to maintain the documentation of zmux:

## small, current doc files

- documentation files should always be small, except for zmux-porting-todo.md and zmux-porting-debt.md as mentioned above. parsimony and salience are your friends. splitting stuff up is the way to ensure this.
- documentation must never say what zmux is not, and may only say what zmux *is*. Any this-not-that constructions had better be reformulated to this-because-this-other.
- repair outdated documentation by changing it to reflect the new status quo, not the old. The word "now" should be a red flag that you are about to break this rule. The only options are "now" and in the future and "now" is the default so why are you about to use that word? Usuaully for a prohibited reason. If you would like to document that something has changed in zmux from the way it used to work, or that a formerly incomplete implementation has been reformed to be complete, the correct and only permitted place to do so in the repository is in the commitmsg attached to your commit making that change.
- zmux documentation should be short, simple and salient: stylistically, think: o'reilly, not apress.

## Advanced testing

- docker configured for unprivileged user control is required for some advanced tests but not the main suite
- advanced tests also pull in certain other dependencies like libcaca; try to keep such dependencies strictly
optional.
- TODO: link to detailed testing docs here.

## Cursor Cloud specific instructions

### Prerequisites

- **Zig ≥ 0.15.0** (installed at `/opt/zig-x86_64-linux-0.15.2/zig`, symlinked to `/usr/local/bin/zig`).
- **C dev headers**: `libevent-dev`, `libncursesw5-dev`, `libsystemd-dev`, `libutempter-dev`.

### ncursesw linker-script workaround

Zig's linker cannot parse the GNU ld linker script at `/usr/lib/x86_64-linux-gnu/libncursesw.so`. The update script replaces it with a symlink to the real ELF shared object (`libncursesw.so.6.4`). Without this, `zig build` fails with `UnexpectedEndOfFile`.

### Build / test / run

| Action | Command |
|--------|---------|
| Build | `zig build` |
| Unit tests | `zig build test` |
| Fast smoke tests | `zig build smoke` |
| Run binary | `./zig-out/bin/zmux -V` |
| Start detached session | `ZMUX_TMPDIR=/tmp ./zig-out/bin/zmux -L test -f /dev/null new-session -d -s demo` |

See `docs/testing.md` for the full testing lanes.

### Known issues (pre-existing, not environment)

- `kill-server` may hang; use socket cleanup or `kill` by PID if needed.

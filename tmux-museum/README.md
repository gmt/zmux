# tmux-museum

reference tooling for studying the tmux source

`src` is a pristine copy of the tmux source tree from
https://github.com/tmux/tmux. Do not run autotools, make, cscope,
or anything else that writes to it. To update it, replace the entire
tree with a fresh `git archive` from upstream.

The build script handles all generated material out-of-tree using a
disposable source mirror in `build/src/`:

- `build/src/` — copy of `src/` where autotools runs (gitignored)
- `build/gdb/` — debug build tree
- `out/xref/` — cscope database and tags
- `out/gdb/` — debug binary, symbols, build log
- `out/pp/` — curated preprocessed `.i` files

Convenience symlinks for editor navigation:

- `rebuild/xref`
- `rebuild/gdb`
- `rebuild/pp`

Use:

```bash
bin/refresh-museum.sh
```

Or specific stages:

```bash
bin/refresh-museum.sh xref
bin/refresh-museum.sh gdb
bin/refresh-museum.sh pp
bin/refresh-museum.sh link
```

Default `pp` output is intentionally curated to a small shortlist of hot files.
Pass explicit sources if you want more:

```bash
bin/refresh-museum.sh pp cmd-split-window.c grid.c
```

## Browsing the source

### Interactive cscope session

```bash
bin/museum-cscope
```

Builds the xref database automatically if needed, then opens a full cscope TUI
for navigating function definitions, callers, and callees.

### Quick symbol lookups (scriptable)

```bash
bin/museum-lookup <type> <symbol>
```

| Type | What it finds |
|------|--------------|
| `def` | global definition of symbol |
| `callers` | functions that call this function |
| `callees` | functions called by this function |
| `symbol` | every use of this symbol |
| `text` | literal string |
| `file` | files matching this name |

Examples:

```bash
bin/museum-lookup def screen_alternate_on
bin/museum-lookup callers screen_write_alternateon
bin/museum-lookup callees window_copy_init
```

Output is tab-separated: `file  function  line  text`

### Plain grep

For a quick one-off search without building the database:

```bash
grep -rn "function_name" src/
```

### Protocol tracer

Less 'art-museum' and more 'museum of science and industry' is
the `museum-trace` script, which provides a way to run the
tmux and zmux executables in various configurations and spy
on the socket converstation occuring between the client and the
server i.e.:

```bash
bin/museum-trace capture --zmux --verbose --output /tmp/some.spy-log
```

Which will dump detailed bidirectional protocol conversation
traces into, of course, `/tmp/some.spy-log`, a text file. These
conversations are pretty easy to understand and going forward
this will likely be where much zmux development happens as
although zmux "appears" to work in many cases, it does so in
radically different ways to tmux. It is notable that
already zmux is a competent tmux client and a somewhat OK tmux
server when this tool is used to force the two programs to talk
to each other as if to themselves -- this suggests substantial
feature parity is already in place and behavioral alignment is the
final parity frontier for the project before it is fully useful
as a tmux replacement.

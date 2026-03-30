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

Please read COPYING and be sure to add headers to code files as Greg Turner

## tmux-museum/src is pristine

`tmux-museum/src/` is an unmodified copy of the tmux source tree from
https://github.com/tmux/tmux.  It must NEVER be modified:

- Do not run autotools (autogen.sh, configure, make) against it
- Do not generate cscope, tags, or any other artifacts inside it
- Do not add, remove, or edit any files in it
- To update it, replace the entire tree with a fresh `git archive` from upstream

All build activity goes through `tmux-museum/bin/refresh-labs.sh`, which
uses a disposable build source mirror in `tmux-museum/build/src/` for
anything that writes to the source tree.  The pristine `src/` is used only
for reading and cross-referencing.

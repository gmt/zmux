"zmux is tmux ported to zig. that's it: a fully independent clone of
tmux, called zmux."

... is what I wish this README said. We're getting there but it's still
a work in progress.

By default, zmux keeps its own name and its own namespace. It looks for
zmux config files, creates zmux socket paths, and exports `ZMUX` and
`ZMUX_PANE` into panes. This keeps zmux and tmux from stepping on each
other while the port is still in progress.

zmux can also run in tmux compatibility mode. Invoke the binary with the
basename `tmux` - i.e. by symlinking or renaming it - and it switches
a bunch of 'z's to 't's and tries to act as a drop-in tmux replacement.

```sh
zig build
ln -sf "$PWD/zig-out/bin/zmux" ~/.local/bin/tmux
tmux new
```

In this mode, zmux uses tmux config search paths, tmux socket directory
names, `TMUX` / `TMUX_PANE` environment variables, and tmux-shaped client
protocol behavior (it tries to do this last part either way). 

Recently zmux has gotten close enough to fine that I'm beginning to be able
to dogfood zmux in tmux-replacement mode, using oh-my-tmux configs; it's not amazing
yet, and bugs are not hard to find. But it is starting to work.

Known parity gaps live in `docs/zmux-porting-todo.md`. However, there are probably
a lot more unknown parity gaps, so, you know, caveat emptor, ymmv if you diy. GL!

send patches!

-gmt

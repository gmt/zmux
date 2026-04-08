zmux is tmux ported to zig. that's it! it is a fully independent clone
of tmux, called zmux. it does things like tmux, but where tmux calls
tmux tmux, zmux calls zmux zmux. tmux does not know about zmux. zmux
does not officially know about tmux (well ... for testing purposes).

we do not cross the streams. otherwise there should be complete feature
parity once the port is complete. it is a work in progress

zmux can also run as a drop-in tmux replacement. Symlink or rename the
binary to `tmux` and it will use tmux's socket paths, config files, and
environment variables. This enables dogfooding zmux as your daily driver
without changing your existing tmux configuration.

-gmt

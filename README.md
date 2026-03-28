zmux is tmux ported to zig. that's it! it is a fully independent clone
of tmux, called zmux. it does things like tmux, but where tmux calls
tmux tmux, zmux calls zmux zmux. tmux does not know about zmux. zmux
does not officially know about tmux (well ... for testing purposes).

we do not cross the streams. otherwise there should be complete feature
parity once the port is complete. it is a work in progress

-gmt

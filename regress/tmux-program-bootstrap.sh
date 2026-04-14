#!/bin/sh
# Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# tmux-program-bootstrap.sh – validate oh-my-tmux's TMUX_PROGRAM environment
# bootstrapping chain: run-shell discovers the binary via /proc/PID/exe,
# then propagates TMUX_PROGRAM and TMUX_SOCKET through the global environment.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init tmux-program-bootstrap
smoke_use_real_shell || exit $?

TMUX_LINK="$SMOKE_BIN_DIR/tmux"

# smoke_init already created a tmux symlink, but it may point at the oracle;
# force it to zmux so we test the zmux bootstrapping path.
ln -sf "$TEST_ZMUX" "$TMUX_LINK"

# Build a config that mimics oh-my-tmux's bootstrapping sequence.
# Step 1: discover binary via /proc/PID/exe and set TMUX_PROGRAM.
# Step 2: use TMUX_PROGRAM to set TMUX_SOCKET.
BOOTSTRAP_CONF="$TEST_TMPDIR/bootstrap.conf"
cat >"$BOOTSTRAP_CONF" <<CONF
%if #{==:#{TMUX_PROGRAM},}
run-shell 'exe=\$(readlink /proc/#{pid}/exe 2>/dev/null || echo unknown); "$TMUX_LINK" -S #{socket_path} set-environment -g TMUX_PROGRAM "\$exe"'
%endif
%if #{==:#{TMUX_SOCKET},}
run-shell '"$TMUX_LINK" -S #{socket_path} set-environment -g TMUX_SOCKET "#{socket_path}"'
%endif
CONF

SESSION_NAME="bootstrap"

# Start the server via the tmux symlink, loading the bootstrap config.
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f "$BOOTSTRAP_CONF" \
    new-session -d -s "$SESSION_NAME" || {
    echo "failed to start server via tmux symlink"
    exit 1
}
smoke_register_server_with_socket "$TMUX_LINK" "$TEST_SOCKET" "$TEST_NAME" \
    >/dev/null 2>&1 || true

# Wait for the run-shell chain to complete (config loading is async).
smoke_wait_for 10 smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    show-environment -g TMUX_PROGRAM >/dev/null 2>&1 || {
    echo "TMUX_PROGRAM was never set by run-shell chain"
    exit 1
}

# --- Check 1: TMUX_PROGRAM is set and points to the zmux binary ---
TMUX_PROG=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    show-environment -g TMUX_PROGRAM 2>/dev/null) || {
    echo "show-environment -g TMUX_PROGRAM failed"
    exit 1
}
# Output is "TMUX_PROGRAM=/path/to/binary"; extract the value.
TMUX_PROG_VAL=${TMUX_PROG#TMUX_PROGRAM=}

# The exe link may resolve to the zmux binary itself (not the symlink).
ZMUX_REAL=$(readlink -f "$TEST_ZMUX" 2>/dev/null || echo "$TEST_ZMUX")
PROG_REAL=$(readlink -f "$TMUX_PROG_VAL" 2>/dev/null || echo "$TMUX_PROG_VAL")
[ "$PROG_REAL" = "$ZMUX_REAL" ] || {
    echo "TMUX_PROGRAM mismatch: got '$TMUX_PROG_VAL' (resolves to '$PROG_REAL'), expected '$ZMUX_REAL'"
    exit 1
}

# --- Check 2: TMUX_SOCKET is set and matches the socket path ---
smoke_wait_for 10 smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    show-environment -g TMUX_SOCKET >/dev/null 2>&1 || {
    echo "TMUX_SOCKET was never set by run-shell chain"
    exit 1
}

TMUX_SOCK=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    show-environment -g TMUX_SOCKET 2>/dev/null) || {
    echo "show-environment -g TMUX_SOCKET failed"
    exit 1
}
TMUX_SOCK_VAL=${TMUX_SOCK#TMUX_SOCKET=}
[ "$TMUX_SOCK_VAL" = "$TEST_SOCKET" ] || {
    echo "TMUX_SOCKET mismatch: got '$TMUX_SOCK_VAL', expected '$TEST_SOCKET'"
    exit 1
}

# --- Check 3: /proc/PID/exe resolves to the zmux binary ---
SERVER_PID=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    display-message -p '#{pid}' 2>/dev/null) || {
    echo "failed to read server pid"
    exit 1
}
EXE_LINK=$(readlink "/proc/$SERVER_PID/exe" 2>/dev/null || echo "")
EXE_REAL=$(readlink -f "$EXE_LINK" 2>/dev/null || echo "$EXE_LINK")
[ "$EXE_REAL" = "$ZMUX_REAL" ] || {
    echo "/proc/$SERVER_PID/exe mismatch: got '$EXE_LINK' (resolves to '$EXE_REAL'), expected '$ZMUX_REAL'"
    exit 1
}

# --- Check 4: run-shell child can read TMUX_PROGRAM from its environment ---
MARKER="$TEST_TMPDIR/env-marker"
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" -f/dev/null \
    run-shell "printenv TMUX_PROGRAM > '$MARKER'" || {
    echo "run-shell to read TMUX_PROGRAM from child env failed"
    exit 1
}
# run-shell is async; wait for the marker file.
smoke_wait_for 10 test -s "$MARKER" || {
    echo "run-shell child never wrote TMUX_PROGRAM to marker file"
    exit 1
}
CHILD_PROG=$(cat "$MARKER")
CHILD_REAL=$(readlink -f "$CHILD_PROG" 2>/dev/null || echo "$CHILD_PROG")
[ "$CHILD_REAL" = "$ZMUX_REAL" ] || {
    echo "run-shell child TMUX_PROGRAM mismatch: got '$CHILD_PROG' (resolves to '$CHILD_REAL'), expected '$ZMUX_REAL'"
    exit 1
}

smoke_cleanup_socket "$TMUX_LINK" "$TEST_SOCKET"

exit 0

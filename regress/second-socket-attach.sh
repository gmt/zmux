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

# second-socket-attach.sh – attach to a session from a second distinct socket.
# Exercises two-socket, multi-server client attachment patterns.
# Based on the socket-isolation pattern from tmux/regress/tty-keys.sh.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init second-socket-attach

SOCK1="$TEST_TMPDIR/socket1"
SOCK2="$TEST_TMPDIR/socket2"

zmux1() {
    "$TEST_ZMUX" -S "$SOCK1" -f/dev/null "$@"
}

zmux2() {
    "$TEST_ZMUX" -S "$SOCK2" -f/dev/null "$@"
}

# Start a detached session on socket 1
zmux1 new-session -d -s main || exit 1
zmux1 has-session -t main || exit 1

# Connect from a second socket; it should start a fresh independent server
zmux2 new-session -d -s peer || exit 1
zmux2 has-session -t peer || exit 1

# Sessions on different sockets must be isolated
zmux1 has-session -t peer 2>/dev/null && {
    echo "socket isolation failed"
    exit 1
}
zmux2 has-session -t main 2>/dev/null && {
    echo "socket isolation failed"
    exit 1
}

exit 0

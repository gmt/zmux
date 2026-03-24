#!/bin/sh
# Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_ZMUX" ] && TEST_ZMUX=$(readlink -f ../zig-out/bin/zmux)
ZMUX1="$TEST_ZMUX -Ltest1"
ZMUX2="$TEST_ZMUX -Ltest2"
$ZMUX1 kill-server 2>/dev/null || true
$ZMUX2 kill-server 2>/dev/null || true

TMP=$(mktemp)
trap 'rm -f $TMP; $ZMUX1 kill-server 2>/dev/null; $ZMUX2 kill-server 2>/dev/null' 0 1 15

# Start a detached session on socket 1
$ZMUX1 -f/dev/null new-session -d -s main || exit 1
$ZMUX1 has-session -t main || exit 1

# Connect from a second socket; it should start a fresh independent server
$ZMUX2 -f/dev/null new-session -d -s peer || exit 1
$ZMUX2 has-session -t peer || exit 1

# Sessions on different sockets must be isolated
$ZMUX1 has-session -t peer 2>/dev/null && { echo "socket isolation failed"; exit 1; }
$ZMUX2 has-session -t main 2>/dev/null && { echo "socket isolation failed"; exit 1; }

exit 0

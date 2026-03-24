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

# kill-session-process-exit.sh – killing a session must kill its pane processes.
# Based on tmux/regress/kill-session-process-exit.sh.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_ZMUX" ] && TEST_ZMUX=$(readlink -f ../zig-out/bin/zmux)
ZMUX="$TEST_ZMUX -Ltest"
$ZMUX kill-server 2>/dev/null || true
sleep 1

# Create session with a long-running pane
$ZMUX -f/dev/null new-session -d 'sleep 1000' || exit 1
P=$($ZMUX display-message -p -t 0:0.0 '#{pane_pid}' 2>/dev/null)
[ -z "$P" ] && exit 1

# Create a second session so the server survives kill-session
$ZMUX -f/dev/null new-session -d || exit 1
sleep 1

# Kill the first session
$ZMUX kill-session -t 0:
sleep 3

# The pane process should be gone
kill -0 "$P" 2>/dev/null && { echo "pane process $P still alive"; exit 1; }

$ZMUX kill-server 2>/dev/null || true
exit 0

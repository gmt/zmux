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

# session-group-resize.sh – grouped sessions resize correctly on switch.
# Tests both switch-client and select-window code paths.
# Based on tmux/regress/session-group-resize.sh.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init session-group-resize

TMP1=$(mktemp)
TMP2=$(mktemp)
TMP3=$(mktemp)
trap 'rm -f "$TMP1" "$TMP2" "$TMP3"; smoke_cleanup' 0 1 2 3 15

# Create a session with two windows, staying on window 0
smoke_cmd new-session -d -s test -x 20 -y 6 || exit 1
smoke_cmd new-window -t test || exit 1
smoke_cmd select-window -t test:0 || exit 1

# Attach small 20x6 control client; move it to window 1
(
    echo "refresh-client -C 20,6"
    echo "select-window -t :1"
    sleep 5
) |
    smoke_bin -f/dev/null -C attach -t test >"$TMP1" 2>&1 &

# Wait for client to land on window 1
n=0
while [ $n -lt 20 ]; do
    smoke_cmd list-clients -F '#{client_name} #{window_index}' 2>/dev/null |
        grep -q " 1$" && break
    sleep 0.1
    n=$((n + 1))
done

# Attach a larger 30x10 grouped session; switch-client to window 1
(
    echo "refresh-client -C 30,10"
    echo "switch-client -t :=1"
    sleep 5
) |
    smoke_bin -f/dev/null -C new-session -t test -x 30 -y 10 >"$TMP2" 2>&1 &

# Poll for resize instead of fixed sleep
n=0
while [ $n -lt 20 ]; do
    OUT1=$(smoke_cmd display-message -t test:1 -p '#{window_width}x#{window_height}' 2>/dev/null)
    [ "$OUT1" = "30x10" ] && break
    sleep 0.1
    n=$((n + 1))
done

# Attach a 25x8 grouped session; use select-window instead
(
    echo "refresh-client -C 25,8"
    echo "select-window -t :1"
    sleep 5
) |
    smoke_bin -f/dev/null -C new-session -t test -x 25 -y 8 >"$TMP3" 2>&1 &

# Wait for resize – poll with backoff instead of a blind sleep
n=0
while [ $n -lt 20 ]; do
    OUT2=$(smoke_cmd display-message -t test:1 -p '#{window_width}x#{window_height}' 2>/dev/null)
    [ "$OUT2" = "25x8" ] && break
    sleep 0.1
    n=$((n + 1))
done

[ "$OUT1" = "30x10" ] || {
    echo "switch-client resize failed: $OUT1"
    exit 1
}
[ "$OUT2" = "25x8" ] || {
    echo "select-window resize failed: $OUT2"
    exit 1
}

exit 0

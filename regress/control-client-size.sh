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

# control-client-size.sh – control-mode client resize via refresh-client -C.
# Based on tmux/regress/control-client-size.sh (issue #947).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_ZMUX" ] && TEST_ZMUX=$(readlink -f ../zig-out/bin/zmux)
ZMUX="$TEST_ZMUX -Ltest"
$ZMUX kill-server 2>/dev/null || true

TMP=$(mktemp)
OUT=$(mktemp)
trap 'rm -f $TMP $OUT' 0 1 15

# Start a detached session at default size (80x24)
$ZMUX -f/dev/null new-session -d || exit 1
sleep 1

# Attach in control mode, check initial size, then resize
cat <<EOF | $ZMUX -C attach >"$TMP"
ls -F':#{window_width} #{window_height}'
refresh -C 100,50
EOF
grep ^: "$TMP" >"$OUT"
$ZMUX ls -F':#{window_width} #{window_height}' >>"$OUT"
printf ":80 24\n:100 50\n" | cmp -s "$OUT" - || {
    echo "size mismatch:"
    cat "$OUT"
    exit 1
}

$ZMUX kill-server 2>/dev/null || true

# Test -x/-y with control-mode new
cat <<EOF | $ZMUX -f/dev/null -C new-session -x 100 -y 50 >"$TMP"
ls -F':#{window_width} #{window_height}'
refresh -C 80,24
EOF
grep ^: "$TMP" >"$OUT"
$ZMUX -Ltest ls -F':#{window_width} #{window_height}' >>"$OUT" 2>/dev/null || true
printf ":100 50\n:80 24\n" | cmp -s "$OUT" - || {
    echo "new-session -x/-y size mismatch:"
    cat "$OUT"
    exit 1
}

$ZMUX kill-server 2>/dev/null || true
exit 0

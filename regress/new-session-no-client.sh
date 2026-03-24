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

# new-session-no-client.sh – starting with no client should create a detached
# session and not attach; has-session should find it afterwards.
# Based on tmux/regress/new-session-no-client.sh (issue #869).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_ZMUX" ] && TEST_ZMUX=$(readlink -f ../zig-out/bin/zmux)
ZMUX="$TEST_ZMUX -Ltest"
$ZMUX kill-server 2>/dev/null || true

TMP=$(mktemp)
trap 'rm -f $TMP' 0 1 15

cat <<EOF >"$TMP"
new -stest
EOF

$ZMUX -f"$TMP" start || exit 1
sleep 1
$ZMUX has -t=test: || exit 1
$ZMUX kill-server 2>/dev/null || true

exit 0

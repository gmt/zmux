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

# has-session-return.sh – has-session exit codes and no-server behavior.
# Based on tmux/regress/has-session-return.sh.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_ZMUX" ] && TEST_ZMUX=$(readlink -f ../zig-out/bin/zmux)
ZMUX="$TEST_ZMUX -Ltest"
$ZMUX kill-server 2>/dev/null || true

# has-session with no server running should return non-zero
$ZMUX has-session 2>/dev/null && exit 1

# start a session; has-session should now succeed
$ZMUX -f/dev/null start-server
$ZMUX -f/dev/null new-session -d -s smoke || exit 1
$ZMUX has-session -t smoke || exit 1

# nonexistent session should fail
$ZMUX has-session -t nosuchsession 2>/dev/null && exit 1

$ZMUX kill-server 2>/dev/null || true
exit 0

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

# attach-detach-client.sh – attach and detach a control client without hanging.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init attach-detach-client

OUT="$TEST_TMPDIR/control.out"
ERR="$TEST_TMPDIR/control.err"

smoke_cmd new-session -d -s main || exit 1

(
    printf 'refresh-client -C 90,30\n'
    sleep 5
    printf 'detach-client\n'
) | smoke_bin -f/dev/null -C attach-session -t main >"$OUT" 2>"$ERR" &
CLIENT_PID=$!

n=0
while [ "$n" -lt 20 ]; do
    if smoke_cmd list-clients 2>/dev/null | grep -q .; then
        break
    fi
    sleep 0.2
    n=$((n + 1))
done

smoke_cmd list-clients 2>/dev/null | grep -q . || {
    echo "client never attached"
    exit 1
}

wait "$CLIENT_PID" || exit 1

exit 0

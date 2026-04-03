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

# command-order.sh – same logical commands in one-line vs multi-line form
# should produce identical window/session structure.
# Based on tmux/regress/command-order.sh.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init command-order

TMP1=$(mktemp)
TMP2=$(mktemp)
TMP3=$(mktemp)
TMP4=$(mktemp)
trap 'rm -f $TMP1 $TMP2 $TMP3 $TMP4' 0 1 15

# Config A: multiline commands
cat <<'EOF' >"$TMP1"
new -d -s s1
neww -t s1
neww -t s1
EOF

# Config B: equivalent one-liner (semicolon-separated)
cat <<'EOF' >"$TMP2"
new -d -s s1; neww -t s1; neww -t s1
EOF

smoke_bin -f"$TMP1" start
smoke_cmd list-windows -t s1 -F '#{window_index}' | sort >"$TMP3"
smoke_try_kill_server
sleep 0.5

smoke_bin -f"$TMP2" start
smoke_cmd list-windows -t s1 -F '#{window_index}' | sort >"$TMP4"
smoke_try_kill_server

cmp -s "$TMP3" "$TMP4" || {
    echo "window order mismatch:"
    echo "multiline:"
    cat "$TMP3"
    echo "one-liner:"
    cat "$TMP4"
    exit 1
}

exit 0

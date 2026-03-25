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

# control-notify-smoke.sh – reduced control-mode notify coverage.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init control-notify

TMP=$(mktemp)
trap 'rm -f "$TMP"' 0 1 15

smoke_cmd new-session -d -s notify-a >/dev/null || exit 1
sleep 1

cat <<'EOF' | smoke_bin -f/dev/null -C attach -t notify-a >"$TMP"
new-session -d -s notify-b
rename-session -t notify-b renamed
rename-window -t notify-a:0 mainwin
link-window -s renamed:0 -t notify-a:9
unlink-window -t notify-a:9
capture-pane -t notify-a:0.0 -b controlbuf
switch-client -t renamed
EOF

grep -Eq '^%sessions-changed$' "$TMP" || {
    echo "missing sessions-changed"
    cat "$TMP"
    exit 1
}

grep -Eq '^%session-renamed \$[0-9]+ renamed$' "$TMP" || {
    echo "missing session-renamed"
    cat "$TMP"
    exit 1
}

grep -Eq '^%window-renamed @[0-9]+ mainwin$' "$TMP" || {
    echo "missing window-renamed"
    cat "$TMP"
    exit 1
}

grep -Eq '^%window-add @[0-9]+$' "$TMP" || {
    echo "missing window-add"
    cat "$TMP"
    exit 1
}

grep -Eq '^%unlinked-window-close @[0-9]+$' "$TMP" || {
    echo "missing unlinked-window-close"
    cat "$TMP"
    exit 1
}

grep -Eq '^%paste-buffer-changed controlbuf$' "$TMP" || {
    echo "missing paste-buffer-changed"
    cat "$TMP"
    exit 1
}

grep -Eq '^%session-changed \$[0-9]+ renamed$' "$TMP" || {
    echo "missing session-changed"
    cat "$TMP"
    exit 1
}

grep -Eq '^%client-detached ' "$TMP" || {
    echo "missing client-detached"
    cat "$TMP"
    exit 1
}

exit 0

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

# list-and-display.sh – cover list-* commands and display-message formatting.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init list-and-display

smoke_cmd new-session -d -s main -x 100 -y 40 || exit 1
smoke_cmd new-window -d -t main || exit 1
smoke_cmd split-window -d -t main:1 || exit 1
smoke_cmd select-window -t main:1 || exit 1

smoke_cmd list-sessions -F '#{session_name}' | grep -qx 'main' || {
    echo "list-sessions did not include main"
    exit 1
}

LIST_WINDOWS=$(smoke_cmd list-windows -t main) || exit 1
printf '%s\n' "$LIST_WINDOWS" | grep -Eq '^0: .* \(1 panes\) \[100x40\] \[layout .+\] @[0-9]+$' || {
    echo "list-windows missing tmux-style default details for window 0: $LIST_WINDOWS"
    exit 1
}

printf '%s\n' "$LIST_WINDOWS" | grep -Eq '^1: .* \(2 panes\) \[100x40\] \[layout .+\] @[0-9]+ \(active\)$' || {
    echo "list-windows missing tmux-style default details for active window: $LIST_WINDOWS"
    exit 1
}

LIST_WINDOWS_ALL=$(smoke_cmd list-windows -a) || exit 1
printf '%s\n' "$LIST_WINDOWS_ALL" | grep -Eq '^main:1: .* \(2 panes\) \[100x40\]$' || {
    echo "list-windows -a default format mismatch: $LIST_WINDOWS_ALL"
    exit 1
}

smoke_cmd list-panes -t main:1 | grep -q 'pid=' || {
    echo "list-panes missing pane details"
    exit 1
}

MSG=$(smoke_cmd display-message -p -t main:1.0 '#{session_name}:#{window_index}.#{pane_index} #{window_width}x#{window_height}')
[ "$MSG" = 'main:1.0 100x40' ] || {
    echo "display-message mismatch: $MSG"
    exit 1
}

exit 0

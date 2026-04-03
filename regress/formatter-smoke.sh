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

# formatter-smoke.sh - live-socket formatter integration coverage.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init formatter-smoke
SEND_OUT="$TEST_TMPDIR/send.out"
rm -f "$SEND_OUT"
smoke_use_helper_shell record-stdin "$SEND_OUT" || exit $?

SESSION_PRINT=$(smoke_cmd new-session -d -P -F '#{session_name}' -s fmtcheck) || exit 1
[ "$SESSION_PRINT" = "fmtcheck" ] || {
    echo "new-session -P -F mismatch: $SESSION_PRINT"
    exit 1
}

NEW_WINDOW_PRINT=$(smoke_cmd new-window -d -P -F '#{session_name}:#{window_index}.#{pane_index}' -t fmtcheck) || exit 1
[ "$NEW_WINDOW_PRINT" = "fmtcheck:1.0" ] || {
    echo "new-window -P -F mismatch: $NEW_WINDOW_PRINT"
    exit 1
}

SPLIT_PRINT=$(smoke_cmd split-window -d -P -F '#{session_name}:#{window_index}.#{pane_index}' -t fmtcheck:0.0) || exit 1
[ "$SPLIT_PRINT" = "fmtcheck:0.1" ] || {
    echo "split-window -P -F mismatch: $SPLIT_PRINT"
    exit 1
}

BREAK_PRINT=$(smoke_cmd break-pane -d -P -F '#{session_name}:#{window_index}.#{pane_index}' -s fmtcheck:0.1 -t fmtcheck:2) || exit 1
[ "$BREAK_PRINT" = "fmtcheck:2.0" ] || {
    echo "break-pane -P -F mismatch: $BREAK_PRINT"
    exit 1
}

DISPLAY_EXPR=$(smoke_cmd display-message -p -t fmtcheck:0.0 '#{m:*fmt*,#{session_name}} #{e|+:1,2} #{s/fmt/FMT/:#{session_name}}') || exit 1
[ "$DISPLAY_EXPR" = "1 3 FMTcheck" ] || {
    echo "display-message expression mismatch: $DISPLAY_EXPR"
    exit 1
}

smoke_cmd set-option -g @fmt '#{session_name}/#{window_index}' || exit 1
DISPLAY_E=$(smoke_cmd display-message -p -t fmtcheck:0.0 '#{E:@fmt}') || exit 1
[ "$DISPLAY_E" = "fmtcheck/0" ] || {
    echo "display-message E mismatch: $DISPLAY_E"
    exit 1
}

smoke_cmd set-option -g @clock 'hour:%H' || exit 1
DISPLAY_T=$(smoke_cmd display-message -p '#{T:@clock}') || exit 1
printf '%s\n' "$DISPLAY_T" | grep -Eq '^hour:[0-9][0-9]$' || {
    echo "display-message T mismatch: $DISPLAY_T"
    exit 1
}

WINDOW_LOOP=$(smoke_cmd display-message -p -t fmtcheck:0.0 '#{W:#{window_index}#{?loop_last_flag,,|},[#{window_index}]#{?loop_last_flag,,|}}') || exit 1
[ "$WINDOW_LOOP" = "[0]|1|2" ] || {
    echo "window loop mismatch: $WINDOW_LOOP"
    exit 1
}

LIST_COMMANDS=$(smoke_cmd list-commands -F '#{command_name}:#{command_alias}') || exit 1
printf '%s\n' "$LIST_COMMANDS" | grep -qx 'list-commands:lscm' || {
    echo "list-commands -F missing list-commands:lscm"
    exit 1
}

LIST_KEYS=$(smoke_cmd list-keys -T prefix -F '#{key_table}:#{key_string}:#{key_command}') || exit 1
printf '%s\n' "$LIST_KEYS" | grep -qx 'prefix:c:new-window' || {
    echo "list-keys -F missing prefix:c:new-window"
    exit 1
}

LIST_SESSIONS=$(smoke_cmd list-sessions -F '#{session_name}:#{session_windows}' -f '#{==:session_name,fmtcheck}') || exit 1
[ "$LIST_SESSIONS" = "fmtcheck:3" ] || {
    echo "list-sessions formatter mismatch: $LIST_SESSIONS"
    exit 1
}

LIST_WINDOWS=$(smoke_cmd list-windows -t fmtcheck -F '#{window_index}' -f '#{m/r:^(0|2)$,#{window_index}}') || exit 1
[ "$(printf '%s\n' "$LIST_WINDOWS" | awk 'NF { count++ } END { print count + 0 }')" -eq 2 ] || {
    echo "list-windows filtered count mismatch: $LIST_WINDOWS"
    exit 1
}
printf '%s\n' "$LIST_WINDOWS" | grep -qx '0' || {
    echo "list-windows filtered output missing 0"
    exit 1
}
printf '%s\n' "$LIST_WINDOWS" | grep -qx '2' || {
    echo "list-windows filtered output missing 2"
    exit 1
}

LIST_PANES=$(smoke_cmd list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' -f '#{==:session_name,fmtcheck}') || exit 1
[ "$(printf '%s\n' "$LIST_PANES" | awk 'NF { count++ } END { print count + 0 }')" -eq 3 ] || {
    echo "list-panes filtered count mismatch: $LIST_PANES"
    exit 1
}
printf '%s\n' "$LIST_PANES" | grep -qx 'fmtcheck:2.0' || {
    echo "list-panes filtered output missing fmtcheck:2.0"
    exit 1
}

LIST_CLIENTS=$(smoke_cmd list-clients -F '#{client_termname}:#{client_width}x#{client_height}') || exit 1
printf '%s\n' "$LIST_CLIENTS" | grep -Eq '^[^:]+:[0-9]+x[0-9]+$' || {
    echo "list-clients formatter mismatch: $LIST_CLIENTS"
    exit 1
}

HOST_SHORT=$(smoke_cmd display-message -p '#{host_short}') || exit 1
SOURCE_CONF="$TEST_TMPDIR/$HOST_SHORT.formatter.conf"
cat <<EOF >"$SOURCE_CONF"
set-option -g @loaded yes
EOF
smoke_cmd source-file -F "$TEST_TMPDIR/#{host_short}.formatter.conf" || exit 1
SHOW_LOADED=$(smoke_cmd show-options -gv @loaded) || exit 1
case "$SHOW_LOADED" in
    yes|@loaded\ yes)
        ;;
    *)
        echo "source-file -F or show-options mismatch: $SHOW_LOADED"
        exit 1
        ;;
esac

smoke_cmd send-keys -F -t fmtcheck:1.0 'session=#{session_name}' Enter || exit 1
smoke_wait_for 5 sh -c "[ -f '$SEND_OUT' ] && grep -qx 'session=fmtcheck' '$SEND_OUT'" || {
    echo "send-keys -F did not write expanded text"
    exit 1
}

exit 0

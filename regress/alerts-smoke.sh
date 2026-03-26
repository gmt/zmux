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

# alerts-smoke.sh - cover reduced bell/activity/silence alert propagation.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init alerts

window_flags() {
    smoke_cmd display-message -p -t alerts:0 '#{window_flags}'
}

session_alerts() {
    smoke_cmd display-message -p -t alerts '#{session_alerts}'
}

has_flag() {
    flag=$1
    case "$(window_flags)" in
        *"$flag"*) return 0 ;;
    esac
    return 1
}

session_has_flag() {
    flag=$1
    case "$(session_alerts)" in
        *"$flag"*) return 0 ;;
    esac
    return 1
}

smoke_cmd new-session -d -s alerts || exit 1
smoke_cmd set-window-option -t alerts:0 monitor-activity on || exit 1

smoke_cmd send-keys -t alerts:0.0 "printf activity" Enter || exit 1
smoke_wait_for 5 has_flag '#' || {
    echo "activity alert flag did not appear: $(window_flags)"
    exit 1
}
smoke_wait_for 5 session_has_flag '#' || {
    echo "session activity alert flag did not appear: $(session_alerts)"
    exit 1
}

smoke_cmd send-keys -t alerts:0.0 "printf '\\a'" Enter || exit 1
smoke_wait_for 5 has_flag '!' || {
    echo "bell alert flag did not appear: $(window_flags)"
    exit 1
}
smoke_wait_for 5 session_has_flag '!' || {
    echo "session bell alert flag did not appear: $(session_alerts)"
    exit 1
}

smoke_cmd kill-session -t alerts -C || exit 1
[ "$(window_flags)" = "*" ] || {
    echo "kill-session -C did not clear window flags: $(window_flags)"
    exit 1
}
[ "$(session_alerts)" = "" ] || {
    echo "kill-session -C did not clear session alerts: $(session_alerts)"
    exit 1
}

smoke_cmd set-window-option -t alerts:0 monitor-silence 1 || exit 1
smoke_wait_for 4 has_flag '~' || {
    echo "silence alert flag did not appear: $(window_flags)"
    exit 1
}
smoke_wait_for 4 session_has_flag '~' || {
    echo "session silence alert flag did not appear: $(session_alerts)"
    exit 1
}

exit 0

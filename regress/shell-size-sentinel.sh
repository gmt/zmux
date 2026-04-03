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

# shell-size-sentinel.sh – narrow ambient-shell integration check for
# real-shell tty sizing inside a pane.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init shell-size-sentinel
smoke_use_real_shell || exit $?

STTY_OUT="$TEST_TMPDIR/stty-size.out"
VARS_OUT="$TEST_TMPDIR/shell-vars.out"

smoke_cmd new-session -d -s shellsize -x 91 -y 37 || exit 1
sleep 1

smoke_cmd send-keys -t shellsize "stty size > '$STTY_OUT'; printf '%s %s\n' \"\${LINES-}\" \"\${COLUMNS-}\" > '$VARS_OUT'" Enter || exit 1

smoke_wait_for 5 sh -c "[ -f '$STTY_OUT' ]" || {
    echo "real shell never wrote tty size"
    exit 1
}

STTY_SIZE=$(tr -d '\r' <"$STTY_OUT")
[ "$STTY_SIZE" = "37 91" ] || {
    echo "stty size mismatch: $STTY_SIZE"
    exit 1
}

if [ -s "$VARS_OUT" ]; then
    VARS=$(tr -d '\r' <"$VARS_OUT")
    case "$VARS" in
        "37 91"|""|" " )
            ;;
        *)
            echo "shell line/column vars mismatch: $VARS"
            exit 1
            ;;
    esac
fi

exit 0

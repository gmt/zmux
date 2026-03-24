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

# run-all.sh – Master smoke harness runner.
# Usage:  ./run-all.sh                       (uses zig-out/bin/zmux)
#         TEST_ZMUX=/usr/bin/tmux ./run-all.sh  (oracle against installed tmux)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${TEST_ZMUX:=$ROOT_DIR/zig-out/bin/zmux}"
export TEST_ZMUX

if [ ! -x "$TEST_ZMUX" ]; then
    echo "SKIP: $TEST_ZMUX not found or not executable" >&2
    echo "      Build with 'zig build' or set TEST_ZMUX" >&2
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

run_test() {
    local script="$1"
    local name
    name="$(basename "$script" .sh)"
    printf "  %-40s " "$name"
    if sh "$script"; then
        printf "PASS\n"
        PASS=$((PASS + 1))
    else
        status=$?
        if [ "$status" -eq 77 ]; then
            printf "SKIP\n"
            SKIP=$((SKIP + 1))
        else
            printf "FAIL (exit %d)\n" "$status"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "zmux smoke harness  ($TEST_ZMUX)"
echo "----------------------------------------------"

for f in \
    "$SCRIPT_DIR/new-session-no-client.sh" \
    "$SCRIPT_DIR/has-session-return.sh" \
    "$SCRIPT_DIR/new-session-size.sh" \
    "$SCRIPT_DIR/kill-session-process-exit.sh" \
    "$SCRIPT_DIR/control-client-size.sh" \
    "$SCRIPT_DIR/session-group-resize.sh" \
    "$SCRIPT_DIR/second-socket-attach.sh" \
    "$SCRIPT_DIR/command-order.sh" \
; do
    [ -f "$f" ] && run_test "$f"
done

echo "----------------------------------------------"
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"

[ "$FAIL" -eq 0 ]

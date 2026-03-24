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

PATH=/bin:/usr/bin
TERM=${TERM:-screen}
export PATH TERM

SMOKE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SMOKE_ROOT_DIR=$(CDPATH= cd -- "$SMOKE_SCRIPT_DIR/.." && pwd)

: "${TEST_ZMUX:=$SMOKE_ROOT_DIR/zig-out/bin/zmux}"
: "${SMOKE_ARTIFACT_ROOT:=/tmp}"
: "${SMOKE_MATRIX:=$SMOKE_SCRIPT_DIR/oracle-command-matrix.tsv}"

smoke_init() {
    TEST_NAME=${1:-smoke}
    TEST_TMPDIR=$(mktemp -d "${SMOKE_ARTIFACT_ROOT%/}/zmux-${TEST_NAME}.XXXXXX") || exit 1
    TEST_SOCKET="$TEST_TMPDIR/socket"
    export TEST_NAME TEST_TMPDIR TEST_SOCKET
    trap 'smoke_cleanup' 0 1 2 3 15
}

smoke_bin() {
    "$TEST_ZMUX" -S "$TEST_SOCKET" "$@"
}

smoke_cmd() {
    "$TEST_ZMUX" -S "$TEST_SOCKET" -f/dev/null "$@"
}

smoke_try_kill_server() {
    if [ -n "${TEST_SOCKET-}" ]; then
        timeout 2 "$TEST_ZMUX" -S "$TEST_SOCKET" -f/dev/null kill-server >/dev/null 2>&1 || true
    fi
}

smoke_kill_wedged_server() {
    if [ -z "${TEST_SOCKET-}" ]; then
        return 0
    fi

    pids=$(ps -eo pid=,args= | awk -v sock="$TEST_SOCKET" 'index($0, sock) { print $1 }')
    if [ -n "$pids" ]; then
        kill -9 $pids >/dev/null 2>&1 || true
    fi
}

smoke_cleanup() {
    smoke_try_kill_server
    smoke_kill_wedged_server
    if [ -n "${TEST_TMPDIR-}" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

smoke_manifest_status() {
    awk -F '\t' -v cmd="$1" '
        $1 == cmd { print $3; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$SMOKE_MATRIX"
}

smoke_supports_command() {
    cmd=$1
    if smoke_manifest_status "$cmd" 2>/dev/null | grep -qx 'implemented'; then
        return 0
    fi
    "$TEST_ZMUX" list-commands "$cmd" >/dev/null 2>&1
}

smoke_wait_for() {
    timeout_s=$1
    shift

    n=0
    while [ "$n" -lt "$timeout_s" ]; do
        if "$@"; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}

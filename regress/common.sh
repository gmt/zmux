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
COLORTERM=${COLORTERM:-truecolor}
export PATH TERM COLORTERM

SMOKE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SMOKE_ROOT_DIR=$(CDPATH= cd -- "$SMOKE_SCRIPT_DIR/.." && pwd)

: "${TEST_ZMUX:=$SMOKE_ROOT_DIR/zig-out/bin/zmux}"
: "${TEST_ZMUX_HELPER:=$SMOKE_ROOT_DIR/zig-out/bin/hello-shell-ansi}"
: "${SMOKE_ARTIFACT_ROOT:=/tmp}"
: "${SMOKE_MATRIX:=$SMOKE_SCRIPT_DIR/oracle-command-matrix.tsv}"

smoke_init() {
    TEST_NAME=${1:-smoke}
    TEST_TMPDIR=$(mktemp -d "${SMOKE_ARTIFACT_ROOT%/}/zmux-${TEST_NAME}.XXXXXX") || exit 1
    TEST_SOCKET="$TEST_TMPDIR/socket"
    SMOKE_HOME="$TEST_TMPDIR/home"
    mkdir -p "$SMOKE_HOME/.config" "$SMOKE_HOME/.cache" "$SMOKE_HOME/.local/share"
    SMOKE_ENV_MODE=ambient
    SMOKE_SELECTED_SHELL=
    SMOKE_HELPER_MODE=
    SMOKE_HELPER_PATH=
    export TEST_NAME TEST_TMPDIR TEST_SOCKET SMOKE_HOME SMOKE_ENV_MODE SMOKE_SELECTED_SHELL SMOKE_HELPER_MODE SMOKE_HELPER_PATH
    trap 'smoke_cleanup' 0 1 2 3 15
}

smoke_use_ambient_shell() {
    SMOKE_ENV_MODE=ambient
    SMOKE_SELECTED_SHELL=
    SMOKE_HELPER_MODE=
    SMOKE_HELPER_PATH=
    export SMOKE_ENV_MODE SMOKE_SELECTED_SHELL SMOKE_HELPER_MODE SMOKE_HELPER_PATH
}

smoke_use_helper_shell() {
    mode=$1
    helper_path=${2:-}
    [ -x "$TEST_ZMUX_HELPER" ] || {
        echo "SKIP: helper shell not found: $TEST_ZMUX_HELPER" >&2
        return 77
    }
    SMOKE_ENV_MODE=deterministic
    SMOKE_SELECTED_SHELL=$TEST_ZMUX_HELPER
    SMOKE_HELPER_MODE=$mode
    SMOKE_HELPER_PATH=$helper_path
    export SMOKE_ENV_MODE SMOKE_SELECTED_SHELL SMOKE_HELPER_MODE SMOKE_HELPER_PATH
}

smoke_find_real_shell() {
    if [ -n "${SMOKE_TEST_SHELL-}" ] && [ -x "$SMOKE_TEST_SHELL" ]; then
        printf '%s\n' "$SMOKE_TEST_SHELL"
        return 0
    fi
    if [ -x /bin/sh ]; then
        printf '/bin/sh\n'
        return 0
    fi
    command -v sh 2>/dev/null || return 1
}

smoke_use_real_shell() {
    shell=$(smoke_find_real_shell) || {
        echo "SKIP: no suitable real shell found" >&2
        return 77
    }
    SMOKE_ENV_MODE=shell-sentinel
    SMOKE_SELECTED_SHELL=$shell
    SMOKE_HELPER_MODE=
    SMOKE_HELPER_PATH=
    export SMOKE_ENV_MODE SMOKE_SELECTED_SHELL SMOKE_HELPER_MODE SMOKE_HELPER_PATH
}

smoke_exec_env() {
    if [ "${SMOKE_ENV_MODE:-ambient}" = ambient ]; then
        env \
            PATH="$PATH" \
            TERM="$TERM" \
            COLORTERM="$COLORTERM" \
            "$@"
        return $?
    fi

    env -i \
        PATH=/bin:/usr/bin \
        TERM="$TERM" \
        COLORTERM="$COLORTERM" \
        LANG=C \
        LC_ALL=C \
        TZ=UTC \
        HOME="$SMOKE_HOME" \
        USER=smoke \
        LOGNAME=smoke \
        XDG_CONFIG_HOME="$SMOKE_HOME/.config" \
        XDG_CACHE_HOME="$SMOKE_HOME/.cache" \
        XDG_DATA_HOME="$SMOKE_HOME/.local/share" \
        SHELL="$SMOKE_SELECTED_SHELL" \
        ZMUX_SMOKE_HELPER_MODE="$SMOKE_HELPER_MODE" \
        ZMUX_SMOKE_HELPER_PATH="$SMOKE_HELPER_PATH" \
        "$@"
}

smoke_bin() {
    smoke_exec_env "$TEST_ZMUX" -S "$TEST_SOCKET" "$@"
}

smoke_cmd() {
    smoke_exec_env "$TEST_ZMUX" -S "$TEST_SOCKET" -f/dev/null "$@"
}

smoke_try_kill_server() {
    if [ -n "${TEST_SOCKET-}" ]; then
        smoke_exec_env timeout 2 "$TEST_ZMUX" -S "$TEST_SOCKET" -f/dev/null kill-server >/dev/null 2>&1 || true
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
    smoke_exec_env "$TEST_ZMUX" list-commands "$cmd" >/dev/null 2>&1
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

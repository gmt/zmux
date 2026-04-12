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

set -eu

usage() {
    echo "usage: $0 MODE --binary PATH --socket PATH [--artifact-root DIR] [--keep-temp]" >&2
    echo "  MODE: switch-only | full" >&2
    exit 2
}

[ $# -ge 1 ] || usage
MODE=$1
shift

BINARY=
SOCKET=
ARTIFACT_ROOT=/tmp/zmux-session-group-lab
KEEP_TEMP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)
            [ $# -ge 2 ] || usage
            BINARY=$2
            shift 2
            ;;
        --socket)
            [ $# -ge 2 ] || usage
            SOCKET=$2
            shift 2
            ;;
        --artifact-root)
            [ $# -ge 2 ] || usage
            ARTIFACT_ROOT=$2
            shift 2
            ;;
        --keep-temp)
            KEEP_TEMP=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done

[ -n "$BINARY" ] || usage
[ -n "$SOCKET" ] || usage
[ -x "$BINARY" ] || {
    echo "driver: binary is not executable: $BINARY" >&2
    exit 1
}

case "$MODE" in
    switch-only | full) ;;
    *)
        usage
        ;;
esac

TMPDIR=$(mktemp -d "${ARTIFACT_ROOT%/}/drive-${MODE}.XXXXXX") || exit 1
TMP1=$TMPDIR/client-1.log
TMP2=$TMPDIR/client-2.log
TMP3=$TMPDIR/client-3.log

cleanup() {
    status=$?
    if [ "$status" -eq 0 ] && [ "$KEEP_TEMP" -eq 0 ]; then
        rm -rf "$TMPDIR"
    else
        echo "driver: artifacts kept in $TMPDIR" >&2
    fi
    exit "$status"
}
trap cleanup 0 1 2 3 15

mkdir -p "$TMPDIR/home/.config" "$TMPDIR/home/.cache" "$TMPDIR/home/.local/share"

mux_env() {
    env -i \
        PATH=/bin:/usr/bin \
        TERM=screen \
        COLORTERM=truecolor \
        LANG=C \
        LC_ALL=C \
        TZ=UTC \
        HOME="$TMPDIR/home" \
        USER=smoke \
        LOGNAME=smoke \
        XDG_CONFIG_HOME="$TMPDIR/home/.config" \
        XDG_CACHE_HOME="$TMPDIR/home/.cache" \
        XDG_DATA_HOME="$TMPDIR/home/.local/share" \
        SHELL=/bin/sh \
        "$@"
}

mux_cmd() {
    mux_env "$BINARY" -N -S "$SOCKET" -f/dev/null "$@"
}

dump_state() {
    echo "-- list-sessions --"
    mux_cmd list-sessions -F '#{session_name}' 2>&1 || echo "list-sessions status=$?"
    echo "-- list-clients --"
    mux_cmd list-clients -F '#{client_name} sess=#{session_name} win=#{window_index} size=#{client_width}x#{client_height}' 2>&1 || echo "list-clients status=$?"
    echo "-- list-windows -a --"
    mux_cmd list-windows -a -F '#{session_name}:#{window_index} size=#{window_width}x#{window_height} active=#{window_active}' 2>&1 || echo "list-windows status=$?"
    echo "-- TMP1 --"
    cat "$TMP1" 2>/dev/null || true
    echo "-- TMP2 --"
    cat "$TMP2" 2>/dev/null || true
    if [ "$MODE" = full ]; then
        echo "-- TMP3 --"
        cat "$TMP3" 2>/dev/null || true
    fi
}

wait_for_window_one() {
    n=0
    while [ $n -lt 20 ]; do
        mux_cmd list-clients -F '#{client_name} #{window_index}' 2>/dev/null | grep -q ' 1$' && return 0
        sleep 0.1
        n=$((n + 1))
    done
    return 1
}

wait_for_size() {
    target=$1
    expected=$2
    out_var=$3
    n=0
    actual=
    while [ $n -lt 20 ]; do
        actual=$(mux_cmd display-message -t "$target" -p '#{window_width}x#{window_height}' 2>/dev/null || true)
        [ "$actual" = "$expected" ] && break
        sleep 0.1
        n=$((n + 1))
    done
    eval "$out_var=\$actual"
}

# Create a session with two windows, staying on window 0.
mux_cmd new-session -d -s test -x 20 -y 6
mux_cmd new-window -t test
mux_cmd select-window -t test:0

# Attach a small control client and place it on window 1.
(
    printf '%s\n' 'refresh-client -C 20,6'
    printf '%s\n' 'select-window -t :1'
    sleep 5
) |
    mux_env "$BINARY" -N -S "$SOCKET" -f/dev/null -C attach -t test >"$TMP1" 2>&1 &

wait_for_window_one || {
    echo "driver: small control client never reached window 1" >&2
    dump_state
    exit 1
}

# Create the larger grouped control client and switch it to window 1.
(
    printf '%s\n' 'refresh-client -C 30,10'
    printf '%s\n' 'switch-client -t :=1'
    sleep 5
) |
    mux_env "$BINARY" -N -S "$SOCKET" -f/dev/null -C new-session -t test -x 30 -y 10 >"$TMP2" 2>&1 &

wait_for_size test:1 30x10 OUT1

if [ "$MODE" = full ]; then
    (
        printf '%s\n' 'refresh-client -C 25,8'
        printf '%s\n' 'select-window -t :1'
        sleep 5
    ) |
        mux_env "$BINARY" -N -S "$SOCKET" -f/dev/null -C new-session -t test -x 25 -y 8 >"$TMP3" 2>&1 &

    wait_for_size test:1 25x8 OUT2
fi

if [ "$OUT1" != 30x10 ]; then
    echo "switch-client resize failed: $OUT1" >&2
    dump_state
    exit 1
fi

if [ "$MODE" = full ] && [ "${OUT2-}" != 25x8 ]; then
    echo "select-window resize failed: ${OUT2-}" >&2
    dump_state
    exit 1
fi

echo "driver: $MODE passed" >&2

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

# run-all.sh – tiered smoke harness runner.
# Usage:
#   ./run-all.sh fast
#   ./run-all.sh oracle
#   ./run-all.sh soak
#   ./run-all.sh docker
#   ./run-all.sh all

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

: "${TEST_ZMUX:=$ROOT_DIR/zig-out/bin/zmux}"
: "${TEST_ORACLE_TMUX:=/usr/bin/tmux}"
: "${SMOKE_ARTIFACT_ROOT:=/tmp}"
: "${SMOKE_TEST_TIMEOUT:=20}"
: "${SMOKE_PYTHON_TIMEOUT:=600}"
: "${SMOKE_DOCKER_TIMEOUT:=1200}"

SUITE=${1:-fast}
RUN_DIR=$(mktemp -d "${SMOKE_ARTIFACT_ROOT%/}/zmux-smoke-run.XXXXXX")
PASS=0
FAIL=0
SKIP=0

cleanup() {
    reap_smoke_processes
    rm -rf "$RUN_DIR"
}
trap cleanup 0 1 2 3 15

reap_smoke_processes() {
    pids=$(ps -eo pid=,args= | awk '
        index($0, "/tmp/zmux-") || index($0, "/tmp/zmux-smoke-") { print $1 }
    ')
    if [ -n "$pids" ]; then
        kill -9 $pids >/dev/null 2>&1 || true
    fi
}

require_bin() {
    bin=$1
    if [ ! -x "$bin" ]; then
        echo "SKIP: $bin not found or not executable" >&2
        exit 77
    fi
}

run_sh_test() {
    name=$1
    bin=$2
    script=$3
    log="$RUN_DIR/$name.log"

    printf "  %-40s " "$name"
    if TEST_ZMUX="$bin" SMOKE_ARTIFACT_ROOT="$SMOKE_ARTIFACT_ROOT" timeout "$SMOKE_TEST_TIMEOUT" sh "$script" >"$log" 2>&1; then
        printf "PASS\n"
        PASS=$((PASS + 1))
        reap_smoke_processes
        return 0
    else
        status=$?
    fi

    if [ "$status" -eq 77 ]; then
        printf "SKIP\n"
        SKIP=$((SKIP + 1))
        reap_smoke_processes
        return 0
    fi

    printf "FAIL (exit %d)\n" "$status"
    sed -n '1,80p' "$log"
    FAIL=$((FAIL + 1))
    reap_smoke_processes
    return 0
}

run_py_test() {
    name=$1
    bin=$2
    shift 2
    log="$RUN_DIR/$name.log"

    printf "  %-40s " "$name"
    if TEST_ZMUX="$bin" SMOKE_ARTIFACT_ROOT="$SMOKE_ARTIFACT_ROOT" timeout "$SMOKE_PYTHON_TIMEOUT" python3 "$SCRIPT_DIR/smoke_harness.py" "$@" >"$log" 2>&1; then
        printf "PASS\n"
        PASS=$((PASS + 1))
        reap_smoke_processes
        return 0
    else
        status=$?
    fi

    if [ "$status" -eq 77 ]; then
        printf "SKIP\n"
        SKIP=$((SKIP + 1))
        reap_smoke_processes
        return 0
    fi

    printf "FAIL (exit %d)\n" "$status"
    sed -n '1,120p' "$log"
    FAIL=$((FAIL + 1))
    reap_smoke_processes
    return 0
}

run_fast_suite() {
    bin=$1
    require_bin "$bin"

    echo "zmux fast suite  ($bin)"
    echo "----------------------------------------------"

    for f in \
        "$SCRIPT_DIR/new-session-no-client.sh" \
        "$SCRIPT_DIR/has-session-return.sh" \
        "$SCRIPT_DIR/new-session-size.sh" \
        "$SCRIPT_DIR/kill-session-process-exit.sh" \
        "$SCRIPT_DIR/control-client-size.sh" \
        "$SCRIPT_DIR/control-notify-smoke.sh" \
        "$SCRIPT_DIR/session-group-resize.sh" \
        "$SCRIPT_DIR/second-socket-attach.sh" \
        "$SCRIPT_DIR/command-order.sh" \
        "$SCRIPT_DIR/attach-detach-client.sh" \
        "$SCRIPT_DIR/list-and-display.sh" \
        "$SCRIPT_DIR/formatter-smoke.sh" \
        "$SCRIPT_DIR/kill-server-cleanup.sh" \
    ; do
        [ -f "$f" ] && run_sh_test "$(basename "$f" .sh)" "$bin" "$f"
    done

    run_py_test command-sweep "$bin" sweep --mode implemented
    run_py_test inside-session "$bin" inside
}

run_oracle_suite() {
    require_bin "$TEST_ORACLE_TMUX"

    echo "oracle tmux suite  ($TEST_ORACLE_TMUX)"
    echo "----------------------------------------------"
    run_py_test oracle-command-sweep "$TEST_ORACLE_TMUX" sweep --mode oracle
    run_py_test oracle-inside-session "$TEST_ORACLE_TMUX" inside
}

run_soak_suite() {
    bin=$1
    require_bin "$bin"

    echo "zmux soak suite  ($bin)"
    echo "----------------------------------------------"
    run_py_test soak "$bin" soak
}

run_docker_suite() {
    require_bin "$TEST_ORACLE_TMUX"

    echo "docker oracle suite"
    echo "----------------------------------------------"
    old_timeout=$SMOKE_TEST_TIMEOUT
    SMOKE_TEST_TIMEOUT=$SMOKE_DOCKER_TIMEOUT
    run_sh_test docker-ssh "$TEST_ORACLE_TMUX" "$SCRIPT_DIR/docker-ssh.sh"
    SMOKE_TEST_TIMEOUT=$old_timeout
}

case "$SUITE" in
    fast)
        run_fast_suite "$TEST_ZMUX"
        ;;
    oracle)
        run_oracle_suite
        ;;
    soak)
        run_soak_suite "$TEST_ZMUX"
        ;;
    docker)
        run_docker_suite
        ;;
    all)
        run_fast_suite "$TEST_ZMUX"
        run_oracle_suite
        run_docker_suite
        ;;
    *)
        echo "usage: $0 [fast|oracle|soak|docker|all]" >&2
        exit 2
        ;;
esac

echo "----------------------------------------------"
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ]

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

# view-mode-oracle.sh — integration test for Ctrl-B ? (list-keys viewer)
#
# Drives an inner multiplexer (zmux or tmux) inside an outer tmux container,
# sends Ctrl-B ? via send-keys, and verifies the resulting screen state.
# Run with CONTAINEE=tmux to establish the oracle baseline, then with
# CONTAINEE=zmux (default) to verify parity.
#
# Usage:
#   ./regress/view-mode-oracle.sh              # test zmux
#   CONTAINEE=tmux ./regress/view-mode-oracle.sh  # oracle baseline

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONTAINEE=${CONTAINEE:-$ROOT_DIR/zig-out/bin/zmux}
OUTER_TMUX=${OUTER_TMUX:-tmux}

# Fixed geometry for reproducible coordinates.
OUTER_COLS=120
OUTER_ROWS=40

TMPDIR=$(mktemp -d /tmp/view-mode-oracle.XXXXXX)
OUTER_SOCK="$TMPDIR/outer.sock"
INNER_SOCK="$TMPDIR/inner.sock"
INNER_CONF="$TMPDIR/inner.conf"
SMOKE_OWNER_DIR=${SMOKE_OWNER_DIR:-$TMPDIR/owned-pids}
trap 'cleanup' 0 1 2 3 15

owner_tool() {
    python3 "$SCRIPT_DIR/smoke_owner.py" "$@"
}

cleanup() {
    # Kill inner multiplexer.
    env HOME="$TMPDIR" "$CONTAINEE" -S "$INNER_SOCK" kill-server >/dev/null 2>&1 || true
    # Kill outer tmux.
    env HOME="$TMPDIR" TMUX_TMPDIR="$TMPDIR" \
        "$OUTER_TMUX" -S "$OUTER_SOCK" kill-server >/dev/null 2>&1 || true
    owner_tool cleanup --owner-dir "$SMOKE_OWNER_DIR" --socket-path "$INNER_SOCK" >/dev/null 2>&1 || true
    owner_tool cleanup --owner-dir "$SMOKE_OWNER_DIR" --socket-path "$OUTER_SOCK" >/dev/null 2>&1 || true
    rm -rf "$TMPDIR"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "PASS: $1"
}

# Helper: run outer tmux commands with sandboxed env.
outer_cmd() {
    env HOME="$TMPDIR" TMUX_TMPDIR="$TMPDIR" \
        "$OUTER_TMUX" -S "$OUTER_SOCK" "$@"
}

# Helper: send keys to inner containee via outer tmux.
# Keys go to the outer pane (which is running the inner multiplexer).
inner_send() {
    outer_cmd send-keys -t outer "$@"
}

# Helper: capture inner pane content from outer tmux's perspective.
inner_capture() {
    outer_cmd capture-pane -t outer -p
}

# Helper: query inner containee directly.
inner_cmd() {
    "$CONTAINEE" -S "$INNER_SOCK" -f/dev/null "$@"
}

# Helper: get inner pane dimensions from the inner containee.
inner_pane_size() {
    inner_cmd display-message -p '#{pane_width}x#{pane_height}' 2>/dev/null
}

# Helper: get cursor position from inner containee.
inner_cursor_pos() {
    inner_cmd display-message -p '#{cursor_x},#{cursor_y}' 2>/dev/null
}

register_server() {
    owner_label=$1
    socket_path=$2
    shift 2
    owner_tool register-server \
        --owner-dir "$SMOKE_OWNER_DIR" \
        --owner-label "$owner_label" \
        --socket-path "$socket_path" \
        -- "$@" >/dev/null
}

wait_for() {
    tries=$1; shift
    n=0
    while [ "$n" -lt "$tries" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.3
        n=$((n + 1))
    done
    return 1
}

########################################################################
# Setup: outer tmux container at fixed geometry.
########################################################################

# Empty config for inner containee — no user customizations.
: > "$INNER_CONF"

# Start inner containee detached first (so the socket exists).
env -i PATH=/bin:/usr/bin TERM=screen HOME="$TMPDIR" \
    "$CONTAINEE" -S "$INNER_SOCK" -f "$INNER_CONF" \
    new-session -d -s inner || fail "inner containee start"
register_server inner "$INNER_SOCK" \
    env -i PATH=/bin:/usr/bin TERM=screen HOME="$TMPDIR" \
    "$CONTAINEE" -S "$INNER_SOCK" -f "$INNER_CONF" \
    || fail "inner containee pid"

# Start outer tmux and attach to inner containee inside it.
# Outer tmux uses empty config and sandboxed HOME to avoid user config leakage.
env -i PATH=/bin:/usr/bin TERM=screen HOME="$TMPDIR" \
    TMUX_TMPDIR="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/.config" \
    "$OUTER_TMUX" -S "$OUTER_SOCK" -f/dev/null new-session -d \
    -s outer -x "$OUTER_COLS" -y "$OUTER_ROWS" \
    "env -i PATH=/bin:/usr/bin TERM=screen HOME=$TMPDIR TMUX_TMPDIR=$TMPDIR XDG_CONFIG_HOME=$TMPDIR/.config $CONTAINEE -S $INNER_SOCK -f $INNER_CONF attach -t inner; sleep 5" \
    || fail "outer tmux start"
register_server outer "$OUTER_SOCK" \
    env -i PATH=/bin:/usr/bin TERM=screen HOME="$TMPDIR" TMUX_TMPDIR="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/.config" \
    "$OUTER_TMUX" -S "$OUTER_SOCK" -f/dev/null \
    || fail "outer tmux pid"

# Wait for inner containee to be attached.
wait_for 10 inner_cmd has-session -t inner || fail "inner containee not ready"
sleep 1

########################################################################
# Pre-flight: record pane dimensions before Ctrl-B ?.
########################################################################

PRE_SIZE=$(inner_pane_size) || fail "couldn't get pre-flight pane size"
PRE_COLS=${PRE_SIZE%x*}
PRE_ROWS=${PRE_SIZE#*x}
echo "Pre-flight inner pane: ${PRE_COLS}x${PRE_ROWS}"

# Sanity: inner pane should be close to outer geometry (minus status line).
[ "$PRE_COLS" -ge 100 ] || fail "inner pane too narrow: $PRE_COLS"
[ "$PRE_ROWS" -ge 30 ] || fail "inner pane too short: $PRE_ROWS"

########################################################################
# Fill with filler text, cursor at bottom.
########################################################################

# Generate enough lines to fill the screen.
FILLER_LINES=$((PRE_ROWS + 5))
i=0
while [ "$i" -lt "$FILLER_LINES" ]; do
    inner_send "echo FILLER_LINE_$(printf '%03d' $i)" Enter
    i=$((i + 1))
done
sleep 0.5

########################################################################
# Send Ctrl-B ? to open the help viewer.
########################################################################

inner_send C-b
sleep 0.1
inner_send '?'
sleep 1

########################################################################
# Test 1: Help text fills the entire vertical span.
#         First visible line should start with "C-b" (the help content).
#         Lower rows should also contain help text, not the stale 24-row blank
#         gap, and no filler text should be visible.
########################################################################

SCREEN=$(inner_capture)
PANE_SCREEN=$(printf '%s\n' "$SCREEN" | sed -n "1,${PRE_ROWS}p")

FIRST_LINE=$(echo "$SCREEN" | head -1)
case "$FIRST_LINE" in
    *C-b*) pass "first line contains help text" ;;
    *)     fail "first line is not help text: '$FIRST_LINE'" ;;
esac

BOTTOM_LINE=$(printf '%s\n' "$PANE_SCREEN" | sed -n "${PRE_ROWS}p")
case "$BOTTOM_LINE" in
    *[![:space:]]*) pass "bottom pane row contains help text" ;;
    *)              fail "bottom pane row is blank in help view" ;;
esac

# No filler should be visible.
if echo "$SCREEN" | grep -q "FILLER_LINE"; then
    fail "filler text visible in help view"
else
    pass "no filler text in help view"
fi

########################################################################
# Test 2: Pane dimensions unchanged.
########################################################################

POST_SIZE=$(inner_pane_size) || fail "couldn't get post-help pane size"
[ "$POST_SIZE" = "$PRE_SIZE" ] || fail "pane size changed: was $PRE_SIZE, now $POST_SIZE"
pass "pane dimensions preserved: $POST_SIZE"

########################################################################
# Test 3: Cursor at bottom of screen.
########################################################################

CURSOR=$(inner_cursor_pos) || fail "couldn't get cursor position"
CURSOR_Y=${CURSOR#*,}
# Cursor should be at or near the last row (PRE_ROWS - 1).
EXPECTED_BOTTOM=$((PRE_ROWS - 1))
if [ "$CURSOR_Y" -ge "$((EXPECTED_BOTTOM - 2))" ]; then
    pass "cursor near bottom: y=$CURSOR_Y (expected ~$EXPECTED_BOTTOM)"
else
    fail "cursor not at bottom: y=$CURSOR_Y (expected ~$EXPECTED_BOTTOM)"
fi

########################################################################
# Test 4: PgDn scrolls the help text.
########################################################################

# Capture the current first line.
BEFORE_PGDN_FIRST=$(inner_capture | head -1)

inner_send PageDown
sleep 0.5

AFTER_PGDN_FIRST=$(inner_capture | head -1)

if [ "$BEFORE_PGDN_FIRST" != "$AFTER_PGDN_FIRST" ]; then
    pass "PgDn scrolled: first line changed"
else
    fail "PgDn did not scroll: first line unchanged ('$BEFORE_PGDN_FIRST')"
fi

########################################################################
# Test 5: Second PgDn scrolls further.
########################################################################

inner_send PageDown
sleep 0.5

AFTER_PGDN2_FIRST=$(inner_capture | head -1)

if [ "$AFTER_PGDN_FIRST" != "$AFTER_PGDN2_FIRST" ]; then
    pass "second PgDn scrolled further"
else
    fail "second PgDn did not scroll"
fi

########################################################################
# Test 6: q quits back to the shell.
########################################################################

inner_send q
sleep 0.5

# Filler text should be visible again.
AFTER_Q=$(inner_capture)
if echo "$AFTER_Q" | grep -q "FILLER_LINE"; then
    pass "q restored shell (filler visible)"
else
    fail "q did not restore shell content"
fi

# Dimensions should be restored.
RESTORED_SIZE=$(inner_pane_size) || fail "couldn't get restored pane size"
[ "$RESTORED_SIZE" = "$PRE_SIZE" ] || fail "size after q: $RESTORED_SIZE (expected $PRE_SIZE)"
pass "dimensions restored after q: $RESTORED_SIZE"

########################################################################
echo ""
echo "All view-mode oracle tests passed."

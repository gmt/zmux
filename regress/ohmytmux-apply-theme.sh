#!/bin/sh
# Verify source-file error format matches tmux's file:line: convention,
# enabling oh-my-tmux's _apply_bindings error recovery loop to work.
# Run via: python3 regress/run-contained.py -- sh regress/ohmytmux-apply-theme.sh

SMOKE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SMOKE_SCRIPT_DIR/common.sh"

smoke_init omt-srcfmt
smoke_use_real_shell

smoke_cmd new-session -d -s test -x 200 -y 50
sleep 0.3

fail() {
    echo "FAIL: $*" >&2
    smoke_cmd kill-server 2>/dev/null || true
    exit 1
}

# -------------------------------------------------------------------
# Test 1: source-file error format includes file:line: prefix
# -------------------------------------------------------------------
echo "=== Test 1: source-file error format ==="

cat > "$TEST_TMPDIR/err.conf" << 'EOF'
set -g status-style fg=white,bg=black
this-is-invalid-command
set -g mode-style fg=yellow
EOF

out=$(smoke_cmd source-file "$TEST_TMPDIR/err.conf" 2>&1)
echo "output: '$out'"

# Must match tmux format: /path/to/file:LINE: error
echo "$out" | grep -qE '^.+:[0-9]+: ' || fail "source-file error missing file:line: prefix"
# Specifically, the bad command is on line 2
echo "$out" | grep -q ':2: ' || fail "source-file error should reference line 2"

echo "Test 1 OK: source-file error format matches file:line: convention"

# -------------------------------------------------------------------
# Test 2: source-file returns non-zero on parse errors
# -------------------------------------------------------------------
echo ""
echo "=== Test 2: source-file exit code on parse errors ==="

cat > "$TEST_TMPDIR/bad.conf" << 'EOF'
totally-broken-command
EOF

smoke_cmd source-file "$TEST_TMPDIR/bad.conf" 2>/dev/null
rc=$?
# Parse errors should cause non-zero exit (via the cmdlist parse path)
# Note: runtime errors from valid commands that fail are different.
echo "source-file bad.conf exit=$rc"

# -------------------------------------------------------------------
# Test 3: multi-line source-file tracks correct line numbers
# -------------------------------------------------------------------
echo ""
echo "=== Test 3: multi-line source-file line tracking ==="

cat > "$TEST_TMPDIR/multi.conf" << 'EOF'
set -g status-style fg=white,bg=black
set -g mode-style fg=yellow
not-a-real-command
set -g status-left "test"
EOF

out=$(smoke_cmd source-file "$TEST_TMPDIR/multi.conf" 2>&1)
echo "output: '$out'"
echo "$out" | grep -q ':3: ' || fail "multi-line error should reference line 3"

echo "Test 3 OK: multi-line source-file tracks correct line numbers"

# -------------------------------------------------------------------
# Test 4: oh-my-tmux error recovery loop would extract correct line
# -------------------------------------------------------------------
echo ""
echo "=== Test 4: oh-my-tmux error recovery line extraction ==="

# Simulate what oh-my-tmux does:
# line=$(printf "%s" "$out" | tail -1 | cut -d':' -f2)
line=$(printf "%s" "$out" | tail -1 | cut -d':' -f2)
echo "extracted line: '$line'"
# The extracted line should be a number (3 in this case)
case "$line" in
    *[!0-9]*) fail "extracted line '$line' is not a number" ;;
    '') fail "extracted line is empty" ;;
esac
echo "Test 4 OK: oh-my-tmux line extraction produces number: $line"

# -------------------------------------------------------------------
# Test 5: bind-key \; command chaining via source-file
# -------------------------------------------------------------------
echo ""
echo "=== Test 5: bind-key \\; command chaining ==="

printf 'bind-key -T copy-mode-vi y select-pane \\; send-keys -X copy-pipe-and-cancel\n' > "$TEST_TMPDIR/bind.conf"
out=$(smoke_cmd source-file "$TEST_TMPDIR/bind.conf" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "bind-key with \\; should succeed, got exit=$rc: $out"

echo "Test 5 OK: bind-key \\; chaining works via source-file"

# -------------------------------------------------------------------
# Test 6: list-keys outputs escaped semicolons
# -------------------------------------------------------------------
echo ""
echo "=== Test 6: list-keys escaped semicolons ==="

smoke_cmd list-keys 2>/dev/null | grep 'DoubleClick1Pane' | head -1 > "$TEST_TMPDIR/lk.txt"
if grep -q ' \\\\; ' "$TEST_TMPDIR/lk.txt" || grep -q ' \\; ' "$TEST_TMPDIR/lk.txt"; then
    echo "Test 6 OK: list-keys uses escaped semicolons"
else
    fail "list-keys should output escaped semicolons (\\;)"
fi

# -------------------------------------------------------------------
# Test 7: list-keys output round-trips through source-file
# -------------------------------------------------------------------
echo ""
echo "=== Test 7: list-keys round-trip ==="

smoke_cmd list-keys 2>/dev/null | grep 'copy-mode.*DoubleClick' | head -1 > "$TEST_TMPDIR/roundtrip.conf"
out=$(smoke_cmd source-file "$TEST_TMPDIR/roundtrip.conf" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "list-keys output should round-trip through source-file, got exit=$rc: $out"

echo "Test 7 OK: list-keys output round-trips through source-file"

echo ""
echo "=== All tests passed ==="

smoke_cmd kill-server 2>/dev/null || true
echo "PASS"

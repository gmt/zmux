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

# semicolon-chaining.sh – validate \; command chaining through the
# server protocol, not just the parser.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init semicolon-chaining
smoke_use_real_shell || exit $?

TMUX_LINK="$SMOKE_BIN_DIR/tmux"
SESSION_NAME="semicolon"

smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" new-session -d -s "$SESSION_NAME" || {
    echo "failed to start server"
    exit 1
}
smoke_register_server_with_socket "$TMUX_LINK" "$TEST_SOCKET" "$TEST_NAME" >/dev/null 2>&1 || true

# --- Case 1: Two-command chaining via \; ---
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" \
    set -g status-left "chain-A" \; set -g status-right "chain-B" || {
    echo "case 1: chained set commands failed"
    exit 1
}

val_left=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv status-left)
val_right=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv status-right)

[ "$val_left" = "chain-A" ] || {
    echo "case 1: status-left expected 'chain-A', got '$val_left'"
    exit 1
}
[ "$val_right" = "chain-B" ] || {
    echo "case 1: status-right expected 'chain-B', got '$val_right'"
    exit 1
}

# --- Case 2: Triple chaining ---
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" \
    set -g base-index 1 \; set -g renumber-windows on \; set -g status-interval 5 || {
    echo "case 2: triple chained set commands failed"
    exit 1
}

val_base=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv base-index)
val_renum=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv renumber-windows)
val_interval=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv status-interval)

[ "$val_base" = "1" ] || {
    echo "case 2: base-index expected '1', got '$val_base'"
    exit 1
}
[ "$val_renum" = "on" ] || {
    echo "case 2: renumber-windows expected 'on', got '$val_renum'"
    exit 1
}
[ "$val_interval" = "5" ] || {
    echo "case 2: status-interval expected '5', got '$val_interval'"
    exit 1
}

# --- Case 3: bind-key with chained action ---
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" \
    bind r set -g status-left "reloaded" \; display "done" || {
    echo "case 3: bind-key with chaining failed"
    exit 1
}

binding=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" list-keys 2>/dev/null | grep ' r ')
[ -n "$binding" ] || {
    echo "case 3: no binding found for key 'r'"
    exit 1
}

# --- Case 4: Semicolons inside quotes are not separators ---
smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" \
    set -g status-left "hello; world" || {
    echo "case 4: set with semicolon in value failed"
    exit 1
}

val_semi=$(smoke_exec_env "$TMUX_LINK" -S "$TEST_SOCKET" show-options -gv status-left)
[ "$val_semi" = "hello; world" ] || {
    echo "case 4: status-left expected 'hello; world', got '$val_semi'"
    exit 1
}

smoke_cleanup_socket "$TMUX_LINK" "$TEST_SOCKET"

exit 0

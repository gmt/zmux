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

# compat-argv0-config.sh – prove argv[0] controls default config family
# regardless of absolute/relative path or symlink versus copied binary.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init compat-argv0-config
smoke_use_real_shell || exit $?

TMUX_LINK_DIR="$TEST_TMPDIR/bin"
TMUX_LINK="$TMUX_LINK_DIR/tmux"
TMUX_COPY_DIR="$TEST_TMPDIR/copy"
TMUX_COPY="$TMUX_COPY_DIR/tmux"
SESSION_NAME="argv0cfg"

mkdir -p "$TMUX_LINK_DIR" "$TMUX_COPY_DIR" "$SMOKE_HOME/.config/zmux" "$SMOKE_HOME/.config/tmux"
ln -sf "$TEST_ZMUX" "$TMUX_LINK"
cp "$TEST_ZMUX" "$TMUX_COPY"
chmod +x "$TMUX_COPY"

cat <<'EOF' >"$SMOKE_HOME/.config/zmux/zmux.conf"
set-option -g status-left zmux-xdg
EOF

cat <<'EOF' >"$SMOKE_HOME/.config/tmux/tmux.conf"
set-option -g status-left tmux-xdg
EOF

run_case() {
    label=$1
    cwd=$2
    program=$3
    expected=$4
    socket="$TEST_SOCKET.$label"
    session="$SESSION_NAME-$label"

    (
        cd "$cwd" &&
        smoke_exec_env "$program" -S "$socket" new-session -d -s "$session"
    ) || {
        echo "$label failed to start server with $program"
        exit 1
    }

    actual=$(
        cd "$cwd" &&
        smoke_exec_env "$program" -S "$socket" show-options -gv status-left
    ) || {
        echo "$label failed to read status-left with $program"
        exit 1
    }

    [ "$actual" = "$expected" ] || {
        echo "$label loaded wrong config family: $actual"
        exit 1
    }

    (
        cd "$cwd" &&
        smoke_exec_env "$program" -S "$socket" -f/dev/null kill-server >/dev/null 2>&1
    ) || true
}

run_case native-abs "$SMOKE_ROOT_DIR" "$TEST_ZMUX" "zmux-xdg"
run_case tmux-symlink-abs "$SMOKE_ROOT_DIR" "$TMUX_LINK" "tmux-xdg"
run_case tmux-symlink-rel "$TMUX_LINK_DIR" "./tmux" "tmux-xdg"
run_case tmux-copy-abs "$SMOKE_ROOT_DIR" "$TMUX_COPY" "tmux-xdg"
run_case tmux-copy-rel "$TMUX_COPY_DIR" "./tmux" "tmux-xdg"

exit 0

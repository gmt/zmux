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

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

# Rename internal source/module filenames. Oracle tmux references are left
# alone on purpose; this script is only for the port's own namespace.
[ -e src/tmux.zig ] && mv src/tmux.zig src/zmux.zig
[ -e src/tmux-protocol.zig ] && mv src/tmux-protocol.zig src/zmux-protocol.zig
[ -e tmux-to-zmux.code-workspace ] && mv tmux-to-zmux.code-workspace zmux-workspace.code-workspace

internal_files=$(rg -l \
    'tmux-protocol\.zig|src/tmux\.zig|TmuxProc|TmuxPeer|TMUX_VERSION|TMUX_CONF|TMUX_SOCK|TMUX_TERM|TMUX_LOCK_CMD|tmux_conf|tmux_sock|tmux_term|tmux_lock_cmd' \
    src build.zig regress smoke.md README.md zmux-workspace.code-workspace 2>/dev/null || true)

if [ -n "$internal_files" ]; then
    perl -0pi -e '
        s/tmux-protocol\.zig/zmux-protocol.zig/g;
        s#src/tmux\.zig#src/zmux.zig#g;
        s/\bTmuxProc\b/ZmuxProc/g;
        s/\bTmuxPeer\b/ZmuxPeer/g;
        s/\bTMUX_VERSION\b/ZMUX_VERSION/g;
        s/\bTMUX_CONF\b/ZMUX_CONF/g;
        s/\bTMUX_SOCK\b/ZMUX_SOCK/g;
        s/\bTMUX_TERM\b/ZMUX_TERM/g;
        s/\bTMUX_LOCK_CMD\b/ZMUX_LOCK_CMD/g;
        s/\btmux_conf\b/zmux_conf/g;
        s/\btmux_sock\b/zmux_sock/g;
        s/\btmux_term\b/zmux_term/g;
        s/\btmux_lock_cmd\b/zmux_lock_cmd/g;
    ' $internal_files
fi

# Move runtime namespace to zmux.
perl -0pi -e '
    s/\$TMUX_TMPDIR:\x2ftmp/\$ZMUX_TMPDIR:\x2ftmp/g;
    s#\x2fetc\x2ftmux\.conf:~\x2f\.tmux\.conf:\$XDG_CONFIG_HOME\x2ftmux\x2ftmux\.conf:~\x2f\.config\x2ftmux\x2ftmux\.conf#\x2fetc\x2fzmux.conf:~\x2f.zmux.conf:\$XDG_CONFIG_HOME\x2fzmux\x2fzmux.conf:~\x2f.config\x2fzmux\x2fzmux.conf#g;
' build.zig 2>/dev/null || true

perl -0pi -e '
    s/std\.posix\.getenv\("TMUX"\)/std.posix.getenv("ZMUX")/g;
    s/cl\.environ\.entries\.get\("TMUX"\)/cl.environ.entries.get("ZMUX")/g;
    s/TMUX_TMPDIR/ZMUX_TMPDIR/g;
    s#\{s\}/tmux-\{d\}#\{s\}/zmux-{d}#g;
    s/env TMUX=/env ZMUX=/g;
    s/\[tmux\]/[zmux]/g;
' src/zmux.zig src/server-client.zig src/options-table.zig regress/smoke_harness.py smoke.md 2>/dev/null || true

echo "Renamed internal tmux namespace to zmux where applicable."

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

# new-session-size.sh – default 80×24 dimensions and explicit -x/-y override.
# Based on tmux/regress/new-session-size.sh.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init new-session-size

# Default size should be 80x24
smoke_cmd new-session -d -s s1 || exit 1
SIZE=$(smoke_cmd display-message -p -t s1:0 '#{window_width}x#{window_height}' 2>/dev/null)
[ "$SIZE" = "80x24" ] || { echo "default size wrong: $SIZE"; exit 1; }

# Explicit size via -x/-y
smoke_cmd new-session -d -s s2 -x 120 -y 40 || exit 1
SIZE=$(smoke_cmd display-message -p -t s2:0 '#{window_width}x#{window_height}' 2>/dev/null)
[ "$SIZE" = "120x40" ] || { echo "explicit size wrong: $SIZE"; exit 1; }

exit 0

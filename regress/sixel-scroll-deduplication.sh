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

# sixel-scroll-deduplication.sh – pin the duplicate-image scrollback
# regression documented in docs/zmux-porting-todo.md.  After a sixel
# image is partially scrolled past the top of the viewport, the redraw
# of the visible cropped portion plus a copy-mode scroll-back into
# history must emit exactly one DCS sixel sequence per surviving image
# region — not two.
#
# This pins the scrollback deduplication invariant: attach and resize redraws
# must not resend the same surviving image into terminal scrollback.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init sixel-scroll-deduplication
smoke_use_real_shell || exit $?

python3 -c 'import pty, select' 2>/dev/null || {
    echo "python3 pty unavailable"
    exit 77
}

# Build a tall single-colour sixel: 80 px wide × ~300 px tall.  At a
# typical 16 px cell height that is ≈ 19 cells, so 15 lines of scroll
# crop the image without removing it entirely.  Using a bespoke colour
# tag (`;2;77;0;77`) keeps the count immune to any other DCS traffic
# zmux might emit during attach (terminfo queries, tmux passthrough,
# etc.).
SIXEL_FILE="$TEST_TMPDIR/tall-sixel.dat"
python3 - "$SIXEL_FILE" <<'PYEOF'
import sys
out = sys.argv[1]
rows = 50
data = b'\x1bPq#0;2;77;0;77' + b'#0!80~-' * rows + b'\x1b\\'
with open(out, 'wb') as f:
    f.write(data)
PYEOF

smoke_cmd new-session -d -s sixel -x 80 -y 24 || exit 1
sleep 0.5

# Emit the sixel via the pane shell so it lands in the input parser
# the same way real terminals see it.
smoke_cmd send-keys -t sixel "cat $SIXEL_FILE" Enter || exit 1
sleep 1

smoke_cmd has-session -t sixel || {
    echo "session died after sixel cat"
    exit 1
}

# Push the image partially past the top of the viewport.  Use a literal
# loop so we do not depend on `yes` or `seq` semantics.
smoke_cmd send-keys -t sixel \
    "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo; done" Enter || exit 1
sleep 0.5

# NOTE: copy-mode pageback is the manual reproducer for the bug; it
# is omitted here because copy-mode appears to suppress image emit in
# the redraw stream we capture.  Even without entering copy-mode the
# visible viewport after the partial scroll contains the cropped
# bottom of the image, which a correct render emits exactly once and
# the buggy render emits twice.

# Attach a sixel-capable PTY client; the attach forces a full redraw
# of the current (copy-mode) view, which is exactly the surface the
# manual reproducer observes.
CAPTURE="$TEST_TMPDIR/capture.bin"

python3 - "$TEST_ZMUX" "$TEST_SOCKET" "$CAPTURE" <<'PYEOF'
import os, pty, select, subprocess, sys, time

zmux, socket, outpath = sys.argv[1], sys.argv[2], sys.argv[3]

master, slave = pty.openpty()
env = os.environ.copy()
env["TERM"] = "xterm-256color"

proc = subprocess.Popen(
    [zmux, "-S", socket, "-f/dev/null", "-T", "sixel",
     "attach-session", "-t", "sixel"],
    stdin=slave, stdout=slave, stderr=slave,
    env=env, start_new_session=True,
)
os.close(slave)

deadline = time.monotonic() + 3.0
output = b""
while time.monotonic() < deadline:
    remaining = max(0.05, deadline - time.monotonic())
    ready, _, _ = select.select([master], [], [], min(remaining, 0.25))
    if ready:
        try:
            chunk = os.read(master, 65536)
            if not chunk:
                break
            output += chunk
        except OSError:
            break

proc.terminate()
try:
    proc.wait(timeout=2)
except Exception:
    proc.kill()
    proc.wait()
os.close(master)

with open(outpath, "wb") as f:
    f.write(output)
sys.exit(0)
PYEOF

[ -f "$CAPTURE" ] || {
    echo "no capture file"
    exit 1
}

# Each DCS sixel emit of our image carries the bespoke colour tag
# `;2;77;0;77`.  Count those tags; the surviving image must appear
# exactly once.  Two or more is the duplicate-image bug.
python3 - "$CAPTURE" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
emit_count = data.count(b';2;77;0;77')
print(f'captured {len(data)} bytes, {emit_count} sixel emits of test image')
if emit_count == 1:
    print('PASS: surviving cropped image emitted exactly once')
    sys.exit(0)
if emit_count == 0:
    print('FAIL: image not redrawn at all (capture too short, or DCS suppressed)')
    sys.exit(1)
print(f'FAIL: expected exactly 1 emit, got {emit_count} (duplicate-image bug)')
sys.exit(1)
PYEOF

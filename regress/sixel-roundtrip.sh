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

# sixel-roundtrip.sh – verify that a sixel image emitted by a
# deterministic helper pane is parsed, stored, and re-emitted as DCS
# sixel data when a real TTY client attaches.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init sixel-roundtrip
smoke_use_helper_shell emit-sixel || exit $?

# Skip if python3 or pty module is unavailable.
python3 -c 'import pty, select' 2>/dev/null || { echo "python3 pty unavailable"; exit 77; }

# Start a detached session.
smoke_cmd new-session -d -s sixel -x 80 -y 24 || exit 1

# Give zmux time to parse the helper-emitted sixel data and store the image.
sleep 1

# Verify the session survived sixel ingestion.
smoke_cmd has-session -t sixel || { echo "session died after sixel input"; exit 1; }

# Attach a real PTY client and capture the rendered byte stream.
# The DCS sixel data should appear in the output.
CAPTURE="$TEST_TMPDIR/capture.bin"

python3 - "$TEST_ZMUX" "$TEST_SOCKET" "$CAPTURE" <<'PYEOF'
import os, pty, select, subprocess, sys, time

zmux, socket, outpath = sys.argv[1], sys.argv[2], sys.argv[3]

master, slave = pty.openpty()
env = os.environ.copy()
env["TERM"] = "xterm-256color"

proc = subprocess.Popen(
    [zmux, "-S", socket, "-f/dev/null", "attach-session", "-t", "sixel"],
    stdin=slave, stdout=slave, stderr=slave,
    env=env, start_new_session=True,
)
os.close(slave)

# Collect rendered output for up to 3 seconds.
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

[ $? -eq 0 ] || { echo "python capture failed"; exit 1; }
[ -f "$CAPTURE" ] || { echo "no capture file"; exit 1; }

# Verify: the rendered output must contain our sixel colour definition
# and sixel data, proving the full parse → store → re-emit pipeline.
if python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
ok = True

# Must contain DCS sixel header (ESC P ... q)
if b'\x1bP' not in data:
    print('FAIL: no DCS (ESC P) in output')
    ok = False

# Must contain our red colour definition
if b';2;100;0;0' not in data:
    print('FAIL: no colour definition ;2;100;0;0 in output')
    ok = False

# Must contain our sixel pixel data
if b'!4~' not in data:
    print('FAIL: no sixel data !4~ in output')
    ok = False

if ok:
    print(f'PASS: sixel round-trip verified ({len(data)} bytes captured)')
sys.exit(0 if ok else 1)
" "$CAPTURE"; then
    exit 0
else
    echo "capture size: $(wc -c < "$CAPTURE") bytes"
    exit 1
fi

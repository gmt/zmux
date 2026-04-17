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

# sixel-capable-roundtrip.sh – verify that a client whose terminal is
# advertised as sixel-capable receives real DCS sixel data, not the text
# placeholder.  Companion to sixel-roundtrip.sh, which exercises the
# non-capable fallback branch; together the two pin both arms of the
# capability gate added by `tty-draw: gate sixel output on client
# capability`.
#
# The harness PTY does not respond to DA1/DA2, and xterm-256color
# terminfo does not advertise the Sxl flag, so by default every PTY
# client is classified as non-capable.  We force capability on by
# passing `-T sixel` to the client invocation, which sends an explicit
# feature bit via the identify_features imsg at attach time.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init sixel-capable-roundtrip
smoke_use_helper_shell emit-sixel || exit $?

python3 -c 'import pty, select' 2>/dev/null || {
    echo "python3 pty unavailable"
    exit 77
}

# Start a detached session that runs the sixel-emitting helper.
smoke_cmd new-session -d -s sixel -x 80 -y 24 || exit 1

# Give zmux time to parse the helper-emitted sixel data and store the image.
sleep 1

smoke_cmd has-session -t sixel || {
    echo "session died after sixel input"
    exit 1
}

# Attach a real PTY client and capture the rendered byte stream.
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

[ $? -eq 0 ] || {
    echo "python capture failed"
    exit 1
}
[ -f "$CAPTURE" ] || {
    echo "no capture file"
    exit 1
}

# Strict assertion: a sixel-capable client must receive DCS sixel data
# with the expected colour and pixel patterns, and must NOT receive the
# fallback placeholder.  Either deviation indicates the capability gate
# is misclassifying or the DCS emit path is broken.
if python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()

has_dcs = b'\x1bP' in data
has_colour = b';2;100;0;0' in data
has_sixel_data = b'!4~' in data
has_fallback = b'SIXEL IMAGE' in data

if has_dcs and has_colour and has_sixel_data and not has_fallback:
    print(f'PASS: capable client received DCS ({len(data)} bytes captured)')
    sys.exit(0)

print('FAIL: capable client did not receive expected DCS sixel data')
print(f'  has_dcs={has_dcs} has_colour={has_colour} has_sixel_data={has_sixel_data} has_fallback={has_fallback}')
print(f'  capture size: {len(data)} bytes')
sys.exit(1)
" "$CAPTURE"; then
    exit 0
else
    exit 1
fi

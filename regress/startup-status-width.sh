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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init startup-status-width

python3 -c 'import pty, pexpect.ANSI' 2>/dev/null || {
    echo "python3 pty or pexpect unavailable"
    exit 77
}

python3 - "$TEST_ZMUX" "$TEST_SOCKET" "$TEST_TMPDIR" <<'PYEOF'
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import fcntl
import warnings

warnings.simplefilter("ignore", UserWarning)

from pexpect import ANSI

zmux, socket_path, root = sys.argv[1:4]
capture_path = os.path.join(root, "startup-status-width.bin")
rows = 37
cols = 132

master, slave = pty.openpty()
os.environ["TERM"] = "xterm-256color"
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

env = os.environ.copy()
env["TERM"] = "xterm-256color"

proc = subprocess.Popen(
    [zmux, "-S", socket_path, "-f/dev/null", "new-session"],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    env=env,
    start_new_session=True,
)
os.close(slave)

output = bytearray()
deadline = time.monotonic() + 1.2
while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.05)
    if not ready:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    output += chunk

with open(capture_path, "wb") as handle:
    handle.write(output)

os.chdir(root)
screen = ANSI.ANSI(rows, cols)
screen.write(output.decode("utf-8", "ignore"))

bad_rows = []
for row in (34, 35, 36):
    rendered = "".join(screen.get_abs(row, col) for col in range(1, cols + 1))
    if len(rendered.rstrip()) != cols:
        bad_rows.append((row, rendered.rstrip()))

try:
    os.killpg(proc.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
try:
    proc.wait(timeout=2)
except Exception:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=2)
os.close(master)

if bad_rows:
    print("startup status bar did not reach full width")
    for row, rendered in bad_rows:
        print(f"row {row}: len={len(rendered)} text={rendered!r}")
    print(f"capture={capture_path}")
    sys.exit(1)

print(f"PASS: startup status width stable ({capture_path})")
PYEOF

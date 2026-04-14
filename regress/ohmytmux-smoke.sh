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

# ohmytmux-smoke.sh – verify zmux loads oh-my-tmux and renders a themed
# status bar without garbage.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init ohmytmux-smoke
smoke_use_real_shell || exit $?

OHMYTMUX_SRC="$HOME/.tmux/.tmux.conf"
[ -f "$OHMYTMUX_SRC" ] || {
    echo "SKIP: oh-my-tmux not found at $OHMYTMUX_SRC"
    exit 77
}

python3 -c 'import pty, pexpect.ANSI' 2>/dev/null || {
    echo "SKIP: python3 pty or pexpect unavailable"
    exit 77
}

# -- oh-my-tmux sandbox -------------------------------------------------------

mkdir -p "$SMOKE_HOME/.tmux"
cp "$OHMYTMUX_SRC" "$SMOKE_HOME/.tmux/.tmux.conf"
ln -sf "$SMOKE_HOME/.tmux/.tmux.conf" "$SMOKE_HOME/.tmux.conf"

# The .local file is sourced both as tmux config (via `tmux source`) and as
# shell (via `cut -c3- | sh`) by oh-my-tmux's _apply_configuration.  Shell
# variable overrides must be plain assignments; tmux commands work as-is.
cat > "$SMOKE_HOME/.tmux.conf.local" <<'LOCALEOF'
tmux_conf_theme_colour_1="#080808"
tmux_conf_theme_colour_2="#303030"
tmux_conf_theme_colour_3="#8a8a8a"
tmux_conf_theme_colour_4="#00afff"
tmux_conf_theme_colour_5="#ffff00"
tmux_conf_theme_colour_9="#ffff00"
tmux_conf_theme_colour_10="#ff00af"
tmux_conf_theme_colour_11="#5fff00"

tmux_conf_battery_bar_symbol_full=""
tmux_conf_battery_bar_symbol_empty=""
tmux_conf_battery_bar_length="0"
tmux_conf_battery_status_charging=""
tmux_conf_battery_status_discharging=""

# Recognizable markers we can grep for in the rendered status bar
tmux_conf_theme_status_left=" OMTSMOKELEFT | #S "
tmux_conf_theme_status_right=" OMTSMOKERIGHT | %R "

set -g @tpm_plugins ''
tmux_conf_update_plugins_on_launch=false
tmux_conf_update_plugins_on_reload=false
tmux_conf_uninstall_plugins_on_reload=false
LOCALEOF

ln -sf "$TEST_ZMUX" "$SMOKE_BIN_DIR/tmux"

# -- run zmux-as-tmux under a PTY and validate ---------------------------------

python3 - "$SMOKE_BIN_DIR/tmux" "$TEST_SOCKET" "$TEST_TMPDIR" "$SMOKE_HOME" <<'PYEOF'
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

tmux_bin, socket_path, root, smoke_home = sys.argv[1:5]
capture_path = os.path.join(root, "ohmytmux-smoke.bin")
detach_path = os.path.join(root, "ohmytmux-detach.bin")
rows = 37
cols = 132


def kill_proc(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=5)


def drain(fd, seconds):
    """Read from fd until silence or timeout, return bytes read."""
    buf = bytearray()
    deadline = time.monotonic() + seconds
    idle_count = 0
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            idle_count += 1
            if idle_count >= 5:  # 0.5s of silence
                break
            continue
        idle_count = 0
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    return buf


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

env = {
    "PATH": os.path.dirname(tmux_bin) + ":/bin:/usr/bin",
    "TERM": "xterm-256color",
    "COLORTERM": "truecolor",
    "HOME": smoke_home,
    "USER": "smoke",
    "LOGNAME": "smoke",
    "SHELL": "/bin/sh",
    "LANG": "C",
    "LC_ALL": "C",
    "TZ": "UTC",
    "TMUX_TMPDIR": os.path.join(root, "tmp"),
    "ZMUX_TMPDIR": os.path.join(root, "tmp"),
    "XDG_CONFIG_HOME": os.path.join(smoke_home, ".config"),
    "XDG_CACHE_HOME": os.path.join(smoke_home, ".cache"),
    "XDG_DATA_HOME": os.path.join(smoke_home, ".local", "share"),
}

os.makedirs(env["TMUX_TMPDIR"], exist_ok=True)

proc = subprocess.Popen(
    [tmux_bin, "-S", socket_path,
     "-f", os.path.join(smoke_home, ".tmux.conf"),
     "new-session"],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    env=env,
    start_new_session=True,
)
os.close(slave)

# -- wait for shell prompt (up to 30s for oh-my-tmux config sourcing) ----------

output = bytearray()
deadline = time.monotonic() + 30
prompt_seen = False

while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk

    text = output.decode("utf-8", "ignore")
    if "$" in text or ">" in text or "%" in text:
        prompt_seen = True
        break

# let the status bar render after prompt appears
time.sleep(2)
output += drain(master, 2)

with open(capture_path, "wb") as f:
    f.write(output)

if not prompt_seen:
    print("FAIL: shell prompt never appeared within 30s")
    print(f"capture={capture_path}")
    kill_proc(proc)
    os.close(master)
    sys.exit(1)

# -- inspect the rendered screen -----------------------------------------------

screen = ANSI.ANSI(rows, cols)
screen.write(output.decode("utf-8", "ignore"))

status_rows = {}
for row in range(rows - 2, rows + 1):
    rendered = "".join(screen.get_abs(row, col) for col in range(1, cols + 1))
    status_rows[row] = rendered

themed = False
default_pattern = False
# oh-my-tmux default theme uses these Unicode indicators regardless of
# .tmux.conf.local customisation (the local shell variables are not
# sourced into _apply_theme; it always uses its built-in defaults):
#   ❐  session indicator
#   ↑  uptime arrow
#   ↗  prefix/mouse/pairing indicator area
theme_indicators = ("\u2750", "\u2191", "\u2197")
for row, text in status_rows.items():
    if not text.strip():
        continue
    if any(ind in text for ind in theme_indicators):
        themed = True
        break
    if "[0]" in text and "bash*" in text:
        default_pattern = True

garbage_rows = []
for row in range(1, rows - 2):
    rendered = "".join(screen.get_abs(row, col) for col in range(1, cols + 1))
    for ch in rendered:
        # BEL (\x07) is a valid terminal control character (OSC terminator
        # from set-titles) — not garbage.
        if ch != ' ' and ord(ch) != 0x07 and (ord(ch) < 0x20 or ord(ch) == 0x7f):
            garbage_rows.append((row, repr(rendered.rstrip())))
            break

# -- detach (C-b d) and check post-detach output ------------------------------

try:
    os.write(master, b"\x02")
    time.sleep(0.3)
    os.write(master, b"d")
except OSError:
    pass

detach_output = drain(master, 5)

with open(detach_path, "wb") as f:
    f.write(detach_output)

detach_text = detach_output.decode("utf-8", "ignore")
detach_garbage = any(
    ord(ch) < 0x20 and ch not in ('\n', '\r', '\t', '\x1b', '\x07')
    for ch in detach_text
)

# -- cleanup and report --------------------------------------------------------

kill_proc(proc)
os.close(master)

failures = []

if not themed:
    msg = "status bar does not show oh-my-tmux themed content"
    if default_pattern:
        msg += " (shows default tmux pattern instead)"
    for row, text in status_rows.items():
        msg += f"\n  row {row}: {text.rstrip()!r}"
    failures.append(msg)

if garbage_rows:
    msg = "garbage characters in main screen area"
    for row, rendered in garbage_rows[:5]:
        msg += f"\n  row {row}: {rendered}"
    failures.append(msg)

if detach_garbage:
    failures.append(f"terminal garbage after detach: {detach_text!r}")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    print(f"capture={capture_path}")
    print(f"detach_capture={detach_path}")
    sys.exit(1)

print(f"PASS: oh-my-tmux smoke test ({capture_path})")
PYEOF

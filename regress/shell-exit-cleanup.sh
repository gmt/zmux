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

# shell-exit-cleanup.sh – "exit" in a default-shell-like pane process
# must cleanly destroy the pane and, if it was the last pane, the
# session.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

smoke_init shell-exit-cleanup
smoke_use_helper_shell exit-on-exit-line || exit $?

# Start a session with a deterministic default-shell helper.
smoke_cmd new-session -d -s shellexit -x 80 -y 24 || exit 1

# Get the pane PID
PID=$(smoke_cmd display-message -p -t shellexit '#{pane_pid}' 2>/dev/null)
[ -z "$PID" ] && {
    echo "could not get pane pid"
    exit 1
}

# Verify the process is alive
kill -0 "$PID" 2>/dev/null || {
    echo "pane process $PID not running"
    exit 1
}

# Send "exit" to the helper.
smoke_cmd send-keys -t shellexit "exit" Enter

# Wait for the session to disappear (up to 5 seconds)
if ! smoke_wait_for 5 sh -c "! \"$TEST_ZMUX\" -S \"$TEST_SOCKET\" -f/dev/null has-session -t shellexit 2>/dev/null"; then
    echo "session still exists after exit"
    exit 1
fi

# The pane process should be gone
sleep 1
if kill -0 "$PID" 2>/dev/null; then
    echo "pane process $PID still alive after exit"
    exit 1
fi

exit 0

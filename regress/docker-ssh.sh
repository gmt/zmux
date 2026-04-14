#!/bin/sh
# Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES
# OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS,
# WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ARTIFACT_ROOT=${SMOKE_ARTIFACT_ROOT:-${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/zmux}
mkdir -p "$ARTIFACT_ROOT"
TMPDIR=$(mktemp -d "${ARTIFACT_ROOT%/}/zmux-docker-ssh.XXXXXX")
IMAGE_TAG=${SMOKE_DOCKER_IMAGE:-zmux-smoke:ssh}
TERM_MATRIX=${SMOKE_TERM_SET:-"tmux-256color screen-256color xterm-256color linux"}

cleanup() {
    if [ -n "${CID:-}" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup 0 1 2 3 15

docker build -f "$SCRIPT_DIR/Dockerfile.smoke" -t "$IMAGE_TAG" "$SCRIPT_DIR" >/dev/null

ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/id_ed25519" >/dev/null
AUTHORIZED_KEY=$(cat "$TMPDIR/id_ed25519.pub")

CID=$(docker run -d --rm -e AUTHORIZED_KEY="$AUTHORIZED_KEY" -p 127.0.0.1::22 "$IMAGE_TAG")
PORT=$(docker port "$CID" 22/tcp | tail -n1 | sed 's/.*://')

# Ignore host ssh_config so the smoke script behaves the same inside the
# namespaced runner, where OpenSSH may reject host-owned include files.
SSH="ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=$TMPDIR/known_hosts -i $TMPDIR/id_ed25519 -p $PORT root@127.0.0.1"

n=0
while [ "$n" -lt 30 ]; do
    if $SSH true >/dev/null 2>&1; then
        break
    fi
    sleep 1
    n=$((n + 1))
done

$SSH true >/dev/null 2>&1 || {
    echo "ssh never came up"
    exit 1
}

$SSH tmux -V | grep -q '^tmux ' || {
    echo "remote tmux missing"
    exit 1
}

$SSH /bin/sh <<'EOF'
set -eu
ffmpeg -hide_banner -f lavfi -i testsrc2=size=320x240:rate=24 -t 3 -y /tmp/zmux-smoke.mp4 >/dev/null 2>&1
cat >/root/zmux-truecolor.sh <<'SCRIPT'
#!/bin/sh
set -eu
i=0
while [ "$i" -lt 80 ]; do
    r=$(( (i * 3) % 255 ))
    g=$(( (i * 5) % 255 ))
    b=$(( (i * 7) % 255 ))
    printf '\033[48;2;%s;%s;%sm  \033[0m' "$r" "$g" "$b"
    i=$((i + 1))
done
printf '\n'
sleep 5
SCRIPT
chmod +x /root/zmux-truecolor.sh
EOF

for TERM_NAME in $TERM_MATRIX; do
    SOCK="smoke-${TERM_NAME}"
    LOG1="$TMPDIR/${TERM_NAME}.client1.log"
    LOG2="$TMPDIR/${TERM_NAME}.client2.log"

    $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null kill-server" >/dev/null 2>&1 || true
    $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null new-session -d -s smoke" >/dev/null
    $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null split-window -d -t smoke:0.0 'cacademo /tmp/zmux-smoke.mp4'" >/dev/null
    $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null split-window -d -t smoke:0.0 /root/zmux-truecolor.sh" >/dev/null

    (
        printf 'refresh-client -C 120,40\n'
        sleep 5
    ) | $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null -C attach-session -t smoke" >"$LOG1" 2>&1 &
    PID1=$!

    (
        printf 'refresh-client -C 100,32\n'
        sleep 5
    ) | $SSH "env TERM=$TERM_NAME COLORTERM=truecolor tmux -L $SOCK -f /dev/null -C attach-session -t smoke" >"$LOG2" 2>&1 &
    PID2=$!

    n=0
    while [ "$n" -lt 20 ]; do
        COUNT=$($SSH "tmux -L $SOCK -f /dev/null list-clients 2>/dev/null | wc -l" | tr -d ' ')
        [ "$COUNT" -ge 2 ] && break
        sleep 0.25
        n=$((n + 1))
    done

    COUNT=$($SSH "tmux -L $SOCK -f /dev/null list-clients 2>/dev/null | wc -l" | tr -d ' ')
    [ "$COUNT" -ge 2 ] || {
        echo "remote list-clients did not observe two viewers for $TERM_NAME"
        exit 1
    }

    SIZE=$($SSH "tmux -L $SOCK -f /dev/null display-message -p -t smoke:0 '#{window_width}x#{window_height}'")
    [ -n "$SIZE" ] || {
        echo "display-message produced no size for $TERM_NAME"
        exit 1
    }

    wait "$PID1" || exit 1
    wait "$PID2" || exit 1

    $SSH "tmux -L $SOCK -f /dev/null kill-server" >/dev/null 2>&1 || true
done

exit 0

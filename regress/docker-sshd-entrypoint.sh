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

set -eu

mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh

if [ -n "${AUTHORIZED_KEY:-}" ]; then
    printf '%s\n' "$AUTHORIZED_KEY" >/root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -A

cat >>/etc/ssh/sshd_config <<'EOF'
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
PrintMotd no
PermitUserEnvironment yes
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

exec /usr/bin/sshd -D -e

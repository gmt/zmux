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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUITE=${1:-fast}
shift || true

case "$SUITE" in
fast)
    TARGET_SUITE=smoke-fast
    ;;
oracle)
    TARGET_SUITE=smoke-oracle
    ;;
recursive)
    TARGET_SUITE=smoke-recursive
    ;;
soak)
    TARGET_SUITE=smoke-soak
    ;;
docker)
    TARGET_SUITE=smoke-docker
    ;;
all)
    TARGET_SUITE=smoke-all
    ;;
*)
    echo "usage: $0 [fast|oracle|recursive|soak|docker|all]" >&2
    exit 2
    ;;
esac

exec python3 "$SCRIPT_DIR/test_orchestrator.py" "$TARGET_SUITE" "$@"

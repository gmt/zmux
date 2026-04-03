#!/usr/bin/env sh
# Replay every file in fuzz/corpus/ through zmux-input-fuzzer (stdin mode).
set -e
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bin=${1:-"$root/zig-out/bin/zmux-input-fuzzer"}
for f in "$root/fuzz/corpus"/*; do
    [ -f "$f" ] || continue
    case "$f" in
    *.sh) continue ;;
    esac
    "$bin" <"$f"
done

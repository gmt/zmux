#!/usr/bin/env bash
#
# Copyright (c) Greg Turner
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

set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_ROOT="${TMUX_ROOT:-$LAB_ROOT/src}"
OUT_ROOT="${OUT_ROOT:-$LAB_ROOT/out}"
BUILD_ROOT="${BUILD_ROOT:-$LAB_ROOT/build}"
BUILD_SRC="$BUILD_ROOT/src"
REBUILD_DIR="${REBUILD_DIR:-$LAB_ROOT/rebuild}"
GDB_BUILD_DIR="$BUILD_ROOT/gdb"
XREF_OUT="$OUT_ROOT/xref"
GDB_OUT="$OUT_ROOT/gdb"
PP_OUT="$OUT_ROOT/pp"
NPROC="${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}"

DEFAULT_PP_SOURCES=(
    "cmd-split-window.c"
    "cmd-capture-pane.c"
    "grid.c"
    "screen-write.c"
    "input.c"
    "utf8.c"
)

log() {
    printf '[tmux-museum] %s\n' "$*"
}

# Populate a disposable build source mirror from the pristine tree and run
# autogen.sh there.  The pristine TMUX_ROOT is never written to.
ensure_build_src() {
    if [ -f "$BUILD_SRC/configure.ac" ] && [ -x "$BUILD_SRC/configure" ]; then
        return 0
    fi
    log "populating build source mirror from $TMUX_ROOT"
    rm -rf "$BUILD_SRC"
    cp -a "$TMUX_ROOT" "$BUILD_SRC"
    log "running autogen.sh in build source mirror"
    (cd "$BUILD_SRC" && ./autogen.sh)
}

build_xref() {
    mkdir -p "$XREF_OUT"
    log "building xref artifacts in $XREF_OUT"
    find "$TMUX_ROOT" \
        \( -path "$TMUX_ROOT/.git" -o -path "$TMUX_ROOT/compat" \) -prune -o \
        \( -name '*.c' -o -name '*.h' -o -name '*.y' \) -print | sort >"$XREF_OUT/cscope.files"
    (cd "$XREF_OUT" && cscope -bkq -i cscope.files)
    ctags -R -f "$XREF_OUT/tags" "$TMUX_ROOT"
    cat >"$XREF_OUT/README.txt" <<EOF
tmux xref lab
=============

Generated from:
  $TMUX_ROOT

Artifacts:
  cscope.files
  cscope.out
  cscope.in.out
  cscope.po.out
  tags

These are intended for navigation, reverse lookups, and tool-assisted
retrieval, not as canonical source.
EOF
}

build_gdb() {
    ensure_build_src
    mkdir -p "$GDB_BUILD_DIR" "$GDB_OUT"
    if [ ! -f "$GDB_BUILD_DIR/Makefile" ]; then
        log "configuring debug build in $GDB_BUILD_DIR"
        (
            cd "$GDB_BUILD_DIR"
            env CFLAGS="-O0 -ggdb3 -fno-omit-frame-pointer" CPPFLAGS="-DDEBUG" \
                "$BUILD_SRC/configure"
        )
    fi
    log "building debug binary in $GDB_BUILD_DIR"
    (
        cd "$GDB_BUILD_DIR"
        make -j"$NPROC" V=1 >"$GDB_OUT/build.log" 2>&1
    )
    ln -sfn "$GDB_BUILD_DIR/tmux" "$GDB_OUT/tmux"
    printf '%s\n' "$GDB_BUILD_DIR" >"$GDB_OUT/build-dir.txt"
    file "$GDB_BUILD_DIR/tmux" >"$GDB_OUT/file.txt"
    nm -an "$GDB_BUILD_DIR/tmux" >"$GDB_OUT/nm.txt"
    readelf -Ws "$GDB_BUILD_DIR/tmux" >"$GDB_OUT/readelf-symbols.txt"
    cat >"$GDB_OUT/README.txt" <<EOF
tmux gdb lab
============

Configured build dir:
  $GDB_BUILD_DIR

Curated outputs:
  tmux -> debug binary
  build.log
  file.txt
  nm.txt
  readelf-symbols.txt
EOF
}

compile_command_for_source() {
    local source="$1"
    local object="${source%.c}.o"
    if [ -f "$GDB_OUT/build.log" ]; then
        local logged
        logged="$(grep -F " $BUILD_SRC/$source" "$GDB_OUT/build.log" | grep -E '(^| )(gcc|clang)( |$).* -c ' | tail -n 1 || true)"
        if [ -n "$logged" ]; then
            printf '%s\n' "${logged%%&&*}"
            return 0
        fi
    fi
    make -C "$GDB_BUILD_DIR" -B -n V=1 "$object" 2>/dev/null |
        grep -E '(^| )(gcc|clang)( |$).* -c ' | tail -n 1 | sed 's/[[:space:]]*&&.*$//'
}

preprocess_source() {
    local source="$1"
    local out_i="$PP_OUT/${source%.c}.i"
    local out_cmd="$PP_OUT/${source%.c}.cmd.txt"
    local command
    command="$(compile_command_for_source "$source")"
    if [ -z "$command" ]; then
        log "no compile command found for $source"
        return 1
    fi
    printf '%s\n' "$command" >"$out_cmd"
    python3 - "$command" "$BUILD_SRC/$source" "$out_i" <<'PY'
import pathlib
import shlex
import subprocess
import sys

command, source, out_i = sys.argv[1:4]
parts = shlex.split(command)
source_path = pathlib.Path(source)
rewritten = []
i = 0
while i < len(parts):
    part = parts[i]
    if part in {"-c", "-MD", "-MMD", "-MP"}:
        i += 1
        continue
    if part in {"-o", "-MF", "-MT", "-MQ"}:
        i += 2
        continue
    if pathlib.Path(part).name == source_path.name:
        i += 1
        continue
    rewritten.append(part)
    i += 1
rewritten.extend(["-E", "-dD", "-CC", "-P", "-o", out_i, source])
subprocess.run(rewritten, check=True)
PY
}

build_pp() {
    mkdir -p "$PP_OUT"
    if [ ! -f "$GDB_BUILD_DIR/Makefile" ]; then
        build_gdb
    fi
    find "$PP_OUT" -maxdepth 1 \( -name '*.i' -o -name '*.cmd.txt' -o -name '*.d' -o -name 'manifest.txt' -o -name 'README.txt' \) -delete
    local sources=("$@")
    if [ "${#sources[@]}" -eq 0 ]; then
        sources=("${DEFAULT_PP_SOURCES[@]}")
    fi
    log "building curated preprocessed outputs in $PP_OUT"
    : >"$PP_OUT/manifest.txt"
    local source
    for source in "${sources[@]}"; do
        preprocess_source "$source"
        printf '%s\n' "$source" >>"$PP_OUT/manifest.txt"
    done
    cat >"$PP_OUT/README.txt" <<EOF
tmux pp lab
===========

Generated from the configured debug build in:
  $GDB_BUILD_DIR

Each *.i file is a curated preprocessed view with macros retained and line
markers stripped to make the result easier to read.
EOF
}

link_museum() {
    mkdir -p "$REBUILD_DIR"
    ln -sfn "$XREF_OUT" "$REBUILD_DIR/xref"
    ln -sfn "$GDB_OUT" "$REBUILD_DIR/gdb"
    ln -sfn "$PP_OUT" "$REBUILD_DIR/pp"
    log "projected curated links into $REBUILD_DIR"
}

main() {
    local stages=()
    local pp_sources=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            xref|gdb|pp|link|all)
                stages+=("$1")
                ;;
            *.c)
                pp_sources+=("$1")
                ;;
            *)
                printf 'unknown argument: %s\n' "$1" >&2
                exit 2
                ;;
        esac
        shift
    done
    if [ "${#stages[@]}" -eq 0 ]; then
        stages=(all)
    fi
    local stage
    for stage in "${stages[@]}"; do
        case "$stage" in
            xref)
                build_xref
                ;;
            gdb)
                build_gdb
                ;;
            pp)
                build_pp "${pp_sources[@]}"
                ;;
            link)
                link_museum
                ;;
            all)
                build_xref
                build_gdb
                build_pp "${pp_sources[@]}"
                link_museum
                ;;
        esac
    done
}

main "$@"

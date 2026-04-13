#!/usr/bin/env python3
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

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
DEFAULT_BINARY = ROOT_DIR / ".zig-cache" / "o"


def find_test_binary() -> pathlib.Path | None:
    if not DEFAULT_BINARY.exists():
        return None
    candidates: list[tuple[float, pathlib.Path]] = []
    for entry in DEFAULT_BINARY.iterdir():
        binary = entry / "test"
        if binary.is_file():
            candidates.append((binary.stat().st_mtime, binary))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compatibility wrapper for the timed zmux unit test runner.",
        epilog="Extra arguments after -- may only be repeated --test-filter values.",
    )
    parser.add_argument("--timeout", type=float, default=None)
    parser.add_argument("--direct", action="store_true")
    parser.add_argument("--no-watchdog", action="store_true")
    parser.add_argument("extra", nargs="*")
    return parser.parse_args(argv)


def parse_filters(extra: list[str]) -> list[str]:
    filters: list[str] = []
    i = 0
    while i < len(extra):
        arg = extra[i]
        if arg == "--":
            i += 1
            continue
        if arg != "--test-filter":
            raise SystemExit(f"unsupported extra argument: {arg}")
        i += 1
        if i >= len(extra):
            raise SystemExit("missing value after --test-filter")
        filters.append(extra[i])
        i += 1
    return filters


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.no_watchdog:
        print("watchdog: timers are always enabled now; ignoring --no-watchdog", file=sys.stderr)
    if args.direct:
        print("watchdog: direct mode is now the default path", file=sys.stderr)

    binary = find_test_binary()
    if binary is None:
        print("watchdog: no compiled test binary found; run 'zig build test-compile' first", file=sys.stderr)
        return 1

    cmd = [sys.executable, str(SCRIPT_DIR / "test_orchestrator.py"), "zig-unit", "--zig-test-binary", str(binary)]
    if args.timeout is not None:
        cmd.extend(["--timeout-override", str(args.timeout)])
    for filter_text in parse_filters(args.extra):
        cmd.extend(["--test-filter", filter_text])

    return subprocess.call(cmd, cwd=ROOT_DIR)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

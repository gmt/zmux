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

"""Test watchdog for zmux unit tests.

Wraps ``zig build test`` with hang detection, adaptive timeout, signal
escalation, and diagnostic re-run to identify the specific hanging test.

Usage::

    python3 regress/test-watchdog.py                # wrapped mode (default)
    python3 regress/test-watchdog.py --direct       # direct binary mode
    python3 regress/test-watchdog.py --no-watchdog   # pass-through, no timeout
    python3 regress/test-watchdog.py --timeout 60   # override timeout
    python3 regress/test-watchdog.py -- --test-filter grid  # pass args to zig
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import pathlib
import re
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import time

# ── Constants ────────────────────────────────────────────────────────────

STATS_FILE = pathlib.Path(".zig-cache/test-watchdog-stats.json")
DEFAULT_TIMEOUT = 120           # seconds, conservative initial
MIN_RUNS_FOR_DYNAMIC = 5        # data points before switching to adaptive
SIGMA_MULTIPLIER = 3            # mean + N*stddev
MIN_DYNAMIC_TIMEOUT = 15        # floor for adaptive timeout (seconds)
ESCALATION_PAUSE = 2            # seconds between kill signals
DIAG_PER_TEST_TIMEOUT = 10      # seconds of inactivity per test in diagnostic

# ── Output helpers ───────────────────────────────────────────────────────

def warn(msg: str) -> None:
    print(f"watchdog: {msg}", file=sys.stderr, flush=True)

# ── Stats ────────────────────────────────────────────────────────────────

def load_stats() -> dict:
    if not STATS_FILE.exists():
        return {"schema_version": 1, "runs": []}
    try:
        return json.loads(STATS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {"schema_version": 1, "runs": []}


def save_stats(stats: dict) -> None:
    STATS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(stats, indent=2) + "\n")
    tmp.rename(STATS_FILE)


def record_run(
    stats: dict,
    elapsed_s: float | None,
    exit_code: int | None,
    timeout_used_s: float,
    hung_test: str | None = None,
    test_count: int | None = None,
) -> None:
    stats["runs"].append({
        "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
        "elapsed_s": round(elapsed_s, 2) if elapsed_s is not None else None,
        "exit_code": exit_code,
        "test_count": test_count,
        "timeout_used_s": round(timeout_used_s, 2),
        "hung_test": hung_test,
    })
    # Keep last 100 runs to avoid unbounded growth.
    stats["runs"] = stats["runs"][-100:]
    save_stats(stats)


def compute_timeout(stats: dict) -> tuple[float, str]:
    """Return (timeout_seconds, description)."""
    # Any run that completed (didn't hang) counts -- test failures are
    # normal and still give a valid runtime baseline.
    completed = [r["elapsed_s"] for r in stats["runs"]
                 if r.get("elapsed_s") is not None]
    if len(completed) < MIN_RUNS_FOR_DYNAMIC:
        remaining = MIN_RUNS_FOR_DYNAMIC - len(completed)
        return DEFAULT_TIMEOUT, f"default ({remaining} more run(s) until adaptive)"
    mean = statistics.mean(completed)
    stddev = statistics.stdev(completed)
    dynamic = mean + SIGMA_MULTIPLIER * stddev
    timeout = max(dynamic, MIN_DYNAMIC_TIMEOUT)
    return timeout, f"adaptive (mean={mean:.1f}s, stddev={stddev:.1f}s, 3\u03c3={timeout:.1f}s)"

# ── Test binary discovery ────────────────────────────────────────────────

def find_test_binary() -> pathlib.Path | None:
    """Find the most recently compiled test binary in .zig-cache."""
    cache = pathlib.Path(".zig-cache/o")
    if not cache.exists():
        return None
    candidates = []
    for p in cache.iterdir():
        binary = p / "test"
        if binary.is_file() and os.access(binary, os.X_OK):
            try:
                candidates.append((binary.stat().st_mtime, binary.stat().st_size, binary))
            except OSError:
                continue
    if not candidates:
        return None
    # Most recent, then largest (full test binary is ~86MB).
    candidates.sort(key=lambda t: (t[0], t[1]), reverse=True)
    return candidates[0][2]

# ── Signal escalation ────────────────────────────────────────────────────

def escalate(proc: subprocess.Popen) -> None:
    """Escalate kill signals: SIGINT -> SIGTERM -> SIGKILL."""
    pgid = None
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        pass

    def kill(sig: signal.Signals, label: str) -> bool:
        warn(f"sending {label} to process group")
        try:
            if pgid is not None:
                os.killpg(pgid, sig)
            else:
                proc.send_signal(sig)
        except OSError:
            pass
        try:
            proc.wait(timeout=ESCALATION_PAUSE)
            return True
        except subprocess.TimeoutExpired:
            return False

    if kill(signal.SIGINT, "SIGINT"):
        return
    if kill(signal.SIGTERM, "SIGTERM"):
        return
    kill(signal.SIGKILL, "SIGKILL")
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass

# ── Parse test count from zig build test output ──────────────────────────

_SUMMARY_RE = re.compile(r"(\d+)/(\d+)\s+(tests?\s+)?passed")

def parse_test_count(output: str) -> int | None:
    m = _SUMMARY_RE.search(output)
    return int(m.group(2)) if m else None

# ── Primary run (wrapped mode) ───────────────────────────────────────────

def run_wrapped(extra_args: list[str], timeout: float) -> tuple[int | None, float, str]:
    """Run ``zig build test`` with a whole-suite timeout.

    Returns (exit_code_or_None, elapsed_seconds, captured_output).
    None exit_code means timeout (hang detected).
    """
    cmd = ["zig", "build", "test"] + extra_args
    warn(f"running: {' '.join(cmd)}")
    warn(f"timeout: {timeout:.1f}s")

    start = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
        elapsed = time.monotonic() - start
        output = out.decode("utf-8", errors="replace")
        sys.stdout.write(output)
        sys.stdout.flush()
        return proc.returncode, elapsed, output
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - start
        warn(f"suite exceeded {timeout:.1f}s after {elapsed:.1f}s, likely hung")
        escalate(proc)
        # Drain any partial output.
        try:
            out, _ = proc.communicate(timeout=2)
            output = out.decode("utf-8", errors="replace")
            sys.stdout.write(output)
            sys.stdout.flush()
        except Exception:
            output = ""
        return None, elapsed, output

# ── Diagnostic run (direct mode) ─────────────────────────────────────────

_TEST_LINE_RE = re.compile(r"(\d+)/(\d+)\s+(.+)\.\.\.(OK|SKIP|FAIL.*)")

def run_diagnostic(binary: pathlib.Path, per_test_timeout: float = DIAG_PER_TEST_TIMEOUT) -> str | None:
    """Run the test binary directly, monitoring per-test output.

    Returns the name of the hanging test, or None if no hang detected.
    """
    warn(f"starting diagnostic re-run: {binary}")
    warn(f"per-test inactivity timeout: {per_test_timeout}s")

    proc = subprocess.Popen(
        [str(binary)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )

    last_test = "(none)"
    current_index = 0
    total = "?"

    try:
        while True:
            ready, _, _ = select.select([proc.stderr], [], [], per_test_timeout)
            if not ready:
                # No output for per_test_timeout seconds -- hung.
                next_index = current_index + 1
                warn(f"test {next_index}/{total} hung after {per_test_timeout}s inactivity")
                warn(f"last completed: {last_test}")
                escalate(proc)
                return last_test

            line = proc.stderr.readline()
            if not line:
                break  # Process ended.

            text = line.decode("utf-8", errors="replace").strip()
            m = _TEST_LINE_RE.match(text)
            if m:
                current_index = int(m.group(1))
                total = m.group(2)
                last_test = m.group(3)
    except Exception as e:
        warn(f"diagnostic error: {e}")
    finally:
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            escalate(proc)

    warn("diagnostic run completed without detecting a hang")
    return None

# ── Main ─────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Test watchdog for zmux unit tests.",
        epilog="Extra arguments after -- are forwarded to zig build test.",
    )
    parser.add_argument(
        "--timeout", type=float, default=None,
        help="Override timeout in seconds (default: adaptive or 120s)",
    )
    parser.add_argument(
        "--no-watchdog", action="store_true",
        help="Pass through to zig build test with no timeout",
    )
    parser.add_argument(
        "--direct", action="store_true",
        help="Run test binary directly with per-test hang detection",
    )
    parser.add_argument(
        "extra", nargs="*",
        help="Extra arguments forwarded to zig build test",
    )

    args = parser.parse_args()

    # --no-watchdog: plain pass-through.
    if args.no_watchdog:
        cmd = ["zig", "build", "test"] + args.extra
        return subprocess.call(cmd)

    stats = load_stats()

    # --direct: run binary with per-test monitoring.
    if args.direct:
        binary = find_test_binary()
        if binary is None:
            warn("no test binary found in .zig-cache; run 'zig build test-compile' first")
            return 1
        timeout = args.timeout or DIAG_PER_TEST_TIMEOUT
        hung = run_diagnostic(binary, per_test_timeout=timeout)
        if hung:
            record_run(stats, None, None, timeout, hung_test=hung)
            return 124
        return 0

    # Default: wrapped mode.
    if args.timeout is not None:
        timeout = args.timeout
        timeout_desc = f"manual override"
    else:
        timeout, timeout_desc = compute_timeout(stats)

    warn(f"timeout: {timeout:.1f}s ({timeout_desc})")

    exit_code, elapsed, output = run_wrapped(args.extra, timeout)

    test_count = parse_test_count(output)

    if exit_code is None:
        # Hang detected. Try diagnostic re-run.
        warn("primary run timed out, attempting diagnostic re-run...")
        binary = find_test_binary()
        hung_test = None
        if binary:
            hung_test = run_diagnostic(binary)
        else:
            warn("no test binary found for diagnostic re-run")
        record_run(stats, None, None, timeout, hung_test=hung_test, test_count=test_count)
        return 124

    # Normal completion (pass or fail).
    warn(f"completed in {elapsed:.1f}s (exit code {exit_code})")
    record_run(stats, elapsed, exit_code, timeout, test_count=test_count)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

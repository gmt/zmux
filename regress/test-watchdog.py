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
import shutil
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

# ── Coredump collection ──────────────────────────────────────────────────

def _have_coredumpctl() -> bool:
    return shutil.which("coredumpctl") is not None


def _find_coredump_pids(since: float, exe_hint: str | None = None) -> list[str]:
    """Return PIDs of coredumps since *since* matching *exe_hint*."""
    since_dt = datetime.datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S")
    try:
        result = subprocess.run(
            ["coredumpctl", "list", "--since", since_dt, "--no-pager"],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []

    pids: list[str] = []
    for line in result.stdout.splitlines():
        if exe_hint and exe_hint not in line:
            continue
        for part in line.split():
            if part.isdigit() and len(part) >= 4:
                pids.append(part)
                break
    return pids


def _gdb_backtrace(pid: str) -> list[str] | None:
    """Get a debuginfod-enriched backtrace via gdb, if available.

    Uses ``gdb -batch -iex 'set debuginfod enabled on'`` to pull
    debug symbols from configured debuginfod servers (e.g.,
    debuginfod.archlinux.org) before unwinding.  This resolves
    system library frames to source file and line number.
    """
    if not shutil.which("gdb"):
        return None
    # Dump the core to a temp file so gdb can load it with the binary.
    with tempfile.NamedTemporaryFile(suffix=".core", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        dump = subprocess.run(
            ["coredumpctl", "dump", pid, "-o", tmp_path, "--no-pager"],
            capture_output=True, timeout=15,
        )
        if dump.returncode != 0:
            return None
        # Find the executable path from coredumpctl info.
        info = subprocess.run(
            ["coredumpctl", "info", pid, "--no-pager"],
            capture_output=True, text=True, timeout=5,
        )
        exe = None
        for line in info.stdout.splitlines():
            if line.strip().startswith("Executable:"):
                exe = line.split(":", 1)[1].strip()
                break
        if not exe:
            return None
        result = subprocess.run(
            ["gdb", "-batch",
             "-iex", "set debuginfod enabled on",
             "-ex", "bt",
             exe, tmp_path],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "DEBUGINFOD_URLS":
                 os.environ.get("DEBUGINFOD_URLS", "")},
        )
        bt = [l for l in result.stdout.splitlines() if l.startswith("#")]
        return bt if bt else None
    except (subprocess.TimeoutExpired, OSError):
        return None
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _coredumpctl_backtrace(pid: str) -> tuple[str, list[str]]:
    """Fallback: extract signal and backtrace from coredumpctl info."""
    try:
        info = subprocess.run(
            ["coredumpctl", "info", pid, "--no-pager"],
            capture_output=True, text=True, timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError):
        return "", []
    if info.returncode != 0:
        return "", []

    sig = ""
    bt_lines: list[str] = []
    in_bt = False
    for line in info.stdout.splitlines():
        line_s = line.strip()
        if line_s.startswith("Signal:"):
            sig = line_s.split(":", 1)[1].strip()
        if "Stack trace" in line_s:
            in_bt = True
            continue
        if in_bt:
            if line_s.startswith("#"):
                bt_lines.append(line_s)
            elif bt_lines:
                break
    return sig, bt_lines


def collect_coredumps(since: float, exe_hint: str | None = None) -> list[dict]:
    """Query coredumpctl for crashes since *since* (UNIX timestamp).

    When gdb and debuginfod are available, produces enriched backtraces
    with system library source locations.  Falls back to coredumpctl's
    own traces otherwise.

    Returns a list of dicts with keys: pid, signal, backtrace.
    """
    if not _have_coredumpctl():
        return []

    pids = _find_coredump_pids(since, exe_hint)
    dumps: list[dict] = []
    for pid in pids[-3:]:  # At most 3 most recent.
        # Try gdb+debuginfod first for richer traces.
        gdb_bt = _gdb_backtrace(pid)
        if gdb_bt is not None:
            # Still need the signal from coredumpctl info.
            sig, _ = _coredumpctl_backtrace(pid)
            dumps.append({"pid": pid, "signal": sig, "backtrace": gdb_bt})
        else:
            sig, bt = _coredumpctl_backtrace(pid)
            if bt:
                dumps.append({"pid": pid, "signal": sig, "backtrace": bt})

    return dumps


def report_coredumps(since: float) -> None:
    """Print any coredumps from the test run to stderr."""
    dumps = collect_coredumps(since, exe_hint="test")
    if not dumps:
        return
    warn(f"found {len(dumps)} coredump(s) from this run:")
    for dump in dumps:
        warn(f"  PID {dump['pid']} ({dump['signal']})")
        for frame in dump["backtrace"][:10]:
            warn(f"    {frame}")
        if len(dump["backtrace"]) > 10:
            warn(f"    ... ({len(dump['backtrace']) - 10} more frames)")


# ── Parse test count from zig build test output ──────────────────────────

_SUMMARY_RE = re.compile(r"(\d+)/(\d+)\s+(tests?\s+)?passed")

def parse_test_count(output: str) -> int | None:
    m = _SUMMARY_RE.search(output)
    return int(m.group(2)) if m else None


# ── Crash-resilient re-run ───────────────────────────────────────────────

PROGRESS_FILE = pathlib.Path(".zig-cache/test-progress.journal")

# Zig test runner stderr format: "N/M module.test.description...STATUS"
_PROGRESS_RE = re.compile(r"(\d+)/(\d+)\s+(.+?)\.\.\.(OK|SKIP|FAIL.*)")


def _write_progress(name: str, status: str) -> None:
    """Append a test result to the progress journal."""
    with open(PROGRESS_FILE, "a") as f:
        f.write(f"{name}={status}\n")


def _read_progress() -> dict[str, str]:
    """Read the progress journal. Returns {test_name: status}."""
    results: dict[str, str] = {}
    if not PROGRESS_FILE.exists():
        return results
    for line in PROGRESS_FILE.read_text().splitlines():
        if "=" in line:
            name, _, status = line.partition("=")
            results[name] = status
    return results


def _is_signal_death(returncode: int | None) -> bool:
    """True if the process was killed by a signal (negative returncode)."""
    return returncode is not None and returncode < 0


def _parse_crasher_from_output(output: str) -> str | None:
    """Extract the crashing test name from zig test runner output."""
    # Pattern: "while executing test 'module.test.desc'"
    m = re.search(r"while executing test '([^']+)'", output)
    return m.group(1) if m else None


def run_crash_resilient(binary: pathlib.Path, per_test_timeout: float) -> tuple[dict, list[str]]:
    """Run the test binary with crash isolation.

    Uses a progress journal to survive signal deaths.  On crash,
    restarts and runs un-reached tests individually via --test-filter
    to avoid re-hitting the same crasher.

    Returns (results_dict, crashers_list) where results_dict maps
    test names to "OK"/"SKIP"/"FAIL ..."/"CRASH" and crashers_list
    is the list of tests that caused signal deaths.
    """
    # Clean slate.
    if PROGRESS_FILE.exists():
        PROGRESS_FILE.unlink()

    crashers: list[str] = []
    total_tests = 0

    # Phase 1: run the full binary, journalling progress.
    warn("crash-resilient: phase 1 — full run with progress journal")
    phase1_results, phase1_crasher, phase1_total = _run_with_journal(binary, per_test_timeout)
    if phase1_total:
        total_tests = phase1_total
    if phase1_crasher:
        crashers.append(phase1_crasher)

    # If no crash, we're done.
    if not phase1_crasher:
        return _read_progress(), crashers

    # Phase 2: run un-reached tests individually, skipping known crashers.
    warn("crash-resilient: phase 2 — running un-reached tests individually")
    seen = _read_progress()
    unreached_count = total_tests - len(seen) if total_tests else 0
    warn(f"  {len(seen)} tests journalled, {len(crashers)} crashed, ~{unreached_count} un-reached")

    # We need test names for the un-reached tests.  Run the binary again;
    # it will re-run tests we've already seen (fast), then crash on the
    # crasher again, but this time we look at what comes after in the
    # test ordering.  We keep restarting until we've discovered all tests.
    max_restarts = 20  # safety limit
    for attempt in range(max_restarts):
        already_seen = _read_progress()
        if total_tests and len(already_seen) >= total_tests:
            break  # All tests accounted for.

        # Run tests we haven't seen yet by name, one at a time.
        # First we need to discover remaining test names.
        new_names = _discover_remaining_tests(binary, already_seen, crashers, per_test_timeout)
        if not new_names:
            break  # No more tests to discover.

        for test_name in new_names:
            if test_name in already_seen or test_name in crashers:
                continue
            rc, output = _run_single_test(binary, test_name, per_test_timeout)
            if _is_signal_death(rc):
                warn(f"  CRASH: {test_name}")
                _write_progress(test_name, "CRASH")
                crashers.append(test_name)
            # Individual test results are parsed from the output and
            # journalled by _run_single_test via _run_with_journal.

    final = _read_progress()
    return final, crashers


def _run_with_journal(
    binary: pathlib.Path,
    per_test_timeout: float,
    test_filter: str | None = None,
) -> tuple[dict[str, str], str | None, int | None]:
    """Run test binary, writing results to the progress journal.

    Returns (results, crasher_name_or_None, total_test_count_or_None).
    """
    cmd = [str(binary)]
    if test_filter:
        cmd += ["--test-filter", test_filter]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )

    results: dict[str, str] = {}
    last_test = None
    total = None

    try:
        while True:
            ready, _, _ = select.select([proc.stderr], [], [], per_test_timeout)
            if not ready:
                # Timeout — treat as hang, not crash.
                warn(f"  inactivity timeout on: {last_test or '(unknown)'}")
                escalate(proc)
                if last_test:
                    _write_progress(last_test, "HANG")
                return results, last_test, total

            line = proc.stderr.readline()
            if not line:
                break

            text = line.decode("utf-8", errors="replace").strip()
            m = _PROGRESS_RE.match(text)
            if m:
                idx, tot, name, status = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
                total = tot
                last_test = name
                results[name] = status
                _write_progress(name, status)
    except Exception as e:
        warn(f"  journal error: {e}")
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            escalate(proc)

    rc = proc.returncode
    if _is_signal_death(rc):
        # The process died from a signal.  The last test in progress
        # is the crasher (it may or may not have been journalled).
        crasher = _parse_crasher_from_output("")  # Can't get output easily
        if not crasher and last_test and last_test not in results:
            crasher = last_test
        if crasher and crasher not in results:
            _write_progress(crasher, "CRASH")
        return results, crasher, total

    return results, None, total


def _discover_remaining_tests(
    binary: pathlib.Path,
    already_seen: dict[str, str],
    crashers: list[str],
    per_test_timeout: float,
) -> list[str]:
    """Run the binary to discover test names beyond the known set.

    The binary will re-run already-seen tests and crash on known
    crashers, but in the process we may observe new test names in
    the progress output.
    """
    cmd = [str(binary)]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )

    new_names: list[str] = []
    try:
        while True:
            ready, _, _ = select.select([proc.stderr], [], [], per_test_timeout)
            if not ready:
                escalate(proc)
                break

            line = proc.stderr.readline()
            if not line:
                break

            text = line.decode("utf-8", errors="replace").strip()
            m = _PROGRESS_RE.match(text)
            if m:
                name = m.group(3)
                if name not in already_seen and name not in crashers:
                    new_names.append(name)
    except Exception:
        pass
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            escalate(proc)

    return new_names


def _run_single_test(
    binary: pathlib.Path,
    test_name: str,
    timeout: float,
) -> tuple[int | None, str]:
    """Run a single test by name. Returns (returncode, output)."""
    cmd = [str(binary), "--test-filter", test_name]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout * 3,  # generous timeout for single test
            start_new_session=True,
        )
        output = result.stderr.decode("utf-8", errors="replace")
        # Parse and journal the result.
        for line in output.splitlines():
            m = _PROGRESS_RE.match(line.strip())
            if m:
                name, status = m.group(3), m.group(4)
                _write_progress(name, status)
        return result.returncode, output
    except subprocess.TimeoutExpired:
        _write_progress(test_name, "HANG")
        return None, ""


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

    run_start = time.time()
    exit_code, elapsed, output = run_wrapped(args.extra, timeout)

    test_count = parse_test_count(output)

    if exit_code is None:
        # Hang detected. Try diagnostic re-run.
        report_coredumps(run_start)
        warn("primary run timed out, attempting diagnostic re-run...")
        binary = find_test_binary()
        hung_test = None
        if binary:
            hung_test = run_diagnostic(binary)
        else:
            warn("no test binary found for diagnostic re-run")
        record_run(stats, None, None, timeout, hung_test=hung_test, test_count=test_count)
        return 124

    if _is_signal_death(exit_code):
        # Process killed by signal (e.g. SIGABRT from a crashing test).
        # The test runner is a single process — one crash kills the whole
        # suite.  Switch to crash-resilient mode: re-run with a progress
        # journal, isolating crashers and running un-reached tests
        # individually.
        sig = -exit_code
        crasher = _parse_crasher_from_output(output)
        report_coredumps(run_start)
        warn(f"primary run killed by signal {sig} after {elapsed:.1f}s")
        if crasher:
            warn(f"crashing test: {crasher}")
        else:
            warn("could not identify crashing test from output")

        binary = find_test_binary()
        if binary:
            warn("switching to crash-resilient mode (progress journal + per-test isolation)")
            per_test = args.timeout or DIAG_PER_TEST_TIMEOUT
            results, crashers = run_crash_resilient(binary, per_test)
            passed = sum(1 for v in results.values() if v == "OK")
            failed = sum(1 for v in results.values() if v.startswith("FAIL"))
            skipped = sum(1 for v in results.values() if v == "SKIP")
            crashed = len(crashers)
            total = len(results)
            warn(f"crash-resilient results: {passed} passed, {failed} failed, "
                 f"{skipped} skipped, {crashed} crashed out of {total} reached")
            if crashers:
                warn(f"crashers: {', '.join(crashers)}")
            record_run(stats, elapsed, exit_code, timeout, test_count=test_count)
            # Return 0 only if everything passed (no fails, no crashes).
            return 0 if (failed == 0 and crashed == 0) else 1
        else:
            warn("no test binary found for crash-resilient re-run")
            record_run(stats, elapsed, exit_code, timeout, test_count=test_count)
            return exit_code

    # Normal completion (pass or fail).
    report_coredumps(run_start)
    warn(f"completed in {elapsed:.1f}s (exit code {exit_code})")
    record_run(stats, elapsed, exit_code, timeout, test_count=test_count)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

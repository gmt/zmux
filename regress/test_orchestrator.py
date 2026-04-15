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
import csv
import json
import os
import pathlib
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import queue
from dataclasses import dataclass, field
from typing import Callable, cast

import artifact_root
import host_caps
import smoke_owner


ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
REGRESS_DIR = ROOT_DIR / "regress"
MATRIX_PATH = REGRESS_DIR / "oracle-command-matrix.tsv"
TIMEOUTS_PATH = REGRESS_DIR / "test_timeouts.json"
SMOKE_HARNESS = REGRESS_DIR / "smoke_harness.py"
RECURSIVE_HARNESS = REGRESS_DIR / "recursive_attach_harness.py"
MUSEUM_BUILD = ROOT_DIR / "tmux-museum" / "out" / "gdb" / "tmux"
MUSEUM_REFRESH = ROOT_DIR / "tmux-museum" / "bin" / "refresh-museum.sh"
DEFAULT_ZMUX = ROOT_DIR / "zig-out" / "bin" / "zmux"
DEFAULT_HELPER = ROOT_DIR / "zig-out" / "bin" / "hello-shell-ansi"
DEFAULT_INPUT_FUZZER = ROOT_DIR / "zig-out" / "bin" / "zmux-input-fuzzer"
DEFAULT_CMD_PREPROCESS_FUZZER = (
    ROOT_DIR / "zig-out" / "bin" / "zmux-cmd-preprocess-fuzzer"
)
MUX_NAMES = {"tmux", "zmux"}
FUZZ_MODES = ("auto", "require", "off")
SUMMARY_FORMATS = ("default", "none")
FAILURE_SUMMARY_LIMIT = 8
FAST_SMOKE_SHELLS = (
    "new-session-no-client.sh",
    "has-session-return.sh",
    "new-session-size.sh",
    "kill-session-process-exit.sh",
    "shell-exit-cleanup.sh",
    "shell-size-sentinel.sh",
    "control-client-size.sh",
    "control-notify-smoke.sh",
    "alerts-smoke.sh",
    "session-group-resize.sh",
    "second-socket-attach.sh",
    "semicolon-chaining.sh",
    "command-order.sh",
    "attach-detach-client.sh",
    "startup-status-width.sh",
    "compat-argv0-config.sh",
    "list-and-display.sh",
    "formatter-smoke.sh",
    "kill-server-cleanup.sh",
    "sixel-roundtrip.sh",
    "ohmytmux-smoke.sh",
    "tmux-program-bootstrap.sh",
)
RECURSIVE_CASES = (
    "tmux-in-zmux",
    "zmux-in-tmux",
    "tmux-in-tmux",
    "zmux-in-zmux",
)


def normalize_fuzz_mode(raw: str | None) -> str:
    value = (raw or "auto").strip().lower()
    if value not in FUZZ_MODES:
        valid = ", ".join(FUZZ_MODES)
        raise HarnessError(f"invalid fuzz mode {value!r}; expected one of {valid}")
    return value


def summarize_results(results: list["CaseResult"], workers: int = 1) -> str:
    counts: dict[str, int] = {}
    for result in results:
        counts[result.status] = counts.get(result.status, 0) + 1
    cleanup_failures = sum(1 for result in results if result.cleanup_failed)
    parts = [f"TOTAL={len(results)}"]
    parts.extend(f"{key}={counts[key]}" for key in sorted(counts))
    parts.append(f"CLEANUP={cleanup_failures}")

    failing = [
        result
        for result in results
        if result.status not in {"PASS", "SKIP"} or result.cleanup_failed
    ]
    if not failing:
        parts.append("ISSUES=none")
        mode = f"parallel({workers})" if workers > 1 else f"serial({workers})"
        parts.append(f"MODE={mode}")
        return "summary: " + " | ".join(parts)

    issue_items = [f"{result.case.case_id}({result.status})" for result in failing]
    if len(issue_items) > FAILURE_SUMMARY_LIMIT:
        visible = ", ".join(issue_items[:FAILURE_SUMMARY_LIMIT])
        issues = f"{visible}, +{len(issue_items) - FAILURE_SUMMARY_LIMIT} more"
    else:
        issues = ", ".join(issue_items)
    parts.append(f"ISSUES={issues}")
    mode = f"parallel({workers})" if workers > 1 else f"serial({workers})"
    parts.append(f"MODE={mode}")
    return "summary: " + " | ".join(parts)


def print_kept_sandboxes(results: list["CaseResult"]) -> None:
    for result in results:
        if result.status in {"PASS", "SKIP"} and not result.cleanup_failed:
            continue
        if result.sandbox is not None:
            print(f"  kept {result.case.case_id}: {result.sandbox}")


class HarnessError(RuntimeError):
    pass


@dataclass(frozen=True)
class Case:
    case_id: str
    label: str
    family: str
    argv: list[str]
    env_overrides: dict[str, str] = field(default_factory=dict)
    stdin_path: str | None = None
    required_capabilities: frozenset[str] = field(default_factory=frozenset)


@dataclass
class CaseResult:
    case: Case
    status: str
    elapsed_s: float
    detail: str = ""
    cleanup_failed: bool = False
    sandbox: pathlib.Path | None = None


def case_to_json(case: Case) -> dict[str, object]:
    return {
        "case_id": case.case_id,
        "label": case.label,
        "family": case.family,
        "argv": list(case.argv),
        "env_overrides": dict(case.env_overrides),
        "stdin_path": case.stdin_path,
        "required_capabilities": sorted(case.required_capabilities),
    }


def case_from_json(payload: dict[str, object]) -> Case:
    return Case(
        case_id=cast(str, payload["case_id"]),
        label=cast(str, payload["label"]),
        family=cast(str, payload["family"]),
        argv=list(cast(list[str], payload["argv"])),
        env_overrides=dict(cast(dict[str, str], payload.get("env_overrides", {}))),
        stdin_path=cast(str | None, payload.get("stdin_path")),
        required_capabilities=frozenset(
            cast(list[str], payload.get("required_capabilities", []))
        ),
    )


def case_result_to_json(
    result: CaseResult, *, case_order: int | None = None
) -> dict[str, object]:
    payload: dict[str, object] = {
        "case": case_to_json(result.case),
        "status": result.status,
        "elapsed_s": result.elapsed_s,
        "detail": result.detail,
        "cleanup_failed": result.cleanup_failed,
        "sandbox": str(result.sandbox) if result.sandbox is not None else None,
    }
    if case_order is not None:
        payload["case_order"] = case_order
    return payload


def case_result_from_json(payload: dict[str, object]) -> CaseResult:
    sandbox_raw = cast(str | None, payload.get("sandbox"))
    elapsed_raw = cast(float | int | str, payload["elapsed_s"])
    return CaseResult(
        case=case_from_json(cast(dict[str, object], payload["case"])),
        status=cast(str, payload["status"]),
        elapsed_s=float(elapsed_raw),
        detail=cast(str, payload.get("detail", "")),
        cleanup_failed=bool(payload.get("cleanup_failed", False)),
        sandbox=pathlib.Path(sandbox_raw) if sandbox_raw is not None else None,
    )


class TimeoutPolicy:
    def __init__(
        self,
        path: pathlib.Path,
        multiplier: float,
        override_seconds: float | None,
        *,
        allow_default_timeouts: bool,
    ) -> None:
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.defaults = {
            str(key): float(value) for key, value in payload["defaults"].items()
        }
        self.case_timeouts = {
            str(key): float(value) for key, value in payload.get("cases", {}).items()
        }
        self.multiplier = multiplier
        self.override_seconds = override_seconds
        self.allow_default_timeouts = allow_default_timeouts

    def lookup_case(self, case: Case) -> tuple[float | None, str]:
        if self.override_seconds is not None:
            return self.override_seconds, "override"
        if case.case_id in self.case_timeouts:
            base = self.case_timeouts[case.case_id]
            return max(1.0, base * self.multiplier), "case"
        if self.allow_default_timeouts:
            base = self.defaults.get(case.family)
            if base is None:
                raise HarnessError(f"no timeout default for family {case.family}")
            return max(1.0, base * self.multiplier), "default"
        return None, "missing"

    def for_case(self, case: Case) -> float:
        timeout_s, source = self.lookup_case(case)
        if timeout_s is None:
            raise HarnessError(
                f"missing explicit timeout for {case.case_id}; rerun with --allow-default-timeouts only while calibrating"
            )
        _ = source
        return timeout_s

    def missing_cases(self, cases: list[Case]) -> list[str]:
        missing: list[str] = []
        for case in cases:
            timeout_s, _ = self.lookup_case(case)
            if timeout_s is None:
                missing.append(case.case_id)
        return missing


def load_matrix_commands() -> list[str]:
    commands: list[str] = []
    with MATRIX_PATH.open("r", encoding="utf-8") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if not row or row[0].startswith("#"):
                continue
            commands.append(row[0])
    return commands


def discover_zig_tests(binary: pathlib.Path) -> list[dict[str, object]]:
    proc = subprocess.run(
        [str(binary), "--list-tests"],
        capture_output=True,
        text=True,
        cwd=ROOT_DIR,
        timeout=15.0,
        env=os.environ.copy(),
    )
    if proc.returncode != 0:
        raise HarnessError(f"unable to list tests from {binary}:\n{proc.stderr}")
    payload: list[dict[str, object]] = []
    for raw_line in proc.stdout.splitlines():
        if not raw_line.strip():
            continue
        try:
            index_text, name = raw_line.split("\t", 1)
        except ValueError as exc:
            raise HarnessError(
                f"bad --list-tests line from {binary}: {raw_line!r}"
            ) from exc
        payload.append(
            {
                "index": int(index_text),
                "name": name,
            }
        )
    return payload


def matches_filters(name: str, filters: list[str]) -> bool:
    if not filters:
        return True
    return any(filter_text in name for filter_text in filters)


def ensure_executable(path: pathlib.Path, label: str) -> pathlib.Path:
    if path.is_file() and os.access(path, os.X_OK):
        return path
    raise HarnessError(f"{label} not found or not executable: {path}")


def ensure_museum_tmux() -> pathlib.Path:
    if MUSEUM_BUILD.is_file() and os.access(MUSEUM_BUILD, os.X_OK):
        return MUSEUM_BUILD
    proc = subprocess.run(
        ["bash", str(MUSEUM_REFRESH), "gdb"],
        capture_output=True,
        text=True,
        cwd=ROOT_DIR,
        timeout=1800.0,
    )
    if proc.returncode != 0:
        raise HarnessError(
            f"unable to build museum tmux:\n{proc.stdout}\n{proc.stderr}"
        )
    return ensure_executable(MUSEUM_BUILD, "museum tmux")


def resolve_oracle_tmux(explicit: str | None) -> pathlib.Path:
    if explicit:
        path = pathlib.Path(explicit)
        if path.is_file() and os.access(path, os.X_OK):
            return path
    system_tmux_path = pathlib.Path("/usr/bin/tmux")
    if system_tmux_path.is_file() and os.access(system_tmux_path, os.X_OK):
        return system_tmux_path
    system_tmux = shutil.which("tmux")
    if system_tmux is not None:
        return pathlib.Path(system_tmux)
    return ensure_museum_tmux()


def make_sandbox(root_dir: pathlib.Path) -> pathlib.Path:
    root = root_dir / f"zmux_test_{secrets.token_hex(6)}"
    root.mkdir(parents=True, exist_ok=False)
    return root


def snapshot_mux_processes() -> dict[tuple[int, int], str]:
    snapshot: dict[tuple[int, int], str] = {}
    proc_root = pathlib.Path("/proc")
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        start_time = smoke_owner.read_proc_start_time(pid)
        if start_time is None:
            continue
        exe_name = smoke_owner.read_proc_exe_name(pid)
        if exe_name in MUX_NAMES:
            snapshot[(pid, start_time)] = exe_name
    return snapshot


def cleanup_new_mux_processes(before: dict[tuple[int, int], str]) -> list[str]:
    survivors: list[tuple[int, int]] = []
    for proc_key in snapshot_mux_processes():
        if proc_key in before:
            continue
        survivors.append(proc_key)
    if not survivors:
        return []

    for pid, _ in survivors:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.2)
    for pid, _ in survivors:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    time.sleep(0.2)

    leftovers: list[str] = []
    current = snapshot_mux_processes()
    for pid, start_time in survivors:
        exe_name = current.get((pid, start_time))
        if exe_name is not None:
            leftovers.append(f"{exe_name}:{pid}")
    return leftovers


def prepare_sandbox_tools(
    sandbox: pathlib.Path,
    *,
    zmux_binary: pathlib.Path,
    oracle_tmux: pathlib.Path,
    helper_binary: pathlib.Path | None,
) -> None:
    bin_dir = sandbox / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (sandbox / "home").mkdir(parents=True, exist_ok=True)
    (sandbox / "tmp").mkdir(parents=True, exist_ok=True)
    (sandbox / "xdg" / "config").mkdir(parents=True, exist_ok=True)
    (sandbox / "xdg" / "cache").mkdir(parents=True, exist_ok=True)
    (sandbox / "xdg" / "data").mkdir(parents=True, exist_ok=True)
    (sandbox / "xdg" / "runtime").mkdir(parents=True, exist_ok=True)
    (sandbox / "owned-pids").mkdir(parents=True, exist_ok=True)
    (sandbox / "logs").mkdir(parents=True, exist_ok=True)

    for name, target in (
        ("zmux", zmux_binary),
        ("tmux", oracle_tmux),
        ("hello-shell-ansi", helper_binary),
    ):
        if target is None:
            continue
        link_path = bin_dir / name
        if link_path.exists() or link_path.is_symlink():
            link_path.unlink()
        link_path.symlink_to(target)


def build_case_env(
    sandbox: pathlib.Path,
    *,
    zmux_binary: pathlib.Path,
    oracle_tmux: pathlib.Path,
    helper_binary: pathlib.Path | None,
    extra_env: dict[str, str],
    af_unix_mode: str,
) -> dict[str, str]:
    home_dir = sandbox / "home"
    tmp_dir = sandbox / "tmp"
    xdg_dir = sandbox / "xdg"
    base_path = os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin")
    env = {
        "PATH": f"{sandbox / 'bin'}:{base_path}",
        "HOME": str(home_dir),
        "TMPDIR": str(tmp_dir),
        "TERM": os.environ.get("TERM", "screen"),
        "COLORTERM": os.environ.get("COLORTERM", "truecolor"),
        "LANG": os.environ.get("LANG", "C"),
        "LC_ALL": os.environ.get("LC_ALL", "C"),
        "TZ": os.environ.get("TZ", "UTC"),
        "USER": "smoke",
        "LOGNAME": "smoke",
        "XDG_CONFIG_HOME": str(xdg_dir / "config"),
        "XDG_CACHE_HOME": str(xdg_dir / "cache"),
        "XDG_DATA_HOME": str(xdg_dir / "data"),
        "XDG_RUNTIME_DIR": str(xdg_dir / "runtime"),
        "TMUX_TMPDIR": str(tmp_dir),
        "ZMUX_TMPDIR": str(tmp_dir),
        "TEST_ZMUX": str(zmux_binary),
        "TEST_ORACLE_TMUX": str(oracle_tmux),
        "SMOKE_ARTIFACT_ROOT": str(sandbox),
        "SMOKE_RUN_ROOT": str(sandbox),
        "SMOKE_OWNER_DIR": str(sandbox / "owned-pids"),
        "SMOKE_KEEP_RUN_ROOT": "1",
        "SMOKE_CONTAINMENT_ACTIVE": "1",
        "SMOKE_AF_UNIX": af_unix_mode,
    }
    if helper_binary is not None:
        env["TEST_ZMUX_HELPER"] = str(helper_binary)
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT"):
        if key in os.environ:
            env[key] = os.environ[key]
    env.update(extra_env)
    return env


def namespace_probe() -> tuple[bool, str | None]:
    unshare = shutil.which("unshare")
    if unshare is None:
        return False, "unshare not found"
    try:
        proc = subprocess.run(
            [
                unshare,
                "--user",
                "--map-current-user",
                "--pid",
                "--mount-proc",
                "--fork",
                "--kill-child",
                "--forward-signals",
                "/bin/sh",
                "-c",
                "exit 0",
            ],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, None
    detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
    return False, detail


def stop_process(proc: subprocess.Popen[bytes], namespaced: bool) -> None:
    if proc.poll() is not None:
        return
    try:
        if namespaced:
            os.kill(proc.pid, signal.SIGTERM)
        else:
            os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        if namespaced:
            os.kill(proc.pid, signal.SIGKILL)
        else:
            os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


def classify_case_exit(
    case: Case,
    returncode: int,
    stdout_path: pathlib.Path,
    stderr_path: pathlib.Path,
) -> tuple[str, str]:
    if returncode == 77:
        return "SKIP", ""
    if returncode < 0:
        return "ERROR", f"(signal {-returncode})"
    if case.family.startswith("zig-"):
        stdout_text = stdout_path.read_text(encoding="utf-8", errors="replace")
        payload: dict[str, str] = {}
        for raw_line in stdout_text.splitlines():
            if "=" not in raw_line:
                continue
            key, value = raw_line.split("=", 1)
            payload[key] = value
        if "status" not in payload:
            stderr_text = stderr_path.read_text(
                encoding="utf-8", errors="replace"
            ).strip()
            return "ERROR", f"(bad result) {stderr_text[:160]}".strip()
        status = payload["status"].upper()
        detail = ""
        if payload.get("leak") == "1":
            detail = "leak"
        elif payload.get("log_err_count") not in {None, "0"}:
            detail = f"log_err_count={payload['log_err_count']}"
        if status == "PASS":
            return "PASS", detail
        if status == "SKIP":
            return "SKIP", detail
        return "FAIL", detail
    return ("PASS", "") if returncode == 0 else ("FAIL", f"(exit {returncode})")


class SignalCoordinator:
    def __init__(self) -> None:
        self._shutdown = threading.Event()
        self._lock = threading.Lock()
        self._active: dict[int, tuple[subprocess.Popen[bytes], bool]] = {}
        self.interrupted_by: int | None = None
        self._install()

    def _install(self) -> None:
        def handle(signum: int, _frame: object) -> None:
            self.interrupted_by = signum
            self._shutdown.set()
            for proc, namespaced in list(self._active.values()):
                stop_process(proc, namespaced)

        for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            signal.signal(sig, handle)

    def register(self, proc: subprocess.Popen[bytes], namespaced: bool) -> None:
        with self._lock:
            self._active[proc.pid] = (proc, namespaced)

    def unregister(self, proc: subprocess.Popen[bytes]) -> None:
        with self._lock:
            self._active.pop(proc.pid, None)

    @property
    def shutdown_requested(self) -> bool:
        return self._shutdown.is_set()


class CaseWorker:
    def __init__(
        self,
        *,
        sandbox_root: pathlib.Path,
        zmux_binary: pathlib.Path,
        oracle_tmux: pathlib.Path,
        helper_binary: pathlib.Path | None,
        af_unix_mode: str,
        use_namespaces: bool,
        register_active: Callable[[subprocess.Popen[bytes], bool], None],
        unregister_active: Callable[[subprocess.Popen[bytes]], None],
    ) -> None:
        self.sandbox_root = sandbox_root
        self.zmux_binary = zmux_binary
        self.oracle_tmux = oracle_tmux
        self.helper_binary = helper_binary
        self.af_unix_mode = af_unix_mode
        self.use_namespaces = use_namespaces
        self.register_active = register_active
        self.unregister_active = unregister_active
        self.active_proc: subprocess.Popen[bytes] | None = None
        self.namespaced = False

    def run(self, case: Case, timeout_s: float) -> CaseResult:
        sandbox = make_sandbox(self.sandbox_root)
        prepare_sandbox_tools(
            sandbox,
            zmux_binary=self.zmux_binary,
            oracle_tmux=self.oracle_tmux,
            helper_binary=self.helper_binary,
        )
        env = build_case_env(
            sandbox,
            zmux_binary=self.zmux_binary,
            oracle_tmux=self.oracle_tmux,
            helper_binary=self.helper_binary,
            extra_env=case.env_overrides,
            af_unix_mode=self.af_unix_mode,
        )
        stdout_path = sandbox / "logs" / "stdout.log"
        stderr_path = sandbox / "logs" / "stderr.log"
        started = time.monotonic()
        status = "ERROR"
        detail = ""

        base_argv = list(case.argv)
        self.namespaced = self.use_namespaces
        before_mux = snapshot_mux_processes() if not self.namespaced else {}
        if self.namespaced:
            base_argv = [
                shutil.which("unshare") or "unshare",
                "--user",
                "--map-current-user",
                "--pid",
                "--mount-proc",
                "--fork",
                "--kill-child",
                "--forward-signals",
                *base_argv,
            ]

        stdin_handle = None
        try:
            with (
                stdout_path.open("wb") as stdout_handle,
                stderr_path.open("wb") as stderr_handle,
            ):
                if case.stdin_path is not None:
                    stdin_handle = open(case.stdin_path, "rb")
                proc = subprocess.Popen(
                    base_argv,
                    stdin=stdin_handle,
                    stdout=stdout_handle,
                    stderr=stderr_handle,
                    cwd=ROOT_DIR,
                    env=env,
                    start_new_session=True,
                )
                self.active_proc = proc
                self.register_active(proc, self.namespaced)
                try:
                    proc.wait(timeout=timeout_s)
                except subprocess.TimeoutExpired:
                    status = "TIMEOUT"
                    detail = f"(limit {timeout_s:.1f}s)"
                    stop_process(proc, self.namespaced)
                finally:
                    self.unregister_active(proc)
                    self.active_proc = None
                    self.namespaced = False

                if status != "TIMEOUT":
                    status, detail = classify_case_exit(
                        case, proc.returncode, stdout_path, stderr_path
                    )
        finally:
            if stdin_handle is not None:
                stdin_handle.close()

        cleanup_failed = False
        survivors: list[smoke_owner.OwnedPid] = []
        if not self.use_namespaces:
            survivors = smoke_owner.cleanup_registered(
                sandbox / "owned-pids", grace_seconds=0.2
            )
        if survivors:
            cleanup_failed = True
            detail = f"{detail} owned={','.join(str(item.pid) for item in survivors)}".strip()
        leaked_mux = (
            cleanup_new_mux_processes(before_mux) if not self.use_namespaces else []
        )
        if leaked_mux:
            cleanup_failed = True
            detail = f"{detail} mux={','.join(leaked_mux)}".strip()
        if cleanup_failed and status in {"PASS", "SKIP"}:
            status = "CLEANUP_FAIL"

        elapsed_s = time.monotonic() - started
        result = CaseResult(
            case=case,
            status=status,
            elapsed_s=elapsed_s,
            detail=detail.strip(),
            cleanup_failed=cleanup_failed,
            sandbox=sandbox,
        )
        if status == "PASS" and not cleanup_failed:
            shutil.rmtree(sandbox, ignore_errors=True)
            result.sandbox = None
        return result


class ResultCollector:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._results: list[CaseResult] = []

    def record(self, result: CaseResult) -> None:
        with self._lock:
            self._results.append(result)

    @property
    def results(self) -> list[CaseResult]:
        with self._lock:
            return list(self._results)

    def __iter__(self):
        return iter(self.results)

    def __len__(self) -> int:
        with self._lock:
            return len(self._results)


class WorkerPool:
    def __init__(
        self,
        n_workers: int,
        coordinator: SignalCoordinator,
        collector: ResultCollector,
        worker_factory: Callable[[], CaseWorker],
        print_lock: threading.Lock,
        timeout_policy: TimeoutPolicy,
    ) -> None:
        self._n = n_workers
        self._coordinator = coordinator
        self._collector = collector
        self._worker_factory = worker_factory
        self._print_lock = print_lock
        self._timeout_policy = timeout_policy
        self._queue: queue.Queue[Case | None] = queue.Queue()

    def _worker_thread(self) -> None:
        worker = self._worker_factory()
        while True:
            try:
                item = self._queue.get(timeout=0.5)
            except queue.Empty:
                if self._coordinator.shutdown_requested:
                    break
                continue
            if item is None:
                break
            if self._coordinator.shutdown_requested:
                break
            try:
                timeout_s = self._timeout_policy.for_case(item)
                result = worker.run(item, timeout_s)
            except Exception as exc:
                result = CaseResult(
                    case=item,
                    status="ERROR",
                    elapsed_s=0.0,
                    detail=f"(worker exception) {exc}",
                )
            self._collector.record(result)
            with self._print_lock:
                suffix = (
                    f" cleanup={result.cleanup_failed}" if result.cleanup_failed else ""
                )
                detail = f" {result.detail}" if result.detail else ""
                print(
                    f"{result.status:12s} {item.case_id} {result.elapsed_s:6.2f}s{suffix}{detail}"
                )

    def run(self, cases: list[Case]) -> None:
        threads = [
            threading.Thread(target=self._worker_thread, daemon=True)
            for _ in range(self._n)
        ]
        for thread in threads:
            thread.start()
        for case in cases:
            if self._coordinator.shutdown_requested:
                break
            self._queue.put(case)
        for _ in threads:
            self._queue.put(None)
        for thread in threads:
            thread.join()


class SuiteRunner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.workers: int = max(1, args.workers)
        self.timeout_policy = TimeoutPolicy(
            TIMEOUTS_PATH,
            multiplier=float(os.environ.get("ZMUX_TEST_TIMEOUT_MULTIPLIER", "1.0")),
            override_seconds=args.timeout_override,
            allow_default_timeouts=args.allow_default_timeouts,
        )
        self.zmux_binary = ensure_executable(
            pathlib.Path(args.zmux_binary or DEFAULT_ZMUX), "zmux binary"
        )
        self.oracle_tmux = resolve_oracle_tmux(args.oracle_binary)
        self.helper_binary = None
        helper_path = pathlib.Path(args.helper_binary or DEFAULT_HELPER)
        if helper_path.is_file() and os.access(helper_path, os.X_OK):
            self.helper_binary = helper_path
        self.af_unix_mode = host_caps.normalize_af_unix_mode(args.af_unix)
        self.af_unix_status = host_caps.af_unix_status(mode=self.af_unix_mode)
        if self.af_unix_mode == "require" and not self.af_unix_status.available:
            raise HarnessError(
                host_caps.capability_reason("af_unix", self.af_unix_status)
            )
        self.sandbox_root = artifact_root.default_sandbox_root()
        if not getattr(args, "skip_prune", False):
            artifact_root.prune_stale_children(self.sandbox_root)
        self.use_namespaces, self.namespace_reason = namespace_probe()
        self._collector = ResultCollector()
        self._coordinator = SignalCoordinator()
        self._summary_workers = 1

    @property
    def results(self) -> list[CaseResult]:
        return self._collector.results

    @property
    def interrupted_by(self) -> int | None:
        return self._coordinator.interrupted_by

    def stop_process(self, proc: subprocess.Popen[bytes], namespaced: bool) -> None:
        stop_process(proc, namespaced)

    def suite_cases(self) -> list[Case]:
        suite = self.args.suite
        if suite == "zig-unit":
            if self.args.zig_test_binary is None:
                raise HarnessError("zig-unit requires --zig-test-binary")
            return self.build_zig_cases(
                pathlib.Path(self.args.zig_test_binary), "zig-unit"
            )
        if suite == "zig-stress":
            if self.args.zig_test_binary is None:
                raise HarnessError("zig-stress requires --zig-test-binary")
            return self.build_zig_cases(
                pathlib.Path(self.args.zig_test_binary), "zig-stress"
            )
        if suite == "smoke-fast":
            return self.build_smoke_fast_cases()
        if suite == "smoke-oracle":
            return self.build_smoke_oracle_cases()
        if suite == "smoke-recursive":
            return self.build_recursive_cases()
        if suite == "smoke-soak":
            return self.build_soak_cases()
        if suite == "smoke-docker":
            return self.build_docker_cases()
        if suite == "smoke-most":
            return (
                self.build_smoke_fast_cases()
                + self.build_smoke_oracle_cases()
                + self.build_recursive_cases()
                + self.build_docker_cases()
            )
        if suite == "smoke-all":
            return (
                self.build_smoke_fast_cases()
                + self.build_smoke_oracle_cases()
                + self.build_recursive_cases()
                + self.build_soak_cases()
                + self.build_fuzz_cases()
                + self.build_docker_cases()
            )
        if suite == "smoke-fuzz":
            return self.build_fuzz_cases()
        raise HarnessError(f"unknown suite: {suite}")

    def build_zig_cases(self, binary: pathlib.Path, family: str) -> list[Case]:
        tests = discover_zig_tests(binary)
        cases: list[Case] = []
        filters = self.args.test_filter or []
        for item in tests:
            index = cast(int, item["index"])
            name = cast(str, item["name"])
            if not matches_filters(name, filters):
                continue
            cases.append(
                Case(
                    case_id=f"{family}:{name}",
                    label=name,
                    family=family,
                    argv=[str(binary), f"--run-test-index={index}"],
                )
            )
        return cases

    def build_smoke_fast_cases(self) -> list[Case]:
        cases: list[Case] = []
        for script_name in FAST_SMOKE_SHELLS:
            cases.append(
                Case(
                    case_id=f"smoke-shell:{pathlib.Path(script_name).stem}",
                    label=pathlib.Path(script_name).stem,
                    family="smoke-shell",
                    argv=["sh", str(REGRESS_DIR / script_name)],
                    required_capabilities=frozenset({"af_unix"}),
                )
            )
        for command in load_matrix_commands():
            cases.append(
                Case(
                    case_id=f"smoke-sweep:{command}",
                    label=command,
                    family="smoke-sweep",
                    argv=[
                        sys.executable,
                        str(SMOKE_HARNESS),
                        "run-case",
                        f"sweep:{command}",
                        "--mode",
                        "implemented",
                    ],
                    required_capabilities=frozenset({"af_unix"}),
                )
            )
        cases.append(
            Case(
                case_id="smoke-inside:inside",
                label="inside",
                family="smoke-inside",
                argv=[
                    sys.executable,
                    str(SMOKE_HARNESS),
                    "run-case",
                    "inside",
                    "--mode",
                    "implemented",
                ],
                required_capabilities=frozenset({"af_unix"}),
            )
        )
        return cases

    def build_smoke_oracle_cases(self) -> list[Case]:
        env = {
            "TEST_ZMUX": str(self.oracle_tmux),
            "TEST_ORACLE_TMUX": str(self.oracle_tmux),
        }
        cases: list[Case] = []
        for command in load_matrix_commands():
            cases.append(
                Case(
                    case_id=f"smoke-sweep-oracle:{command}",
                    label=command,
                    family="smoke-sweep",
                    argv=[
                        sys.executable,
                        str(SMOKE_HARNESS),
                        "run-case",
                        f"sweep:{command}",
                        "--mode",
                        "oracle",
                    ],
                    env_overrides=env,
                    required_capabilities=frozenset({"af_unix"}),
                )
            )
        cases.append(
            Case(
                case_id="smoke-inside-oracle:inside",
                label="inside-oracle",
                family="smoke-inside",
                argv=[
                    sys.executable,
                    str(SMOKE_HARNESS),
                    "run-case",
                    "inside",
                    "--mode",
                    "oracle",
                ],
                env_overrides=env,
                required_capabilities=frozenset({"af_unix"}),
            )
        )
        return cases

    def build_soak_cases(self) -> list[Case]:
        return [
            Case(
                case_id="smoke-soak:soak",
                label="soak",
                family="smoke-soak",
                argv=[
                    sys.executable,
                    str(SMOKE_HARNESS),
                    "run-case",
                    "soak",
                    "--mode",
                    "implemented",
                ],
                required_capabilities=frozenset({"af_unix"}),
            )
        ]

    def build_recursive_cases(self) -> list[Case]:
        return [
            Case(
                case_id=f"smoke-recursive:{name}",
                label=name,
                family="smoke-recursive",
                argv=[sys.executable, str(RECURSIVE_HARNESS), "run-case", name],
                required_capabilities=frozenset({"af_unix"}),
            )
            for name in RECURSIVE_CASES
        ]

    def build_docker_cases(self) -> list[Case]:
        return [
            Case(
                case_id="smoke-docker:docker-ssh",
                label="docker-ssh",
                family="smoke-docker",
                argv=["sh", str(REGRESS_DIR / "docker-ssh.sh")],
                required_capabilities=frozenset({"af_unix"}),
            )
        ]

    def build_fuzz_cases(self) -> list[Case]:
        fuzz_mode = normalize_fuzz_mode(self.args.fuzz_mode)
        if fuzz_mode == "off":
            return []
        binaries: list[tuple[str, pathlib.Path]] = []
        input_fuzzer = self.args.input_fuzzer or str(DEFAULT_INPUT_FUZZER)
        cmd_preprocess_fuzzer = self.args.cmd_preprocess_fuzzer or str(
            DEFAULT_CMD_PREPROCESS_FUZZER
        )
        if pathlib.Path(input_fuzzer).is_file():
            binaries.append(
                (
                    "input",
                    ensure_executable(pathlib.Path(input_fuzzer), "input fuzzer"),
                )
            )
        if pathlib.Path(cmd_preprocess_fuzzer).is_file():
            binaries.append(
                (
                    "cmd-preprocess",
                    ensure_executable(
                        pathlib.Path(cmd_preprocess_fuzzer),
                        "cmd preprocess fuzzer",
                    ),
                )
            )
        if not binaries:
            if fuzz_mode == "auto":
                return []
            raise HarnessError(
                "smoke-fuzz requires --input-fuzzer and/or --cmd-preprocess-fuzzer"
            )

        corpus_root = ROOT_DIR / "fuzz" / "corpus"
        corpus_files = sorted(
            path
            for path in corpus_root.iterdir()
            if path.is_file() and not path.name.endswith(".sh")
        )
        cases: list[Case] = []
        for target_name, binary in binaries:
            for corpus_file in corpus_files:
                label = f"{target_name}:{corpus_file.name}"
                cases.append(
                    Case(
                        case_id=f"fuzz-corpus:{label}",
                        label=label,
                        family="fuzz-corpus",
                        argv=[str(binary)],
                        stdin_path=str(corpus_file),
                    )
                )
        return cases

    def selected_cases(self) -> list[Case]:
        cases = self.suite_cases()
        if self.args.case_filter:
            cases = [
                case
                for case in cases
                if any(
                    filter_text in case.case_id or filter_text in case.label
                    for filter_text in self.args.case_filter
                )
            ]
        return cases

    def missing_capability_reason(self, case: Case) -> str | None:
        if (
            "af_unix" in case.required_capabilities
            and not self.af_unix_status.available
        ):
            return host_caps.capability_reason("af_unix", self.af_unix_status)
        return None

    def run(self) -> int:
        cases = self.selected_cases()
        if self.args.list_cases:
            for case in cases:
                timeout_s, source = self.timeout_policy.lookup_case(case)
                timeout_text = (
                    f"{timeout_s:.1f}" if timeout_s is not None else "MISSING"
                )
                caps_text = ",".join(sorted(case.required_capabilities)) or "-"
                print(
                    f"{case.case_id}\t{timeout_text}\t{source}\t{caps_text}\t{case.argv[0]}"
                )
            return 0

        if not cases:
            print("no cases selected", file=sys.stderr)
            return 1

        if self.args.timeout_override is None:
            missing = self.timeout_policy.missing_cases(cases)
            if missing:
                preview = ", ".join(missing[:5])
                if len(missing) > 5:
                    preview += ", ..."
                raise HarnessError(
                    f"missing explicit timeouts for {len(missing)} case(s): {preview}. "
                    "Use --allow-default-timeouts only while calibrating."
                )

        namespace_text = (
            "enabled" if self.use_namespaces else f"disabled ({self.namespace_reason})"
        )
        print(
            "orchestrator: "
            f"suite={self.args.suite} "
            f"namespace={namespace_text} "
            f"{self.af_unix_status.summary()}"
        )
        if self.workers > 1 and self.use_namespaces:
            self._summary_workers = self.workers
            self._run_parallel(cases)
        elif self.workers > 1:
            print(
                f"warning: namespaces unavailable ({self.namespace_reason}), falling back to serial",
                file=sys.stderr,
            )
            self._summary_workers = 1
            self._run_serial(cases)
        else:
            self._summary_workers = 1
            self._run_serial(cases)

        if self.args.summary_format != "none":
            self.print_summary()
        if self.interrupted_by is not None:
            return 128 + self.interrupted_by
        return (
            0
            if all(
                result.status in {"PASS", "SKIP"} and not result.cleanup_failed
                for result in self.results
            )
            else 1
        )

    def run_case(self, case: Case, timeout_s: float | None = None) -> CaseResult:
        missing_reason = self.missing_capability_reason(case)
        if missing_reason is not None:
            return CaseResult(
                case=case,
                status="SKIP",
                elapsed_s=0.0,
                detail=missing_reason,
            )
        if timeout_s is None:
            timeout_s = self.timeout_policy.for_case(case)
        worker = CaseWorker(
            sandbox_root=self.sandbox_root,
            zmux_binary=self.zmux_binary,
            oracle_tmux=self.oracle_tmux,
            helper_binary=self.helper_binary,
            af_unix_mode=self.af_unix_mode,
            use_namespaces=self.use_namespaces,
            register_active=self._coordinator.register,
            unregister_active=self._coordinator.unregister,
        )
        return worker.run(case, timeout_s)

    def _run_serial(self, cases: list[Case]) -> None:
        for case in cases:
            result = self.run_case(case)
            self._collector.record(result)
            suffix = (
                f" cleanup={result.cleanup_failed}" if result.cleanup_failed else ""
            )
            detail = f" {result.detail}" if result.detail else ""
            print(
                f"{result.status:12s} {case.case_id} {result.elapsed_s:6.2f}s{suffix}{detail}"
            )
            if self._coordinator.shutdown_requested:
                break

    def _run_parallel(self, cases: list[Case]) -> None:
        runnable_cases: list[Case] = []
        for case in cases:
            missing_reason = self.missing_capability_reason(case)
            if missing_reason is not None:
                result = CaseResult(
                    case=case,
                    status="SKIP",
                    elapsed_s=0.0,
                    detail=missing_reason,
                )
                self._collector.record(result)
                suffix = (
                    f" cleanup={result.cleanup_failed}" if result.cleanup_failed else ""
                )
                detail = f" {result.detail}" if result.detail else ""
                print(
                    f"{result.status:12s} {case.case_id} {result.elapsed_s:6.2f}s{suffix}{detail}"
                )
                if self._coordinator.shutdown_requested:
                    break
                continue
            runnable_cases.append(case)
        if self._coordinator.shutdown_requested or not runnable_cases:
            return
        print_lock = threading.Lock()
        pool = WorkerPool(
            n_workers=self.workers,
            coordinator=self._coordinator,
            collector=self._collector,
            worker_factory=lambda: CaseWorker(
                sandbox_root=self.sandbox_root,
                zmux_binary=self.zmux_binary,
                oracle_tmux=self.oracle_tmux,
                helper_binary=self.helper_binary,
                af_unix_mode=self.af_unix_mode,
                use_namespaces=self.use_namespaces,
                register_active=self._coordinator.register,
                unregister_active=self._coordinator.unregister,
            ),
            print_lock=print_lock,
            timeout_policy=self.timeout_policy,
        )
        pool.run(runnable_cases)

    def classify_case_exit(
        self,
        case: Case,
        returncode: int,
        stdout_path: pathlib.Path,
        stderr_path: pathlib.Path,
    ) -> tuple[str, str]:
        return classify_case_exit(case, returncode, stdout_path, stderr_path)

    def print_summary(self) -> None:
        print(summarize_results(self.results, workers=self._summary_workers))
        print_kept_sandboxes(self.results)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="timed test suite runner")
    parser.add_argument(
        "suite",
        choices=(
            "zig-unit",
            "zig-stress",
            "smoke-fast",
            "smoke-oracle",
            "smoke-recursive",
            "smoke-soak",
            "smoke-docker",
            "smoke-most",
            "smoke-all",
            "smoke-fuzz",
        ),
    )
    parser.add_argument("--zig-test-binary")
    parser.add_argument("--input-fuzzer")
    parser.add_argument("--cmd-preprocess-fuzzer")
    parser.add_argument("--fuzz-mode", choices=FUZZ_MODES, default="auto")
    parser.add_argument("--summary-format", choices=SUMMARY_FORMATS, default="default")
    parser.add_argument("--workers", type=int, default=1, metavar="N")
    parser.add_argument("--zmux-binary")
    parser.add_argument("--oracle-binary")
    parser.add_argument("--helper-binary")
    parser.add_argument("--af-unix", choices=host_caps.AF_UNIX_MODES)
    parser.add_argument("--skip-prune", action="store_true", default=False)
    parser.add_argument("--test-filter", action="append", default=[])
    parser.add_argument("--case-filter", action="append", default=[])
    parser.add_argument("--timeout-override", type=float)
    parser.add_argument("--allow-default-timeouts", action="store_true")
    parser.add_argument("--list-cases", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    runner = SuiteRunner(args)
    try:
        return runner.run()
    except HarnessError as exc:
        print(f"orchestrator: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

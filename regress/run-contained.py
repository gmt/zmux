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
import os
import pathlib
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass


MUX_NAMES = {"tmux", "zmux"}
GRACE_SECONDS = 0.5
TERM_ENV_KEYS = {
    "COLORTERM",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOGNAME",
    "PATH",
    "PYTHONPATH",
    "TERM",
    "TMPDIR",
    "TZ",
    "USER",
}
TERM_ENV_PREFIXES = ("SMOKE_", "TEST_", "TMUX_", "XDG_", "ZMUX_")


@dataclass(frozen=True)
class ProcInfo:
    pid: int
    start_time: int
    exe_name: str
    cmdline: str


class ContainedSignal(RuntimeError):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a smoke command in a contained environment and leave no net-new tmux/zmux processes behind.",
    )
    parser.add_argument(
        "--backend",
        choices=("auto", "systemd", "disciplined", "off"),
        default=os.environ.get("SMOKE_CONTAINMENT_BACKEND", "auto"),
        help="Containment backend to use.",
    )
    parser.add_argument(
        "--keep-run-root",
        action="store_true",
        default=os.environ.get("SMOKE_KEEP_RUN_ROOT") == "1",
        help="Keep the wrapper-owned run root instead of deleting it.",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command")
    return args


def systemd_backend_available() -> bool:
    if shutil.which("systemd-run") is None or shutil.which("systemctl") is None:
        return False
    probe = subprocess.run(
        ["systemctl", "--user", "show-environment"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return probe.returncode == 0


def choose_backend(requested: str) -> str:
    if requested == "auto":
        return "systemd" if systemd_backend_available() else "disciplined"
    if requested == "systemd" and not systemd_backend_available():
        raise RuntimeError("systemd containment backend requested but unavailable")
    return requested


def read_proc_cmdline(pid: int) -> str:
    try:
        data = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    if not data:
        return ""
    return " ".join(part.decode(errors="replace") for part in data.split(b"\0") if part)


def read_proc_start_time(pid: int) -> int | None:
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    end = stat.rfind(")")
    if end == -1:
        return None
    fields = stat[end + 2 :].split()
    if len(fields) < 20:
        return None
    try:
        return int(fields[19])
    except ValueError:
        return None


def read_proc_exe_name(pid: int) -> str | None:
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        try:
            exe = pathlib.Path(f"/proc/{pid}/comm").read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return None
    return pathlib.Path(exe).name


def snapshot_mux_processes() -> dict[tuple[int, int], ProcInfo]:
    snapshot: dict[tuple[int, int], ProcInfo] = {}
    for proc_dir in pathlib.Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        pid = int(proc_dir.name)
        exe_name = read_proc_exe_name(pid)
        if exe_name not in MUX_NAMES:
            continue
        start_time = read_proc_start_time(pid)
        if start_time is None:
            continue
        snapshot[(pid, start_time)] = ProcInfo(
            pid=pid,
            start_time=start_time,
            exe_name=exe_name,
            cmdline=read_proc_cmdline(pid),
        )
    return snapshot


def is_owned_process(info: ProcInfo, run_root: pathlib.Path) -> bool:
    run_root_text = str(run_root)
    return run_root_text in info.cmdline


def leaked_mux_processes(
    baseline: dict[tuple[int, int], ProcInfo],
    run_root: pathlib.Path,
) -> list[ProcInfo]:
    current = snapshot_mux_processes()
    return sorted(
        (
            info
            for key, info in current.items()
            if key not in baseline and is_owned_process(info, run_root)
        ),
        key=lambda info: (info.exe_name, info.pid),
    )


def signal_processes(processes: list[ProcInfo], sig: int) -> None:
    for info in processes:
        try:
            os.kill(info.pid, sig)
        except ProcessLookupError:
            continue


def cleanup_leaked_processes(
    baseline: dict[tuple[int, int], ProcInfo],
    run_root: pathlib.Path,
) -> list[ProcInfo]:
    leaked = leaked_mux_processes(baseline, run_root)
    if not leaked:
        return leaked
    signal_processes(leaked, signal.SIGTERM)
    time.sleep(GRACE_SECONDS)
    leaked = leaked_mux_processes(baseline, run_root)
    if not leaked:
        return leaked
    signal_processes(leaked, signal.SIGKILL)
    time.sleep(GRACE_SECONDS)
    return leaked_mux_processes(baseline, run_root)


def process_env_for_systemd(env: dict[str, str]) -> list[str]:
    args: list[str] = []
    for key, value in sorted(env.items()):
        if "\n" in value:
            continue
        if key in TERM_ENV_KEYS or key.startswith(TERM_ENV_PREFIXES):
            args.append(f"--setenv={key}={value}")
    return args


class ContainedRun:
    def __init__(self, command: list[str], backend: str, keep_run_root: bool) -> None:
        self.command = command
        self.backend = backend
        self.keep_run_root = keep_run_root
        artifact_parent = pathlib.Path(os.environ.get("SMOKE_ARTIFACT_ROOT", "/tmp"))
        artifact_parent.mkdir(parents=True, exist_ok=True)
        self.run_root = pathlib.Path(tempfile.mkdtemp(prefix="zmux-contained-", dir=str(artifact_parent)))
        self.artifact_root = self.run_root / "artifacts"
        self.artifact_root.mkdir(parents=True, exist_ok=True)
        self.baseline = snapshot_mux_processes()
        self.process: subprocess.Popen[str] | None = None
        self.unit_name: str | None = None
        self._stopped = False

        self.inner_env = os.environ.copy()
        self.inner_env["SMOKE_CONTAINMENT_ACTIVE"] = "1"
        self.inner_env["SMOKE_CONTAINMENT_BACKEND"] = backend
        self.inner_env["SMOKE_RUN_ROOT"] = str(self.run_root)
        self.inner_env["SMOKE_ARTIFACT_ROOT"] = str(self.artifact_root)

    def run(self) -> int:
        if self.backend == "systemd":
            return self._run_systemd()
        if self.backend in {"disciplined", "off"}:
            return self._run_direct()
        raise RuntimeError(f"unknown backend: {self.backend}")

    def _run_direct(self) -> int:
        self.process = subprocess.Popen(
            self.command,
            env=self.inner_env,
            start_new_session=self.backend == "disciplined",
            text=False,
        )
        return self.process.wait()

    def _run_systemd(self) -> int:
        self.unit_name = f"zmux-smoke-{os.getpid()}-{random.getrandbits(24):06x}"
        cmd = [
            "systemd-run",
            "--user",
            "--quiet",
            "--wait",
            "--collect",
            "--pipe",
            "--same-dir",
            "--service-type=exec",
            "--unit",
            self.unit_name,
            "-p",
            "KillMode=control-group",
            *process_env_for_systemd(self.inner_env),
            *self.command,
        ]
        self.process = subprocess.Popen(cmd, text=False)
        return self.process.wait()

    def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True

        if self.backend == "systemd" and self.unit_name is not None:
            subprocess.run(
                ["systemctl", "--user", "stop", self.unit_name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        elif self.backend == "disciplined" and self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            time.sleep(GRACE_SECONDS)
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        if self.process is not None and self.process.poll() is None:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def finalize(self) -> list[ProcInfo]:
        leaked = cleanup_leaked_processes(self.baseline, self.run_root)
        if not self.keep_run_root:
            shutil.rmtree(self.run_root, ignore_errors=True)
        return leaked


def print_leaks(leaked: list[ProcInfo]) -> None:
    if not leaked:
        return
    print("leaked tmux/zmux processes from this run:", file=sys.stderr)
    for info in leaked:
        cmdline = info.cmdline or f"<{info.exe_name}>"
        print(f"  pid={info.pid} exe={info.exe_name} cmd={cmdline}", file=sys.stderr)


def run_uncontained(command: list[str]) -> int:
    proc = subprocess.Popen(command)
    return proc.wait()


def main() -> int:
    args = parse_args()

    if os.environ.get("SMOKE_CONTAINMENT_ACTIVE") == "1":
        return run_uncontained(args.command)

    backend = choose_backend(args.backend)
    runner = ContainedRun(args.command, backend, args.keep_run_root)
    received_signal: int | None = None
    exit_code = 1

    def signal_handler(signum: int, _frame: object) -> None:
        raise ContainedSignal(signum)

    handled_signals = [sig for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM) if sig is not None]
    previous_handlers = {sig: signal.getsignal(sig) for sig in handled_signals}
    for sig in handled_signals:
        signal.signal(sig, signal_handler)

    try:
        exit_code = runner.run()
    except ContainedSignal as exc:
        received_signal = exc.signum
    finally:
        for sig, previous in previous_handlers.items():
            signal.signal(sig, previous)
        if received_signal is not None or (runner.process is not None and runner.process.poll() is None):
            runner.stop()
        leaked = runner.finalize()

    print_leaks(leaked)

    if received_signal is not None:
        return 128 + received_signal
    if leaked:
        return exit_code if exit_code != 0 else 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

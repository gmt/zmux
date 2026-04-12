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

import smoke_owner


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
        choices=("auto", "systemd", "disciplined", "systemd-disciplined", "off"),
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


def process_env_for_systemd(env: dict[str, str]) -> list[str]:
    args: list[str] = []
    for key, value in sorted(env.items()):
        if "\n" in value:
            continue
        if key in TERM_ENV_KEYS or key.startswith(TERM_ENV_PREFIXES):
            args.append(f"--setenv={key}={value}")
    return args


def systemd_probe() -> tuple[bool, str | None]:
    if shutil.which("systemd-run") is None or shutil.which("systemctl") is None:
        return False, "systemd-run or systemctl not found"

    true_bin = shutil.which("true") or "/bin/true"
    try:
        probe = subprocess.run(
            [
                "systemd-run",
                "--user",
                "--quiet",
                "--wait",
                "--collect",
                "--pipe",
                "--service-type=exec",
                "-p",
                "KillMode=control-group",
                true_bin,
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)

    if probe.returncode == 0:
        return True, None

    detail = probe.stderr.strip() or probe.stdout.strip() or f"exit {probe.returncode}"
    return False, detail


def choose_backend(requested: str) -> tuple[str, str | None]:
    needs_systemd = requested in {"auto", "systemd", "systemd-disciplined"}
    available = False
    reason: str | None = None
    if needs_systemd:
        available, reason = systemd_probe()

    if requested == "auto":
        if available:
            return "systemd", None
        return "disciplined", reason

    if requested in {"systemd", "systemd-disciplined"} and not available:
        raise RuntimeError(f"{requested} containment backend requested but unavailable: {reason}")

    return requested, None


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
        self.owner_dir = self.run_root / "owned-pids"
        self.process: subprocess.Popen[bytes] | None = None
        self.unit_name: str | None = None
        self._stopped = False
        self.script_path = pathlib.Path(__file__).resolve()

        self.inner_env = os.environ.copy()
        self.inner_env["SMOKE_CONTAINMENT_ACTIVE"] = "1"
        self.inner_env["SMOKE_CONTAINMENT_BACKEND"] = backend
        self.inner_env["SMOKE_RUN_ROOT"] = str(self.run_root)
        self.inner_env["SMOKE_ARTIFACT_ROOT"] = str(self.artifact_root)
        self.inner_env["SMOKE_OWNER_DIR"] = str(self.owner_dir)

    def run(self) -> int:
        if self.backend == "systemd":
            return self._run_systemd(self.command, self.inner_env)
        if self.backend == "systemd-disciplined":
            nested_command = [
                sys.executable,
                str(self.script_path),
                "--backend",
                "disciplined",
            ]
            if self.keep_run_root:
                nested_command.append("--keep-run-root")
            nested_command.extend(["--", *self.command])

            nested_env = os.environ.copy()
            nested_env["SMOKE_ARTIFACT_ROOT"] = os.environ.get("SMOKE_ARTIFACT_ROOT", "/tmp")
            nested_env["SMOKE_CONTAINMENT_BACKEND"] = "disciplined"
            return self._run_systemd(nested_command, nested_env)
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

    def _run_systemd(self, payload: list[str], payload_env: dict[str, str]) -> int:
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
            *process_env_for_systemd(payload_env),
            *payload,
        ]
        self.process = subprocess.Popen(cmd, text=False)
        return self.process.wait()

    def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True

        if self.backend in {"systemd", "systemd-disciplined"} and self.unit_name is not None:
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
        elif self.process is not None and self.process.poll() is None:
            self.process.terminate()

        if self.process is not None and self.process.poll() is None:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def finalize(self) -> list[smoke_owner.OwnedPid]:
        leaked = smoke_owner.cleanup_registered(self.owner_dir, grace_seconds=GRACE_SECONDS)
        if not self.keep_run_root:
            shutil.rmtree(self.run_root, ignore_errors=True)
        return leaked


def print_leaks(leaked: list[smoke_owner.OwnedPid]) -> None:
    if not leaked:
        return
    print("leaked owned tmux/zmux processes from this run:", file=sys.stderr)
    for entry in leaked:
        socket_info = f" socket={entry.socket_path}" if entry.socket_path else ""
        exe_info = f" exe={entry.exe_name}" if entry.exe_name else ""
        print(
            f"  pid={entry.pid} start={entry.start_time} kind={entry.kind} owner={entry.owner_label}{exe_info}{socket_info}",
            file=sys.stderr,
        )


def run_uncontained(command: list[str]) -> int:
    proc = subprocess.Popen(command)
    return proc.wait()


def main() -> int:
    args = parse_args()

    if os.environ.get("SMOKE_CONTAINMENT_ACTIVE") == "1":
        return run_uncontained(args.command)

    backend, downgrade_reason = choose_backend(args.backend)
    if args.backend == "auto" and backend != "systemd" and downgrade_reason:
        print(
            f"run-contained: systemd unavailable, using disciplined backend ({downgrade_reason})",
            file=sys.stderr,
        )

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

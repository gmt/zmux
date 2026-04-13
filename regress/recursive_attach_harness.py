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
import concurrent.futures
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

import smoke_env
import smoke_owner


SCRIPT_PATH = pathlib.Path(__file__).resolve()
ROOT_DIR = SCRIPT_PATH.parent.parent


class RecursiveAttachError(RuntimeError):
    pass


@dataclass(frozen=True)
class Expectation:
    kind: str
    stderr_substring: str | None = None


@dataclass(frozen=True)
class RecursiveCase:
    name: str
    root_binary: str
    inner_binary: str
    expectation: Expectation


class RecursiveAttachHarness:
    def __init__(self, artifact_root: pathlib.Path, zmux_binary: str, oracle_binary: str, timeout_seconds: float) -> None:
        self.artifact_dir = pathlib.Path(tempfile.mkdtemp(prefix="zmux-recursive-attach-", dir=str(artifact_root)))
        self.owner_dir = smoke_owner.resolve_owner_dir() or (self.artifact_dir / "owned-pids")
        self.zmux_binary = zmux_binary
        self.oracle_binary = oracle_binary
        self.timeout_seconds = timeout_seconds
        self.env = smoke_env.build_smoke_env(
            mode=os.environ.get("SMOKE_ENV_MODE", "ambient"),
            home_dir=self.artifact_dir / "home",
            zmux_binary=os.environ.get("TEST_ZMUX"),
            oracle_tmux=os.environ.get("TEST_ORACLE_TMUX", "/usr/bin/tmux"),
        )

    def root_base_args(self, binary: str, socket_path: pathlib.Path) -> list[str]:
        return shlex.split(binary) + ["-S", str(socket_path), "-f/dev/null"]

    def build_cases(self) -> list[RecursiveCase]:
        return [
            RecursiveCase(
                name="tmux-in-zmux",
                root_binary=self.zmux_binary,
                inner_binary=self.oracle_binary,
                expectation=Expectation(kind="timeout"),
            ),
            RecursiveCase(
                name="zmux-in-tmux",
                root_binary=self.oracle_binary,
                inner_binary=self.zmux_binary,
                expectation=Expectation(kind="timeout"),
            ),
            RecursiveCase(
                name="tmux-in-tmux",
                root_binary=self.oracle_binary,
                inner_binary=self.oracle_binary,
                expectation=Expectation(kind="timeout"),
            ),
            RecursiveCase(
                name="zmux-in-zmux",
                root_binary=self.zmux_binary,
                inner_binary=self.zmux_binary,
                expectation=Expectation(kind="timeout"),
            ),
        ]

    def run(self) -> None:
        cases = self.build_cases()
        waves = (
            tuple(cases[0:2]),
            tuple(cases[2:4]),
        )

        for wave in waves:
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(wave)) as pool:
                futures = [pool.submit(self.run_case, case) for case in wave]
                for future in concurrent.futures.as_completed(futures):
                    future.result()

    def run_case_by_name(self, name: str) -> None:
        for case in self.build_cases():
            if case.name == name:
                self.run_case(case)
                return
        raise RecursiveAttachError(f"unknown recursive case {name}")

    def run_case(self, case: RecursiveCase) -> None:
        case_dir = self.artifact_dir / case.name
        case_dir.mkdir(parents=True, exist_ok=True)
        root_socket = case_dir / "root.socket"
        results_path = case_dir / "results.json"
        command = shlex.join(
            [
                "python3",
                str(SCRIPT_PATH),
                "inner-probe",
                "--inner-binary",
                case.inner_binary,
                "--output-json",
                str(results_path),
                "--timeout-seconds",
                str(self.timeout_seconds),
            ]
        )

        base = self.root_base_args(case.root_binary, root_socket)
        create = subprocess.run(
            base + ["new-session", "-d", "-s", "recursive-attach", command],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=5.0,
            start_new_session=True,
        )
        if create.returncode != 0:
            raise RecursiveAttachError(
                f"{case.name}: failed to start root container\nstdout:\n{create.stdout}\nstderr:\n{create.stderr}"
            )
        smoke_owner.register_server(
            base,
            self.env,
            owner_dir=self.owner_dir,
            owner_label=f"{case.name}-root",
            socket_path=str(root_socket),
            timeout=2.0,
        )

        try:
            self.wait_for_results(results_path)
            result = json.loads(results_path.read_text(encoding="utf-8"))
            self.verify_case(case, result)
        finally:
            self.cleanup_root(case.root_binary, root_socket)

    def wait_for_results(self, results_path: pathlib.Path) -> None:
        deadline = time.time() + self.timeout_seconds + 5.0
        while time.time() < deadline:
            if results_path.exists():
                return
            time.sleep(0.1)
        raise RecursiveAttachError(f"timed out waiting for recursive attach probe results: {results_path}")

    def verify_case(self, case: RecursiveCase, result: dict[str, object]) -> None:
        outcome = result["attach_outcome"]
        if not isinstance(outcome, dict):
            raise RecursiveAttachError(f"{case.name}: malformed result payload: {result}")

        actual_kind = outcome.get("kind")
        if actual_kind != case.expectation.kind:
            raise RecursiveAttachError(
                f"{case.name}: expected {case.expectation.kind}, found {actual_kind}\n"
                f"result: {json.dumps(result, indent=2, sort_keys=True)}"
            )

        if case.expectation.stderr_substring is not None:
            stderr_text = str(outcome.get("stderr", ""))
            if case.expectation.stderr_substring not in stderr_text:
                raise RecursiveAttachError(
                    f"{case.name}: expected stderr containing {case.expectation.stderr_substring!r}\n"
                    f"result: {json.dumps(result, indent=2, sort_keys=True)}"
                )

    def cleanup_root(self, binary: str, socket_path: pathlib.Path) -> None:
        try:
            subprocess.run(
                self.root_base_args(binary, socket_path) + ["kill-server"],
                capture_output=True,
                text=True,
                env=self.env,
                timeout=2.0,
                start_new_session=True,
                check=False,
            )
        except subprocess.TimeoutExpired:
            pass
        smoke_owner.cleanup_registered(
            self.owner_dir,
            socket_path=str(socket_path),
            grace_seconds=0.2,
        )


def run_inner_probe(inner_binary: str, output_json: pathlib.Path, timeout_seconds: float) -> None:
    output_json.parent.mkdir(parents=True, exist_ok=True)
    owner_dir = smoke_owner.resolve_owner_dir() or (output_json.parent / "owned-pids")
    env = smoke_env.build_smoke_env(
        mode=os.environ.get("SMOKE_ENV_MODE", "ambient"),
        home_dir=output_json.parent / "home",
        zmux_binary=os.environ.get("TEST_ZMUX"),
        oracle_tmux=os.environ.get("TEST_ORACLE_TMUX", "/usr/bin/tmux"),
    )
    socket_path = output_json.parent / "inner.socket"
    base = shlex.split(inner_binary) + ["-S", str(socket_path), "-f/dev/null"]

    steps: list[dict[str, object]] = []
    for args in (["start-server"], ["new-session", "-d", "-s", "smoke"]):
        proc = subprocess.run(
            base + args,
            capture_output=True,
            text=True,
            env=env,
            timeout=5.0,
            start_new_session=True,
        )
        steps.append(
            {
                "args": args,
                "returncode": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
            }
        )
    smoke_owner.register_server(
        base,
        env,
        owner_dir=owner_dir,
        owner_label=f"inner-probe:{output_json.parent.name}",
        socket_path=str(socket_path),
        timeout=2.0,
    )

    try:
        proc = subprocess.run(
            base + ["attach-session", "-t", "smoke"],
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout_seconds,
            start_new_session=True,
        )
        outcome = {
            "kind": "fast_error" if proc.returncode != 0 else "success",
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }
    except subprocess.TimeoutExpired:
        outcome = {
            "kind": "timeout",
            "timeout_seconds": timeout_seconds,
            "stdout": "",
            "stderr": "",
        }

    payload = {
        "env": {key: env.get(key) for key in ("TERM", "COLORTERM", "TMUX", "ZMUX")},
        "inner_binary": inner_binary,
        "steps": steps,
        "attach_outcome": outcome,
    }
    try:
        output_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    finally:
        try:
            subprocess.run(
                base + ["kill-server"],
                capture_output=True,
                text=True,
                env=env,
                timeout=2.0,
                start_new_session=True,
                check=False,
            )
        except subprocess.TimeoutExpired:
            pass
        smoke_owner.cleanup_registered(
            owner_dir,
            socket_path=str(socket_path),
            grace_seconds=0.2,
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="recursive attach characterization harness")
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run")
    run_parser.add_argument("--artifact-root", default=os.environ.get("SMOKE_ARTIFACT_ROOT", "/tmp"))
    run_parser.add_argument("--zmux-binary", default=os.environ.get("TEST_ZMUX", str(ROOT_DIR / "zig-out/bin/zmux")))
    run_parser.add_argument("--oracle-binary", default=os.environ.get("TEST_ORACLE_TMUX", "/usr/bin/tmux"))
    run_parser.add_argument("--timeout-seconds", type=float, default=2.0)

    run_case_parser = sub.add_parser("run-case")
    run_case_parser.add_argument("case_name")
    run_case_parser.add_argument("--artifact-root", default=os.environ.get("SMOKE_ARTIFACT_ROOT", "/tmp"))
    run_case_parser.add_argument("--zmux-binary", default=os.environ.get("TEST_ZMUX", str(ROOT_DIR / "zig-out/bin/zmux")))
    run_case_parser.add_argument("--oracle-binary", default=os.environ.get("TEST_ORACLE_TMUX", "/usr/bin/tmux"))
    run_case_parser.add_argument("--timeout-seconds", type=float, default=2.0)

    inner = sub.add_parser("inner-probe")
    inner.add_argument("--inner-binary", required=True)
    inner.add_argument("--output-json", type=pathlib.Path, required=True)
    inner.add_argument("--timeout-seconds", type=float, default=2.0)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "run":
            artifact_root = pathlib.Path(args.artifact_root)
            artifact_root.mkdir(parents=True, exist_ok=True)
            harness = RecursiveAttachHarness(
                artifact_root=artifact_root,
                zmux_binary=args.zmux_binary,
                oracle_binary=args.oracle_binary,
                timeout_seconds=args.timeout_seconds,
            )
            harness.run()
            return 0

        if args.command == "run-case":
            artifact_root = pathlib.Path(args.artifact_root)
            artifact_root.mkdir(parents=True, exist_ok=True)
            harness = RecursiveAttachHarness(
                artifact_root=artifact_root,
                zmux_binary=args.zmux_binary,
                oracle_binary=args.oracle_binary,
                timeout_seconds=args.timeout_seconds,
            )
            harness.run_case_by_name(args.case_name)
            return 0

        if args.command == "inner-probe":
            run_inner_probe(args.inner_binary, args.output_json, args.timeout_seconds)
            return 0

        raise RecursiveAttachError(f"unknown command {args.command}")
    except RecursiveAttachError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

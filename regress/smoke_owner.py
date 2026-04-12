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
import json
import os
import pathlib
import shlex
import signal
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass


DEFAULT_GRACE_SECONDS = 0.5


@dataclass(frozen=True)
class OwnedPid:
    pid: int
    start_time: int
    kind: str
    owner_label: str
    socket_path: str | None
    exe_name: str


def _proc_root() -> pathlib.Path:
    return pathlib.Path("/proc")


def read_proc_start_time(pid: int) -> int | None:
    try:
        stat = (_proc_root() / str(pid) / "stat").read_text(encoding="utf-8", errors="replace")
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


def read_proc_exe_name(pid: int) -> str:
    try:
        exe = os.readlink(_proc_root() / str(pid) / "exe")
        return pathlib.Path(exe).name
    except OSError:
        pass
    try:
        return (_proc_root() / str(pid) / "comm").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def pid_is_live(entry: OwnedPid) -> bool:
    return read_proc_start_time(entry.pid) == entry.start_time


def resolve_owner_dir(owner_dir: pathlib.Path | str | None = None) -> pathlib.Path | None:
    if owner_dir is not None:
        return pathlib.Path(owner_dir)
    env_owner = os.environ.get("SMOKE_OWNER_DIR")
    if env_owner:
        return pathlib.Path(env_owner)
    run_root = os.environ.get("SMOKE_RUN_ROOT")
    if run_root:
        return pathlib.Path(run_root) / "owned-pids"
    return None


def _record_path(owner_dir: pathlib.Path, entry: OwnedPid) -> pathlib.Path:
    return owner_dir / f"{entry.pid}-{entry.start_time}.json"


def register_pid(
    pid: int,
    *,
    owner_dir: pathlib.Path | str | None = None,
    kind: str = "server",
    owner_label: str = "smoke",
    socket_path: str | None = None,
    exe_name: str | None = None,
) -> OwnedPid:
    resolved_dir = resolve_owner_dir(owner_dir)
    if resolved_dir is None:
        raise RuntimeError("no owner dir available")
    start_time = read_proc_start_time(pid)
    if start_time is None:
        raise RuntimeError(f"unable to read start time for pid {pid}")
    entry = OwnedPid(
        pid=pid,
        start_time=start_time,
        kind=kind,
        owner_label=owner_label,
        socket_path=socket_path,
        exe_name=exe_name or read_proc_exe_name(pid),
    )
    resolved_dir.mkdir(parents=True, exist_ok=True)
    record_path = _record_path(resolved_dir, entry)
    if not record_path.exists():
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=resolved_dir,
            prefix=f".{record_path.name}.",
            delete=False,
        ) as handle:
            json.dump(asdict(entry), handle, sort_keys=True)
            handle.write("\n")
            temp_path = pathlib.Path(handle.name)
        temp_path.replace(record_path)
    return entry


def list_entries(owner_dir: pathlib.Path | str | None = None) -> list[OwnedPid]:
    resolved_dir = resolve_owner_dir(owner_dir)
    if resolved_dir is None or not resolved_dir.exists():
        return []
    entries: list[OwnedPid] = []
    for record in sorted(resolved_dir.glob("*.json")):
        try:
            payload = json.loads(record.read_text(encoding="utf-8"))
            entries.append(OwnedPid(**payload))
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            continue
    return entries


def filter_entries(
    entries: list[OwnedPid],
    *,
    kind: str | None = None,
    socket_path: str | None = None,
) -> list[OwnedPid]:
    filtered = entries
    if kind is not None:
        filtered = [entry for entry in filtered if entry.kind == kind]
    if socket_path is not None:
        filtered = [entry for entry in filtered if entry.socket_path == socket_path]
    return filtered


def live_entries(
    owner_dir: pathlib.Path | str | None = None,
    *,
    kind: str | None = None,
    socket_path: str | None = None,
) -> list[OwnedPid]:
    entries = filter_entries(list_entries(owner_dir), kind=kind, socket_path=socket_path)
    return [entry for entry in entries if pid_is_live(entry)]


def signal_entries(entries: list[OwnedPid], sig: int) -> None:
    for entry in entries:
        if not pid_is_live(entry):
            continue
        try:
            os.kill(entry.pid, sig)
        except ProcessLookupError:
            continue


def cleanup_registered(
    owner_dir: pathlib.Path | str | None = None,
    *,
    kind: str | None = None,
    socket_path: str | None = None,
    grace_seconds: float = DEFAULT_GRACE_SECONDS,
) -> list[OwnedPid]:
    survivors = live_entries(owner_dir, kind=kind, socket_path=socket_path)
    if not survivors:
        return []
    signal_entries(survivors, signal.SIGTERM)
    time.sleep(grace_seconds)
    survivors = live_entries(owner_dir, kind=kind, socket_path=socket_path)
    if not survivors:
        return []
    signal_entries(survivors, signal.SIGKILL)
    time.sleep(grace_seconds)
    return live_entries(owner_dir, kind=kind, socket_path=socket_path)


def query_server_pid(base_args: list[str], env: dict[str, str], *, timeout: float = 2.0) -> int | None:
    try:
        proc = subprocess.run(
            base_args + ["display-message", "-p", "#{pid}"],
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired:
        return None
    if proc.returncode != 0:
        return None
    output = proc.stdout.strip()
    if not output.isdigit():
        return None
    return int(output)


def register_server(
    base_args: list[str],
    env: dict[str, str],
    *,
    owner_dir: pathlib.Path | str | None = None,
    owner_label: str = "smoke",
    socket_path: str | None = None,
    kind: str = "server",
    timeout: float = 2.0,
) -> OwnedPid | None:
    pid = query_server_pid(base_args, env, timeout=timeout)
    if pid is None:
        return None
    return register_pid(
        pid,
        owner_dir=owner_dir,
        kind=kind,
        owner_label=owner_label,
        socket_path=socket_path,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="register and clean up owned smoke processes")
    sub = parser.add_subparsers(dest="command", required=True)

    register = sub.add_parser("register")
    register.add_argument("--owner-dir")
    register.add_argument("--pid", required=True, type=int)
    register.add_argument("--kind", default="server")
    register.add_argument("--owner-label", default="smoke")
    register.add_argument("--socket-path")

    register_server_cmd = sub.add_parser("register-server")
    register_server_cmd.add_argument("--owner-dir")
    register_server_cmd.add_argument("--kind", default="server")
    register_server_cmd.add_argument("--owner-label", default="smoke")
    register_server_cmd.add_argument("--socket-path")
    register_server_cmd.add_argument("--timeout", type=float, default=2.0)
    register_server_cmd.add_argument("base_args", nargs=argparse.REMAINDER)

    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--owner-dir")
    cleanup.add_argument("--kind")
    cleanup.add_argument("--socket-path")
    cleanup.add_argument("--grace-seconds", type=float, default=DEFAULT_GRACE_SECONDS)

    live = sub.add_parser("live")
    live.add_argument("--owner-dir")
    live.add_argument("--kind")
    live.add_argument("--socket-path")

    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.command == "register":
        entry = register_pid(
            args.pid,
            owner_dir=args.owner_dir,
            kind=args.kind,
            owner_label=args.owner_label,
            socket_path=args.socket_path,
        )
        print(json.dumps(asdict(entry), sort_keys=True))
        return 0

    if args.command == "register-server":
        base_args = args.base_args
        if base_args and base_args[0] == "--":
            base_args = base_args[1:]
        if not base_args:
            raise SystemExit("missing server base args")
        entry = register_server(
            base_args,
            os.environ.copy(),
            owner_dir=args.owner_dir,
            kind=args.kind,
            owner_label=args.owner_label,
            socket_path=args.socket_path,
            timeout=args.timeout,
        )
        if entry is None:
            return 1
        print(json.dumps(asdict(entry), sort_keys=True))
        return 0

    if args.command == "cleanup":
        survivors = cleanup_registered(
            args.owner_dir,
            kind=args.kind,
            socket_path=args.socket_path,
            grace_seconds=args.grace_seconds,
        )
        for entry in survivors:
            print(json.dumps(asdict(entry), sort_keys=True))
        return 0 if not survivors else 1

    if args.command == "live":
        entries = live_entries(args.owner_dir, kind=args.kind, socket_path=args.socket_path)
        for entry in entries:
            print(json.dumps(asdict(entry), sort_keys=True))
        return 0 if not entries else 1

    raise SystemExit(f"unknown command {args.command}")


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))

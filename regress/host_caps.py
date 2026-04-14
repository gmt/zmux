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
import shutil
import socket
import sys
import tempfile
import threading
from dataclasses import dataclass

import artifact_root as artifact_root_module


AF_UNIX_ENV = "SMOKE_AF_UNIX"
AF_UNIX_MODES = ("auto", "require", "skip")


@dataclass(frozen=True)
class CapabilityStatus:
    name: str
    available: bool
    detail: str = ""

    def summary(self) -> str:
        if self.available:
            return f"{self.name}=enabled"
        if self.detail:
            return f"{self.name}=disabled ({self.detail})"
        return f"{self.name}=disabled"


def normalize_af_unix_mode(raw: str | None) -> str:
    value = (raw or os.environ.get(AF_UNIX_ENV, "auto")).strip().lower()
    if value not in AF_UNIX_MODES:
        valid = ", ".join(AF_UNIX_MODES)
        raise ValueError(
            f"invalid {AF_UNIX_ENV} mode {value!r}; expected one of {valid}"
        )
    return value


def capability_reason(capability: str, status: CapabilityStatus) -> str:
    detail = status.detail or "unavailable"
    return f"{capability} unavailable: {detail}"


def af_unix_status(
    *, mode: str | None = None, artifact_root: pathlib.Path | None = None
) -> CapabilityStatus:
    selected_mode = normalize_af_unix_mode(mode)
    if selected_mode == "skip":
        return CapabilityStatus("af_unix", False, "disabled by override")
    return probe_af_unix(artifact_root=artifact_root)


def enforce_af_unix(
    *,
    mode: str | None = None,
    artifact_root: pathlib.Path | None = None,
) -> tuple[bool, CapabilityStatus, str]:
    selected_mode = normalize_af_unix_mode(mode)
    status = af_unix_status(mode=selected_mode, artifact_root=artifact_root)
    if status.available:
        return True, status, ""
    message = capability_reason("af_unix", status)
    if selected_mode == "require":
        return False, status, message
    return False, status, message


def probe_af_unix(*, artifact_root: pathlib.Path | None = None) -> CapabilityStatus:
    root = artifact_root or artifact_root_module.default_artifact_root()
    root.mkdir(parents=True, exist_ok=True)
    probe_dir = pathlib.Path(tempfile.mkdtemp(prefix="zaf-", dir=str(root)))
    socket_path = probe_dir / "probe.sock"

    server_ready = threading.Event()
    server_result: dict[str, object] = {}

    def server() -> None:
        listener: socket.socket | None = None
        conn: socket.socket | None = None
        try:
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                listener.bind(str(socket_path))
            except OSError as exc:
                server_result["error"] = f"bind failed: {format_os_error(exc)}"
                return
            try:
                listener.listen(1)
            except OSError as exc:
                server_result["error"] = f"listen failed: {format_os_error(exc)}"
                return
            listener.settimeout(1.0)
            server_ready.set()
            try:
                conn, _ = listener.accept()
            except OSError as exc:
                server_result["error"] = f"accept failed: {format_os_error(exc)}"
                return
            conn.settimeout(1.0)
            try:
                payload = conn.recv(8)
                conn.sendall(b"ok")
            except OSError as exc:
                server_result["error"] = (
                    f"server exchange failed: {format_os_error(exc)}"
                )
                return
            server_result["payload"] = payload
        finally:
            if conn is not None:
                conn.close()
            if listener is not None:
                listener.close()
            server_ready.set()

    thread = threading.Thread(target=server, name="af-unix-probe", daemon=True)
    thread.start()
    try:
        if not server_ready.wait(timeout=1.0):
            return CapabilityStatus("af_unix", False, "probe setup timed out")
        if "error" in server_result:
            return CapabilityStatus("af_unix", False, str(server_result["error"]))

        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            try:
                client.connect(str(socket_path))
            except OSError as exc:
                return CapabilityStatus(
                    "af_unix", False, f"connect failed: {format_os_error(exc)}"
                )
            try:
                client.sendall(b"ping")
                reply = client.recv(8)
            except OSError as exc:
                return CapabilityStatus(
                    "af_unix", False, f"client exchange failed: {format_os_error(exc)}"
                )
        finally:
            client.close()

        thread.join(timeout=1.0)
        if "error" in server_result:
            return CapabilityStatus("af_unix", False, str(server_result["error"]))
        if server_result.get("payload") != b"ping":
            return CapabilityStatus("af_unix", False, "unexpected probe payload")
        if reply != b"ok":
            return CapabilityStatus("af_unix", False, "unexpected probe reply")
        return CapabilityStatus("af_unix", True)
    finally:
        shutil.rmtree(probe_dir, ignore_errors=True)


def format_os_error(exc: OSError) -> str:
    if exc.errno is None:
        return str(exc)
    text = exc.strerror or str(exc)
    return f"[Errno {exc.errno}] {text}"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="probe smoke host capabilities")
    parser.add_argument("--artifact-root", type=pathlib.Path)
    parser.add_argument("--af-unix", choices=AF_UNIX_MODES, default=None)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    ok, _status, message = enforce_af_unix(
        mode=args.af_unix, artifact_root=args.artifact_root
    )
    if ok:
        return 0
    print(message, file=sys.stderr)
    return 1 if normalize_af_unix_mode(args.af_unix) == "require" else 77


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

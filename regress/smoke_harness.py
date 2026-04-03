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
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

import smoke_env


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
MATRIX_PATH = SCRIPT_DIR / "oracle-command-matrix.tsv"


@dataclass(frozen=True)
class MatrixRow:
    command: str
    context: str
    zmux_status: str


class SmokeError(RuntimeError):
    pass


class SmokeTimeoutError(SmokeError):
    def __init__(self, args: list[str]) -> None:
        super().__init__(f"command timed out: {' '.join(args)}")
        self.args_list = args


class ControlClient:
    def __init__(self, harness: "SmokeHarness", name: str, session: str = "smoke") -> None:
        self.harness = harness
        self.name = name
        self.session = session
        self.stdout_path = harness.artifact_dir / f"{name}.stdout.log"
        self.stderr_path = harness.artifact_dir / f"{name}.stderr.log"
        self.stdout_file = self.stdout_path.open("w", encoding="utf-8")
        self.stderr_file = self.stderr_path.open("w", encoding="utf-8")
        argv = harness.mux_base_args() + ["-C", "attach-session", "-t", session]
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=self.stdout_file,
            stderr=self.stderr_file,
            text=True,
            env=harness.env,
            start_new_session=True,
        )
        if self.proc.stdin is not None:
            self.proc.stdin.write("refresh-client -C 90,30\n")
            self.proc.stdin.flush()

    def send(self, command: str) -> None:
        if self.proc.stdin is None:
            raise SmokeError(f"{self.name}: control stdin closed")
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()

    def wait_attached(self, minimum_clients: int = 1, timeout_s: float = 5.0) -> None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise SmokeError(f"{self.name}: control client exited early with {self.proc.returncode}")
            listing = self.harness.mux(
                ["list-clients"],
                timeout=2.0,
                accept_codes=(0, 1),
            )
            lines = [line for line in listing.stdout.splitlines() if line.strip()]
            if len(lines) >= minimum_clients:
                return
            time.sleep(0.1)
        raise SmokeError(f"{self.name}: control client never attached")

    def current_name(self) -> str | None:
        text = self.stdout_path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("%client-session-changed "):
                parts = line.split()
                if len(parts) >= 2:
                    return parts[1]
        return None

    def close(self) -> None:
        try:
            if self.proc.stdin is not None and self.proc.poll() is None:
                try:
                    self.send("detach-client")
                except BrokenPipeError:
                    pass
        finally:
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2)

            self.stdout_file.close()
            self.stderr_file.close()

    def stderr_is_clean(self) -> bool:
        text = self.stderr_path.read_text(encoding="utf-8", errors="replace")
        return text.strip() == ""


class SmokeHarness:
    CLIENTISH_COMMANDS = {
        "attach-session",
        "choose-buffer",
        "choose-client",
        "choose-tree",
        "clock-mode",
        "command-prompt",
        "confirm-before",
        "copy-mode",
        "customize-mode",
        "detach-client",
        "display-menu",
        "display-popup",
        "display-panes",
        "lock-client",
        "refresh-client",
        "show-messages",
        "suspend-client",
        "switch-client",
    }
    TIMEOUT_IS_EXERCISE = {
        "choose-buffer",
        "choose-client",
        "choose-tree",
        "clock-mode",
        "command-prompt",
        "confirm-before",
        "copy-mode",
        "customize-mode",
        "display-menu",
        "display-panes",
        "display-popup",
        "kill-server",
        "lock-client",
        "lock-server",
        "lock-session",
        "show-messages",
        "suspend-client",
    }
    CONTROL_CLIENT_EXERCISE = {
        "choose-buffer",
        "choose-client",
        "choose-tree",
        "clock-mode",
        "command-prompt",
        "copy-mode",
        "customize-mode",
        "display-menu",
        "display-panes",
        "show-messages",
    }

    def __init__(self, binary: str, artifact_root: pathlib.Path) -> None:
        self.binary = binary
        self.binary_argv = shlex.split(binary)
        self.artifact_dir = pathlib.Path(
            tempfile.mkdtemp(prefix="zmux-smoke-", dir=str(artifact_root))
        )
        self.socket_path = self.artifact_dir / "socket"
        self.temp_buffer = self.artifact_dir / "buffer.txt"
        self.temp_save = self.artifact_dir / "saved-buffer.txt"
        self.temp_conf = self.artifact_dir / "smoke.conf"
        self.temp_video = self.artifact_dir / "smoke-testsrc.mp4"
        self.inner_socket = self.artifact_dir / "inner.socket"
        self.control_clients: list[ControlClient] = []
        self._native_commands: set[str] | None = None
        env_mode = os.environ.get("SMOKE_ENV_MODE", "ambient")
        helper_mode = os.environ.get("ZMUX_SMOKE_HELPER_MODE")
        helper_path = os.environ.get("ZMUX_SMOKE_HELPER_PATH")
        self.env = smoke_env.build_smoke_env(
            mode=env_mode,
            home_dir=self.artifact_dir / "home",
            helper_mode=helper_mode,
            helper_path=helper_path,
        )

    def cleanup(self) -> None:
        for client in reversed(self.control_clients):
            client.close()
        self.control_clients.clear()
        self.kill_server()
        self.kill_wedged_server()

    def mux_base_args(self) -> list[str]:
        return self.binary_argv + ["-S", str(self.socket_path), "-f/dev/null"]

    def mux(
        self,
        args: list[str],
        *,
        timeout: float = 5.0,
        input_text: str | None = None,
        accept_codes: tuple[int, ...] = (0,),
    ) -> subprocess.CompletedProcess[str]:
        try:
            proc = subprocess.run(
                self.mux_base_args() + args,
                input=input_text,
                text=True,
                capture_output=True,
                timeout=timeout,
                env=self.env,
                start_new_session=True,
            )
        except subprocess.TimeoutExpired as exc:
            raise SmokeTimeoutError(args) from exc

        if proc.returncode not in accept_codes:
            raise SmokeError(
                f"unexpected exit {proc.returncode} for {' '.join(args)}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            )
        return proc

    def kill_server(self) -> None:
        try:
            self.mux(["kill-server"], timeout=2.0, accept_codes=(0, 1))
        except SmokeError:
            pass

    def kill_wedged_server(self) -> None:
        probe = subprocess.run(
            ["ps", "-eo", "pid=", "-o", "args="],
            capture_output=True,
            text=True,
            check=True,
        )
        pids = []
        marker = str(self.socket_path)
        for line in probe.stdout.splitlines():
            if marker in line:
                pid = line.strip().split(None, 1)[0]
                if pid.isdigit():
                    pids.append(pid)
        if pids:
            subprocess.run(["kill", "-9", *pids], check=False)

    def native_commands(self) -> set[str]:
        if self._native_commands is not None:
            return self._native_commands

        proc = subprocess.run(
            self.binary_argv + ["list-commands"],
            capture_output=True,
            text=True,
            env=self.env,
        )
        commands: set[str] = set()
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if not line.strip():
                    continue
                commands.add(line.split()[0])
        self._native_commands = commands
        return commands

    def supports(self, command: str) -> bool:
        native = self.native_commands()
        if native:
            return command in native
        for row in load_matrix():
            if row.command == command:
                return row.zmux_status == "implemented"
        return False

    def setup_base_state(self, *, needs_client: bool = False) -> str | None:
        self.cleanup()
        self.temp_buffer.write_text("payload\n", encoding="utf-8")
        self.temp_conf.write_text("set -g status off\n", encoding="utf-8")

        self.mux(["start-server"], accept_codes=(0, 1))
        self.mux(["new-session", "-d", "-s", "smoke"], accept_codes=(0, 1))
        self.mux(["new-session", "-d", "-s", "peer"], accept_codes=(0, 1))

        if self.supports("new-window"):
            self.mux(["new-window", "-d", "-t", "smoke"], accept_codes=(0, 1))

        if self.supports("split-window"):
            self.mux(["split-window", "-d", "-t", "smoke:0.0"], accept_codes=(0, 1))

        if self.supports("set-buffer"):
            self.mux(["set-buffer", "-b", "smoke-buf", "payload"], accept_codes=(0, 1))

        if self.supports("set-option"):
            self.mux(["set-option", "-g", "lock-command", "true"], accept_codes=(0, 1))

        if not needs_client:
            return None

        client = ControlClient(self, "control-main")
        self.control_clients.append(client)
        client.wait_attached()
        return self.current_client_name()

    def current_client_name(self) -> str | None:
        proc = self.mux(["list-clients"], accept_codes=(0, 1))
        for line in proc.stdout.splitlines():
            if line.strip():
                return line.split()[0]
        return None

    def verify_no_unknown_command(self, proc: subprocess.CompletedProcess[str], command: str) -> None:
        combined = f"{proc.stdout}\n{proc.stderr}".lower()
        if "unknown command" in combined:
            raise SmokeError(f"{command}: reported as unknown command")

    def ensure_oracle_manifest_matches(self) -> None:
        native = self.native_commands()
        if not native:
            return
        manifest = {row.command for row in load_matrix()}
        if manifest != native:
            missing = sorted(native - manifest)
            extra = sorted(manifest - native)
            raise SmokeError(
                "command matrix drifted from installed tmux\n"
                f"missing: {missing}\nextra: {extra}"
            )

    def exercise_row(self, row: MatrixRow, mode: str) -> None:
        if mode == "implemented" and row.zmux_status == "unsupported":
            self.mux([row.command], accept_codes=(0, 1))
            return

        needs_client = row.context == "client" or row.command in self.CLIENTISH_COMMANDS
        client_name = self.setup_base_state(needs_client=needs_client)
        self.prepare_command_state(row.command)
        if row.command == "attach-session":
            self.exercise_attach_session_interactive()
            return
        if row.command in self.CONTROL_CLIENT_EXERCISE:
            self.exercise_via_control_client(self.recipe_for(row.command, client_name))
            return
        try:
            proc = self.mux(
                self.recipe_for(row.command, client_name),
                timeout=6.0,
                accept_codes=(0, 1),
            )
        except SmokeTimeoutError:
            if row.command in self.TIMEOUT_IS_EXERCISE:
                return
            raise
        self.verify_no_unknown_command(proc, row.command)

    def exercise_attach_session_interactive(self) -> None:
        attach_client = ControlClient(self, "control-attach", session="smoke")
        self.control_clients.append(attach_client)
        attach_client.wait_attached(minimum_clients=2)
        if not attach_client.stderr_is_clean():
            raise SmokeError("control-attach: unexpected stderr during attach-session")

    def exercise_via_control_client(self, args: list[str]) -> None:
        if not self.control_clients:
            raise SmokeError(f"{args[0]}: no control client available")

        client = self.control_clients[0]
        if client.proc.poll() is not None:
            raise SmokeError(f"{args[0]}: control client exited before command dispatch")

        client.send(shlex.join(args))
        deadline = time.time() + 1.5
        while time.time() < deadline:
            if client.proc.poll() is not None:
                raise SmokeError(f"{args[0]}: control client exited early with {client.proc.returncode}")
            time.sleep(0.05)

        if not client.stderr_is_clean():
            raise SmokeError(f"{args[0]}: control client stderr was not clean")

    def prepare_command_state(self, command: str) -> None:
        if command in {"unlink-window"} and self.supports("link-window"):
            self.mux(["link-window", "-s", "smoke:1", "-t", "peer:9"], accept_codes=(0, 1))

        if command in {"swap-window", "move-window"}:
            self.mux(["new-window", "-d", "-t", "peer"], accept_codes=(0, 1))

        if command in {"last-window", "next-window", "previous-window", "swap-window", "move-window"}:
            self.mux(["select-window", "-t", "smoke:0"], accept_codes=(0, 1))

        if command in {"last-pane", "swap-pane", "join-pane", "move-pane", "kill-pane", "break-pane", "resize-pane"} and self.supports("split-window"):
            self.mux(["select-pane", "-t", "smoke:0.1"], accept_codes=(0, 1))

    def recipe_for(self, command: str, client_name: str | None) -> list[str]:
        client_target = client_name or "/dev/null"
        if command == "attach-session":
            return ["attach-session", "-t", "smoke"]
        if command == "bind-key":
            return ["bind-key", "F12", "display-message", "bound"]
        if command == "break-pane":
            return ["break-pane", "-s", "smoke:0.1", "-t", "smoke"]
        if command == "capture-pane":
            return ["capture-pane", "-p", "-t", "smoke:0.0"]
        if command == "choose-buffer":
            return ["choose-buffer", "-t", "smoke:0.0"]
        if command == "choose-client":
            return ["choose-client", "-t", "smoke:0.0"]
        if command == "choose-tree":
            return ["choose-tree", "-t", "smoke:0.0"]
        if command == "clear-history":
            return ["clear-history", "-t", "smoke:0.0"]
        if command == "clear-prompt-history":
            return ["clear-prompt-history"]
        if command == "clock-mode":
            return ["clock-mode", "-t", "smoke:0.0"]
        if command == "command-prompt":
            return ["command-prompt", "-t", client_target, "display-message command-prompt"]
        if command == "confirm-before":
            return ["confirm-before", "-b", "-y", "-t", client_target, "display-message", "confirmed"]
        if command == "copy-mode":
            return ["copy-mode", "-t", "smoke:0.0"]
        if command == "customize-mode":
            return ["customize-mode", "-t", "smoke:0.0"]
        if command == "delete-buffer":
            return ["delete-buffer", "-b", "smoke-buf"]
        if command == "detach-client":
            return ["detach-client", "-t", client_target]
        if command == "display-menu":
            return ["display-menu", "-t", "smoke:0.0", "smoke", "x", "display-message menu"]
        if command == "display-message":
            return ["display-message", "-p", "-t", "smoke:0.0", "#{session_name}:#{window_index}.#{pane_index}"]
        if command == "display-popup":
            return ["display-popup", "-t", "smoke:0.0", "true"]
        if command == "display-panes":
            return ["display-panes", "-t", client_target]
        if command == "find-window":
            return ["find-window", "-t", "smoke:0.0", "sh"]
        if command == "has-session":
            return ["has-session", "-t", "smoke"]
        if command == "if-shell":
            return ["if-shell", "-t", "smoke:0.0", "true", "display-message true"]
        if command == "join-pane":
            return ["join-pane", "-s", "smoke:0.1", "-t", "smoke:1.0"]
        if command == "kill-pane":
            return ["kill-pane", "-t", "smoke:0.1"]
        if command == "kill-server":
            return ["kill-server"]
        if command == "kill-session":
            return ["kill-session", "-t", "peer"]
        if command == "kill-window":
            return ["kill-window", "-t", "smoke:1"]
        if command == "last-pane":
            return ["last-pane", "-t", "smoke:0"]
        if command == "last-window":
            return ["last-window", "-t", "smoke"]
        if command == "link-window":
            return ["link-window", "-s", "smoke:1", "-t", "peer:9"]
        if command == "list-buffers":
            return ["list-buffers"]
        if command == "list-clients":
            return ["list-clients"]
        if command == "list-commands":
            return ["list-commands"]
        if command == "list-keys":
            return ["list-keys"]
        if command == "list-panes":
            return ["list-panes", "-t", "smoke:0"]
        if command == "list-sessions":
            return ["list-sessions"]
        if command == "list-windows":
            return ["list-windows", "-t", "smoke"]
        if command == "load-buffer":
            return ["load-buffer", "-b", "loaded-buf", str(self.temp_buffer)]
        if command == "lock-client":
            return ["lock-client", "-t", client_target]
        if command == "lock-server":
            return ["lock-server"]
        if command == "lock-session":
            return ["lock-session", "-t", "smoke"]
        if command == "move-pane":
            return ["move-pane", "-s", "smoke:0.1", "-t", "smoke:1.0"]
        if command == "move-window":
            return ["move-window", "-s", "smoke:1", "-t", "peer:3"]
        if command == "new-session":
            return ["new-session", "-d", "-s", "fresh"]
        if command == "new-window":
            return ["new-window", "-d", "-t", "smoke"]
        if command == "next-layout":
            return ["next-layout", "-t", "smoke:0"]
        if command == "next-window":
            return ["next-window", "-t", "smoke"]
        if command == "paste-buffer":
            return ["paste-buffer", "-b", "smoke-buf", "-t", "smoke:0.0"]
        if command == "pipe-pane":
            return ["pipe-pane", "-t", "smoke:0.0", "cat >/dev/null"]
        if command == "previous-layout":
            return ["previous-layout", "-t", "smoke:0"]
        if command == "previous-window":
            return ["previous-window", "-t", "smoke"]
        if command == "refresh-client":
            return ["refresh-client", "-t", client_target, "-C", "90,30"]
        if command == "rename-session":
            return ["rename-session", "-t", "smoke", "renamed"]
        if command == "rename-window":
            return ["rename-window", "-t", "smoke:1", "renamed"]
        if command == "resize-pane":
            return ["resize-pane", "-t", "smoke:0.0", "-x", "80", "-y", "20"]
        if command == "resize-window":
            return ["resize-window", "-t", "smoke:0", "-x", "100", "-y", "40"]
        if command == "respawn-pane":
            return ["respawn-pane", "-k", "-t", "smoke:0.0", "sh", "-lc", "printf respawn-pane; sleep 1"]
        if command == "respawn-window":
            return ["respawn-window", "-k", "-t", "smoke:1", "sh", "-lc", "printf respawn-window; sleep 1"]
        if command == "rotate-window":
            return ["rotate-window", "-t", "smoke:0"]
        if command == "run-shell":
            return ["run-shell", "true"]
        if command == "save-buffer":
            return ["save-buffer", "-b", "smoke-buf", str(self.temp_save)]
        if command == "select-layout":
            return ["select-layout", "-t", "smoke:0.0", "even-horizontal"]
        if command == "select-pane":
            return ["select-pane", "-t", "smoke:0.0"]
        if command == "select-window":
            return ["select-window", "-t", "smoke:1"]
        if command == "send-keys":
            return ["send-keys", "-t", "smoke:0.0", "Enter"]
        if command == "send-prefix":
            return ["send-prefix", "-t", "smoke:0.0"]
        if command == "server-access":
            return ["server-access", "-l"]
        if command == "set-buffer":
            return ["set-buffer", "-b", "smoke-buf", "payload"]
        if command == "set-environment":
            return ["set-environment", "-t", "smoke", "SMOKE_VAR", "1"]
        if command == "set-hook":
            return ["set-hook", "-t", "smoke:0.0", "after-new-window", "display-message hook"]
        if command == "set-option":
            return ["set-option", "-g", "status", "off"]
        if command == "set-window-option":
            return ["set-window-option", "-t", "smoke:0", "automatic-rename", "off"]
        if command == "show-buffer":
            return ["show-buffer", "-b", "smoke-buf"]
        if command == "show-environment":
            return ["show-environment", "-t", "smoke"]
        if command == "show-hooks":
            return ["show-hooks"]
        if command == "show-messages":
            return ["show-messages", "-t", client_target]
        if command == "show-options":
            return ["show-options", "-g"]
        if command == "show-prompt-history":
            return ["show-prompt-history"]
        if command == "show-window-options":
            return ["show-window-options", "-t", "smoke:0"]
        if command == "source-file":
            return ["source-file", str(self.temp_conf)]
        if command == "split-window":
            return ["split-window", "-d", "-t", "smoke:0.0"]
        if command == "start-server":
            return ["start-server"]
        if command == "suspend-client":
            return ["suspend-client", "-t", client_target]
        if command == "swap-pane":
            return ["swap-pane", "-s", "smoke:0.0", "-t", "smoke:0.1"]
        if command == "swap-window":
            return ["swap-window", "-s", "smoke:0", "-t", "smoke:1"]
        if command == "switch-client":
            return ["switch-client", "-t", "peer"]
        if command == "unbind-key":
            return ["unbind-key", "F12"]
        if command == "unlink-window":
            return ["unlink-window", "-t", "peer:9"]
        if command == "wait-for":
            return ["wait-for", "-S", "smoke-channel"]
        raise SmokeError(f"no recipe for {command}")

    def run_inside_suite(self) -> None:
        if not self.native_commands():
            self.run_inside_suite_zmux()
            return

        main_client_name = self.setup_base_state(needs_client=True)
        if main_client_name is None:
            raise SmokeError("inside suite: failed to create primary client")

        primary = self.control_clients[0]
        primary.send("refresh-client -C 110,35")
        self._poll(
            lambda: self.mux(
                ["display-message", "-p", "-t", "smoke:0", "#{window_width}x#{window_height}"],
                accept_codes=(0, 1),
            ).stdout.strip()
            == "110x35",
            timeout_s=5.0,
            message="control resize never propagated",
        )

        if self.supports("new-window") and self.supports("select-window"):
            primary.send("new-window -t smoke")
            self._poll(
                lambda: len(self.mux(["list-windows", "-t", "smoke"], accept_codes=(0, 1)).stdout.splitlines()) >= 3,
                timeout_s=5.0,
                message="new window never appeared",
            )
            primary.send("select-window -t smoke:1")

        secondary = ControlClient(self, "control-peer", session="smoke")
        self.control_clients.append(secondary)
        secondary.wait_attached(minimum_clients=2)

        if self.native_commands():
            nested_cmd = f"env ZMUX= {self.binary} -S {shlex.quote(str(self.inner_socket))} -f/dev/null new-session -d -s inner"
            self.mux(["new-window", "-d", "-t", "smoke", nested_cmd], accept_codes=(0, 1))
            self._poll(
                lambda: subprocess.run(
                    self.binary_argv + ["-S", str(self.inner_socket), "-f/dev/null", "has-session", "-t", "inner"],
                    capture_output=True,
                    text=True,
                    env=self.env,
                ).returncode
                == 0,
                timeout_s=5.0,
                message="nested session was not created",
            )

        primary.send("detach-client")
        self._poll(
            lambda: self.control_clients[0].proc.poll() is not None,
            timeout_s=5.0,
            message="primary client never detached",
        )

        for client in list(self.control_clients):
            client.close()
        self.control_clients.clear()

    def run_inside_suite_zmux(self) -> None:
        self.setup_base_state(needs_client=False)
        attach = self.mux(
            ["-C", "attach-session", "-t", "smoke"],
            input_text="list-clients\n",
            accept_codes=(0, 1),
        )
        self.verify_no_unknown_command(attach, "attach-session")

        if self.supports("new-window") and self.supports("select-window"):
            self.mux(
                ["-C", "attach-session", "-t", "smoke"],
                input_text="refresh-client -C 110,35\nnew-window -t smoke\nselect-window -t :1\n",
                accept_codes=(0, 1),
            )
            windows = self.mux(["list-windows", "-t", "smoke"], accept_codes=(0, 1))
            if len([line for line in windows.stdout.splitlines() if line.strip()]) < 2:
                raise SmokeError("one-shot control client never created a second window")

    def run_soak_suite(self) -> None:
        stress_seconds = int(os.environ.get("SMOKE_STRESS_SECONDS", "20"))
        viewer_count = int(os.environ.get("SMOKE_VIEWER_COUNT", "8"))

        self.setup_base_state(needs_client=True)
        server_pid = self.server_pid()
        if server_pid is None:
            raise SmokeError("unable to find server pid for soak run")

        if self.supports("split-window") and self.supports("send-keys"):
            self._build_test_video()
            self.mux(["split-window", "-d", "-t", "smoke:0.0", f"cacademo {self.temp_video}"], accept_codes=(0, 1))
            self.mux(["split-window", "-d", "-t", "smoke:0.0", self.truecolor_command()], accept_codes=(0, 1))
            self.mux(["split-window", "-d", "-t", "smoke:0.0", self.truecolor_command(offset=32)], accept_codes=(0, 1))

        churn_clients: list[ControlClient] = []
        for index in range(max(1, viewer_count)):
            client = ControlClient(self, f"viewer-{index}", session="smoke")
            churn_clients.append(client)
            client.wait_attached(minimum_clients=1)

        start_rss, start_fds = self.sample_process(server_pid)
        end_deadline = time.time() + stress_seconds

        while time.time() < end_deadline:
            short = ControlClient(self, f"burst-{int(time.time() * 1000)}", session="smoke")
            short.wait_attached(minimum_clients=1)
            short.close()
            time.sleep(0.2)

        end_rss, end_fds = self.sample_process(server_pid)

        for client in churn_clients:
            client.close()

        if end_rss > start_rss + 65536:
            raise SmokeError(f"rss grew too far during soak: {start_rss} -> {end_rss}")
        if end_fds > start_fds + 64:
            raise SmokeError(f"fd count grew too far during soak: {start_fds} -> {end_fds}")

    def sample_process(self, pid: int) -> tuple[int, int]:
        status = pathlib.Path(f"/proc/{pid}/status").read_text(encoding="utf-8", errors="replace")
        rss_kib = 0
        for line in status.splitlines():
            if line.startswith("VmRSS:"):
                rss_kib = int(line.split()[1])
                break
        fd_count = len(list(pathlib.Path(f"/proc/{pid}/fd").iterdir()))
        return rss_kib, fd_count

    def server_pid(self) -> int | None:
        probe = subprocess.run(
            ["ps", "-eo", "pid=", "-o", "args="],
            capture_output=True,
            text=True,
            check=True,
        )
        marker = str(self.socket_path)
        for line in probe.stdout.splitlines():
            if marker in line:
                head = line.strip().split(None, 1)[0]
                if head.isdigit():
                    return int(head)
        return None

    def truecolor_command(self, offset: int = 0) -> str:
        return (
            "sh -lc 'i=0; "
            "while [ \"$i\" -lt 80 ]; do "
            f"r=$((({offset} + i * 3) % 255)); "
            f"g=$((({offset} + i * 5) % 255)); "
            f"b=$((({offset} + i * 7) % 255)); "
            "printf \"\\033[48;2;%s;%s;%sm  \\033[0m\" \"$r\" \"$g\" \"$b\"; "
            "i=$((i + 1)); "
            "done; "
            "printf \"\\n\"; "
            "while true; do sleep 1; done'"
        )

    def _build_test_video(self) -> None:
        ffmpeg = subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=320x240:rate=24",
                "-t",
                "3",
                "-y",
                str(self.temp_video),
            ],
            capture_output=True,
            text=True,
        )
        if ffmpeg.returncode != 0:
            raise SmokeError(f"ffmpeg failed to build soak video:\n{ffmpeg.stderr}")

    def _poll(self, predicate, *, timeout_s: float, message: str) -> None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        raise SmokeError(message)


def load_matrix() -> list[MatrixRow]:
    rows: list[MatrixRow] = []
    with MATRIX_PATH.open("r", encoding="utf-8") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if not row or row[0].startswith("#"):
                continue
            rows.append(MatrixRow(*row))
    return rows


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="zmux smoke harness")
    parser.add_argument("suite", choices=("sweep", "inside", "soak"))
    parser.add_argument("--mode", choices=("implemented", "oracle"), default="implemented")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    artifact_root = pathlib.Path(os.environ.get("SMOKE_ARTIFACT_ROOT", "/tmp"))
    artifact_root.mkdir(parents=True, exist_ok=True)
    binary = os.environ.get("TEST_ZMUX", str(ROOT_DIR / "zig-out/bin/zmux"))
    harness = SmokeHarness(binary, artifact_root)

    try:
        if args.suite == "sweep":
            if args.mode == "oracle":
                harness.ensure_oracle_manifest_matches()
            for row in load_matrix():
                harness.exercise_row(row, args.mode)
        elif args.suite == "inside":
            harness.run_inside_suite()
        elif args.suite == "soak":
            harness.run_soak_suite()
        else:
            raise SmokeError(f"unknown suite {args.suite}")
    except SmokeError as exc:
        print(str(exc), file=sys.stderr)
        print(f"artifacts: {harness.artifact_dir}", file=sys.stderr)
        return 1
    finally:
        harness.cleanup()

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

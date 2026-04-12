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
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone


ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ARTIFACT_ROOT = pathlib.Path(tempfile.gettempdir()) / "zmux-session-group-lab"
DEFAULT_WORKTREE = ROOT_DIR.parent / "zmux-session-group-lab"
DEFAULT_PARALLEL_TMUX_SESSION = "session-group-parallel-gdb"


def die(message: str) -> "NoReturn":
    print(f"lab: {message}", file=sys.stderr)
    raise SystemExit(1)


def lab_paths(artifact_root: pathlib.Path) -> dict[str, pathlib.Path]:
    return {
        "root": artifact_root,
        "crash": artifact_root / "crash",
        "gdb": artifact_root / "gdb",
        "strace": artifact_root / "strace",
        "patches": artifact_root / "patches",
        "sockets": artifact_root / "sockets",
    }


def manifest_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return artifact_root / "manifest.json"


def current_phase_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return artifact_root / "current-phase.json"


def parallel_session_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return artifact_root / "parallel-session.json"


def latest_crash_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return lab_paths(artifact_root)["crash"] / "latest.json"


def crash_analysis_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return lab_paths(artifact_root)["crash"] / "analysis.txt"


def ensure_artifact_dirs(artifact_root: pathlib.Path) -> None:
    for path in lab_paths(artifact_root).values():
        path.mkdir(parents=True, exist_ok=True)


def run(
    cmd: list[str],
    *,
    cwd: pathlib.Path | None = None,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str] | subprocess.CompletedProcess[bytes]:
    kwargs: dict[str, object] = {
        "cwd": str(cwd) if cwd is not None else None,
        "check": check,
    }
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    return subprocess.run(cmd, **kwargs)


def write_json(path: pathlib.Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def repo_head(root: pathlib.Path) -> str:
    result = run(["git", "rev-parse", "HEAD"], cwd=root, capture=True)
    return result.stdout.strip()


def sanitize_branch_component(name: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip(".-/")
    return value or "session-group-lab"


def default_branch_name(worktree: pathlib.Path) -> str:
    return f"lab/{sanitize_branch_component(worktree.name)}"


def worktree_branch(worktree: pathlib.Path) -> str | None:
    result = run(["git", "branch", "--show-current"], cwd=worktree, capture=True)
    branch = result.stdout.strip()
    return branch or None


def branch_exists(repo_root: pathlib.Path, branch: str) -> bool:
    result = run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=repo_root,
        check=False,
    )
    return result.returncode == 0


def worktree_exists(worktree: pathlib.Path) -> bool:
    return (worktree / ".git").exists()


def ensure_worktree(repo_root: pathlib.Path, worktree: pathlib.Path, branch: str) -> str:
    if worktree_exists(worktree):
        current_branch = worktree_branch(worktree)
        if current_branch is not None:
            return current_branch
        if worktree_dirty(worktree):
            die(f"existing detached worktree is dirty: {worktree}")
        try:
            if branch_exists(repo_root, branch):
                run(["git", "checkout", branch], cwd=worktree)
            else:
                run(["git", "checkout", "-b", branch], cwd=worktree)
        except subprocess.CalledProcessError:
            die(f"unable to attach {worktree} to branch {branch!r}; pass --branch to choose a different breadcrumb")
        return branch

    worktree.parent.mkdir(parents=True, exist_ok=True)
    try:
        if branch_exists(repo_root, branch):
            run(["git", "worktree", "add", str(worktree), branch], cwd=repo_root)
        else:
            run(["git", "worktree", "add", "-b", branch, str(worktree), "HEAD"], cwd=repo_root)
    except subprocess.CalledProcessError:
        die(f"unable to create worktree {worktree} on branch {branch!r}; pass --branch to choose a different breadcrumb")
    return branch


def write_manifest(repo_root: pathlib.Path, artifact_root: pathlib.Path, worktree: pathlib.Path, branch: str) -> None:
    payload = {
        "repo_root": str(repo_root),
        "artifact_root": str(artifact_root),
        "worktree": str(worktree),
        "branch": branch,
        "head": repo_head(repo_root),
    }
    manifest_path(artifact_root).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_manifest(artifact_root: pathlib.Path) -> dict[str, str]:
    path = manifest_path(artifact_root)
    if not path.exists():
        die(f"missing manifest: run setup first ({path})")
    return json.loads(path.read_text(encoding="utf-8"))


def write_current_phase(artifact_root: pathlib.Path, payload: dict[str, object]) -> None:
    current_phase_path(artifact_root).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_current_phase(artifact_root: pathlib.Path) -> dict[str, object]:
    path = current_phase_path(artifact_root)
    if not path.exists():
        die("no current phase metadata; run a phase command first or pass --binary/--socket")
    return json.loads(path.read_text(encoding="utf-8"))


def clear_current_phase(artifact_root: pathlib.Path) -> None:
    path = current_phase_path(artifact_root)
    if path.exists():
        path.unlink()


def write_parallel_session(artifact_root: pathlib.Path, payload: dict[str, object]) -> None:
    parallel_session_path(artifact_root).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_parallel_session(artifact_root: pathlib.Path) -> dict[str, object]:
    path = parallel_session_path(artifact_root)
    if not path.exists():
        die("no parallel session metadata; run parallel-gdb first")
    return json.loads(path.read_text(encoding="utf-8"))


def clear_parallel_session(artifact_root: pathlib.Path) -> None:
    path = parallel_session_path(artifact_root)
    if path.exists():
        path.unlink()


def phase_tag(phase: str, mode: str) -> str:
    return f"{phase}-{mode}"


def phase_socket(artifact_root: pathlib.Path, phase: str, mode: str) -> pathlib.Path:
    return lab_paths(artifact_root)["sockets"] / f"{phase_tag(phase, mode)}.sock"


def line_number(path: pathlib.Path, needle: str) -> int:
    with path.open("r", encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            if needle in line:
                return lineno
    die(f"unable to find marker {needle!r} in {path}")


def anchor_locations(worktree: pathlib.Path) -> dict[str, dict[str, str]]:
    control_line = line_number(worktree / "src" / "control.zig", "pub fn control_read_callback(cl: *T.Client, line: []const u8) void {")
    new_session_line = line_number(worktree / "src" / "cmd-new-session.zig", "fn exec_new_session(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {")
    switch_line = line_number(worktree / "src" / "cmd-switch-client.zig", "fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {")
    select_line = line_number(worktree / "src" / "cmd-select-window.zig", "fn exec_selectw(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {")
    return {
        "control_read_callback": {
            "zmux": f"{worktree / 'src' / 'control.zig'}:{control_line}",
            "tmux": "control_read_callback",
        },
        "exec_new_session": {
            "zmux": f"{worktree / 'src' / 'cmd-new-session.zig'}:{new_session_line}",
            "tmux": "cmd_new_session_exec",
        },
        "server_client_set_session": {
            "zmux": "server_client_set_session",
            "tmux": "server_client_set_session",
        },
        "resolve_current_state": {
            "zmux": "resolve_current_state",
            "tmux": "cmd_find_target",
        },
        "cmd_find_target": {
            "zmux": "cmd_find_target",
            "tmux": "cmd_find_target",
        },
        "cmd_switch_client": {
            "zmux": f"{worktree / 'src' / 'cmd-switch-client.zig'}:{switch_line}",
            "tmux": "cmd_switch_client_exec",
        },
        "cmd_select_window": {
            "zmux": f"{worktree / 'src' / 'cmd-select-window.zig'}:{select_line}",
            "tmux": "cmd_select_window_exec",
        },
    }


def default_anchor_order() -> list[str]:
    return [
        "control_read_callback",
        "exec_new_session",
        "cmd_switch_client",
        "cmd_select_window",
        "server_client_set_session",
        "resolve_current_state",
        "cmd_find_target",
    ]


def crash_comment_lines(side: str, analysis: dict[str, object] | None, anchor_name: str | None) -> list[str]:
    if not analysis:
        return []

    lines = ["echo Crash replay context loaded.\\n"]
    crash_signal = analysis.get("signal")
    crash_site = analysis.get("crash_site")
    selected_anchor = anchor_name or analysis.get("default_anchor")
    if crash_signal:
        lines.append(f"echo Signal: {crash_signal}\\n")
    if crash_site:
        lines.append(f"echo Crash site: {crash_site}\\n")
    if selected_anchor:
        lines.append(f"echo Replay anchor: {selected_anchor}\\n")

    selected = None
    if side == "zmux":
        selected = analysis.get("app_frame") or analysis.get("caller_frame")
    else:
        selected = analysis.get("tmux_counterpart")

    if isinstance(selected, dict):
        func = selected.get("function")
        location = selected.get("location")
        if func:
            lines.append(f"echo Frame: {func}\\n")
        if location:
            lines.append(f"echo Location: {location}\\n")

    excerpt = analysis.get("conditional_excerpt")
    if isinstance(excerpt, list) and excerpt:
        lines.append("echo Captured locals/args follow in comments.\\n")
        for item in excerpt[:4]:
            safe = str(item).replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'echo {safe}\\n')
        lines.append("echo Example condition template: break <bpnum> if /* use captured values above */\\n")
    return lines


def write_zmux_gdb_script(
    worktree: pathlib.Path,
    artifact_root: pathlib.Path,
    mode: str,
    *,
    anchor_name: str | None = None,
    analysis: dict[str, object] | None = None,
) -> pathlib.Path:
    script_path = lab_paths(artifact_root)["gdb"] / f"{phase_tag('phase1-zmux-gdb', mode)}.gdb"
    anchors = anchor_locations(worktree)
    lines = [
        "set pagination off",
        "set breakpoint pending on",
        "set print pretty on",
        "set debuginfod enabled off",
        "handle SIGPIPE nostop noprint pass",
        "echo Loaded zmux session-group handoff breakpoint set.\\n",
        "echo Recommended on stop: bt 8 ; info args ; info locals\\n",
    ]
    lines.extend(crash_comment_lines("zmux", analysis, anchor_name))
    if anchor_name is None and analysis is None:
        for key in default_anchor_order():
            lines.append(f"break {anchors[key]['zmux']}")
    else:
        selected = anchor_name
        if selected is None and analysis is not None:
            value = analysis.get("default_anchor")
            selected = str(value) if value else None
        if selected and selected in anchors:
            lines.append(f"tbreak {anchors[selected]['zmux']}")
        app_frame = analysis.get("app_frame") if analysis else None
        caller_frame = analysis.get("caller_frame") if analysis else None
        for frame in (app_frame, caller_frame):
            if isinstance(frame, dict):
                frame_anchor = frame.get("anchor")
                if isinstance(frame_anchor, str) and frame_anchor in anchors:
                    lines.append(f"tbreak {anchors[frame_anchor]['zmux']}")
    lines.append("echo # condition example: break <bpnum> if /* use captured values above */\\n")
    script_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return script_path


def write_tmux_gdb_script(
    worktree: pathlib.Path,
    artifact_root: pathlib.Path,
    mode: str,
    *,
    anchor_name: str | None = None,
    analysis: dict[str, object] | None = None,
) -> pathlib.Path:
    script_path = lab_paths(artifact_root)["gdb"] / f"{phase_tag('phase2-tmux-gdb', mode)}.gdb"
    anchors = anchor_locations(worktree)
    lines = [
        "set pagination off",
        "set breakpoint pending on",
        "set print pretty on",
        "set debuginfod enabled off",
        "handle SIGPIPE nostop noprint pass",
        "echo Loaded tmux session-group handoff breakpoint set.\\n",
        "echo Recommended on stop: bt 8 ; info args ; info locals\\n",
    ]
    lines.extend(crash_comment_lines("tmux", analysis, anchor_name))
    if anchor_name is None and analysis is None:
        for key in default_anchor_order():
            lines.append(f"break {anchors[key]['tmux']}")
    else:
        selected = anchor_name
        if selected is None and analysis is not None:
            value = analysis.get("default_anchor")
            selected = str(value) if value else None
        if selected and selected in anchors:
            lines.append(f"tbreak {anchors[selected]['tmux']}")
        counterpart = analysis.get("tmux_counterpart") if analysis else None
        if isinstance(counterpart, dict):
            counterpart_anchor = counterpart.get("anchor")
            if isinstance(counterpart_anchor, str) and counterpart_anchor in anchors:
                lines.append(f"tbreak {anchors[counterpart_anchor]['tmux']}")
        elif analysis:
            lines.append("echo No direct tmux counterpart was inferred for the crash frame.\\n")
    lines.append("echo # condition example: break <bpnum> if /* use captured values above */\\n")
    script_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return script_path


def build_zmux_debug(worktree: pathlib.Path) -> pathlib.Path:
    run(["zig", "build", "-Doptimize=Debug"], cwd=worktree)
    binary = worktree / "zig-out" / "bin" / "zmux"
    if not binary.exists():
        die(f"expected zmux debug binary at {binary}")
    return binary


def build_tmux_debug(worktree: pathlib.Path) -> pathlib.Path:
    (worktree / "tmux-museum" / "build").mkdir(parents=True, exist_ok=True)
    (worktree / "tmux-museum" / "out").mkdir(parents=True, exist_ok=True)
    run(["tmux-museum/bin/refresh-museum.sh", "gdb"], cwd=worktree)
    binary = worktree / "tmux-museum" / "out" / "gdb" / "tmux"
    if not binary.exists():
        die(f"expected tmux debug binary at {binary}")
    return binary


def driver_command(worktree: pathlib.Path, binary: pathlib.Path, socket: pathlib.Path, artifact_root: pathlib.Path, mode: str) -> list[str]:
    return [
        str(worktree / "regress" / "session-group-drive.sh"),
        mode,
        "--binary",
        str(binary),
        "--socket",
        str(socket),
        "--artifact-root",
        str(artifact_root),
    ]


def print_phase_summary(phase: dict[str, object]) -> None:
    print(f"phase: {phase['phase']}")
    print(f"mode: {phase['mode']}")
    print(f"worktree: {phase['worktree']}")
    print(f"binary: {phase['binary']}")
    print(f"socket: {phase['socket']}")
    if "gdb_script" in phase:
        print(f"gdb script: {phase['gdb_script']}")
    if "strace_prefix" in phase:
        print(f"strace prefix: {phase['strace_prefix']}")
    print("driver:")
    print(f"  {phase['driver_command']}")
    print("wind-down:")
    print(f"  {phase['wind_down_command']}")


def print_parallel_summary(payload: dict[str, object]) -> None:
    print("parallel session:")
    print(f"  tmux session: {payload['tmux_session']}")
    print(f"  mode: {payload['mode']}")
    print(f"  worktree: {payload['worktree']}")
    print("attach:")
    print(f"  {payload['attach_command']}")
    print("runz:")
    print(f"  {payload['runz_command']}")
    print("runt:")
    print(f"  {payload['runt_command']}")
    print("wind-down:")
    print(f"  {payload['wind_down_command']}")


def save_patch(worktree: pathlib.Path, artifact_root: pathlib.Path, label: str) -> pathlib.Path | None:
    diff = subprocess.run(
        ["git", "-C", str(worktree), "diff", "--binary"],
        check=True,
        capture_output=True,
    ).stdout
    if not diff:
        return None
    path = lab_paths(artifact_root)["patches"] / f"{label}.patch"
    path.write_bytes(diff)
    return path


def phase_metadata(
    *,
    artifact_root: pathlib.Path,
    worktree: pathlib.Path,
    phase: str,
    mode: str,
    binary: pathlib.Path,
    socket: pathlib.Path,
    driver_cmd: list[str],
    extra: dict[str, object] | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "artifact_root": str(artifact_root),
        "binary": str(binary),
        "driver_command": shlex.join(driver_cmd),
        "mode": mode,
        "phase": phase,
        "socket": str(socket),
        "wind_down_command": shlex.join(
            [
                sys.executable,
                str(ROOT_DIR / "regress" / "session-group-lab.py"),
                "--artifact-root",
                str(artifact_root),
                "wind-down",
            ]
        ),
        "worktree": str(worktree),
    }
    if extra:
        payload.update(extra)
    return payload


def tmux_has_session(session_name: str) -> bool:
    result = subprocess.run(
        ["tmux", "has-session", "-t", session_name],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def tmux_kill_session(session_name: str) -> None:
    if tmux_has_session(session_name):
        subprocess.run(
            ["tmux", "kill-session", "-t", session_name],
            check=False,
            capture_output=True,
            text=True,
        )


def tmux_send_keys(target: str, *keys: str) -> None:
    run(["tmux", "send-keys", "-t", target, *keys])


def tmux_current_pane_id(target: str) -> str:
    result = run(["tmux", "display-message", "-p", "-t", target, "#{pane_id}"], capture=True)
    pane_id = result.stdout.strip()
    if not pane_id:
        die(f"unable to resolve current pane for tmux target {target!r}")
    return pane_id


def tmux_split_window(target: str) -> str:
    result = run(["tmux", "split-window", "-h", "-P", "-F", "#{pane_id}", "-t", target], capture=True)
    pane_id = result.stdout.strip()
    if not pane_id:
        die(f"unable to create split pane for tmux target {target!r}")
    return pane_id


def coredumpctl_usable() -> bool:
    if shutil.which("coredumpctl") is None:
        return False
    result = subprocess.run(
        ["coredumpctl", "--no-pager", "--json=short", "list", "-n", "1"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def coredump_entries(binary: pathlib.Path) -> list[dict[str, object]]:
    result = subprocess.run(
        ["coredumpctl", "--no-pager", "--json=short", "list", f"EXE={binary}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    stdout = result.stdout.strip()
    if not stdout:
        return []
    data = json.loads(stdout)
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


def coredump_key(entry: dict[str, object]) -> tuple[object, ...]:
    return (
        entry.get("time"),
        entry.get("pid"),
        entry.get("sig"),
        entry.get("exe"),
    )


def coredump_info_text(entry: dict[str, object]) -> str:
    pid = str(entry["pid"])
    exe = str(entry["exe"])
    result = run(
        ["coredumpctl", "--no-pager", "info", f"PID={pid}", f"EXE={exe}"],
        capture=True,
    )
    return result.stdout


def dump_coredump(entry: dict[str, object], core_path: pathlib.Path) -> None:
    subprocess.run(
        [
            "coredumpctl",
            "--no-pager",
            "dump",
            "-o",
            str(core_path),
            f"PID={entry['pid']}",
            f"EXE={entry['exe']}",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def wait_for_socket(socket: pathlib.Path, proc: subprocess.Popen[str] | None = None, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if socket.exists():
            return True
        if proc is not None and proc.poll() is not None:
            return False
        time.sleep(0.05)
    return socket.exists()


def parse_driver_temp_dir(stderr_text: str) -> str | None:
    match = re.search(r"artifacts kept in (\S+)", stderr_text)
    if match:
        return match.group(1)
    return None


def gdb_batch_commands(extra: list[str]) -> list[str]:
    commands = [
        "gdb",
        "-q",
        "-batch",
        "-iex",
        "set debuginfod enabled off",
        "-iex",
        "set pagination off",
        "-iex",
        "set confirm off",
        "-ex",
        "handle SIGPIPE nostop noprint pass",
    ]
    for cmd in extra:
        commands.extend(["-ex", cmd])
    return commands


def parse_gdb_frames(text: str) -> list[dict[str, object]]:
    frames: list[dict[str, object]] = []
    pattern = re.compile(r"^#(?P<index>\d+)\s+(?P<body>.*)$")
    for line in text.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        body = match.group("body")
        func_match = re.search(r"\bin\s+([^(]+)", body)
        if func_match:
            function = func_match.group(1).strip()
        else:
            function = body.split("(", 1)[0].strip()
        frames.append(
            {
                "index": int(match.group("index")),
                "function": function,
                "raw": line,
            }
        )
    return frames


def gdb_frame_snapshot(binary: pathlib.Path, frame_index: int, core_path: pathlib.Path | None = None) -> str:
    cmd = gdb_batch_commands(
        [
            f"frame {frame_index}",
            "info line",
            "info args",
            "info locals",
        ]
    )
    cmd.extend([str(binary)])
    if core_path is not None:
        cmd.append(str(core_path))
    result = run(cmd, capture=True)
    return result.stdout


def frame_location_from_snapshot(snapshot: str) -> str | None:
    for line in snapshot.splitlines():
        match = re.search(r'Line \d+ of "([^"]+)"', line)
        if match:
            return match.group(1)
    return None


def frame_anchor(function: str, location: str | None) -> str | None:
    if location:
        path = pathlib.Path(location)
        name = path.name
        if name == "control.zig":
            return "control_read_callback"
        if name == "cmd-new-session.zig":
            return "exec_new_session"
        if name == "cmd-switch-client.zig":
            return "cmd_switch_client"
        if name == "cmd-select-window.zig":
            return "cmd_select_window"
        if name == "cmd-find.zig":
            if "resolve_current_state" in function:
                return "resolve_current_state"
            return "cmd_find_target"
        if name == "server-client.zig":
            return "server_client_set_session"
    if "control_read_callback" in function:
        return "control_read_callback"
    if "exec_new_session" in function or "cmd_new_session_exec" in function:
        return "exec_new_session"
    if "server_client_set_session" in function:
        return "server_client_set_session"
    if "resolve_current_state" in function:
        return "resolve_current_state"
    if "cmd_find_target" in function:
        return "cmd_find_target"
    if "cmd_switch_client" in function:
        return "cmd_switch_client"
    if "cmd_select_window" in function or "exec_selectw" in function:
        return "cmd_select_window"
    return None


def runtime_frame(function: str, raw: str, location: str | None) -> bool:
    if location and "/src/" in location:
        return False
    runtime_prefixes = (
        "pthread_",
        "raise",
        "abort",
        "__libc_start_main",
        "_start",
        "posix.abort",
        "debug.defaultPanic",
        "callMain",
        "start.main",
    )
    if function.startswith(runtime_prefixes):
        return True
    return " from /usr/lib/" in raw or "libc.so" in raw


def extract_conditional_excerpt(snapshot: str) -> list[str]:
    lines: list[str] = []
    for line in snapshot.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[New LWP "):
            continue
        if stripped.startswith("[Thread debugging using "):
            continue
        if stripped.startswith("Using host libthread_db library"):
            continue
        if stripped.startswith("Core was generated by "):
            continue
        if "debuginfod" in stripped.lower():
            continue
        if stripped.startswith("This GDB supports auto-downloading debuginfo"):
            continue
        if stripped.startswith("Enable debuginfod for this session?"):
            continue
        if stripped.startswith("No locals.") or stripped.startswith("No arguments."):
            continue
        if stripped.startswith("Stack level") or stripped.startswith("Line "):
            continue
        lines.append(stripped)
    return lines[:6]


def latest_crash_manifest(artifact_root: pathlib.Path) -> dict[str, object]:
    path = latest_crash_path(artifact_root)
    if not path.exists():
        die("no crash manifest; run capture-crash first")
    return json.loads(path.read_text(encoding="utf-8"))


def stop_parallel_session(artifact_root: pathlib.Path) -> list[str]:
    messages: list[str] = []
    path = parallel_session_path(artifact_root)
    if not path.exists():
        return messages

    payload = json.loads(path.read_text(encoding="utf-8"))
    for prefix in ("zmux", "tmux"):
        binary = pathlib.Path(str(payload[f"{prefix}_binary"]))
        socket = pathlib.Path(str(payload[f"{prefix}_socket"]))
        kill_server(binary, socket)
        messages.append(f"killed {prefix} server on {socket} (best effort)")

    session_name = str(payload["tmux_session"])
    if tmux_has_session(session_name):
        tmux_kill_session(session_name)
        messages.append(f"killed tmux session {session_name}")

    clear_parallel_session(artifact_root)
    return messages


def shell_command(worktree: pathlib.Path, argv: list[str]) -> str:
    return f"cd {shlex.quote(str(worktree))} && exec {shlex.join(argv)}"


def preload_command(worktree: pathlib.Path, argv: list[str]) -> str:
    return f"cd {shlex.quote(str(worktree))} && {shlex.join(argv)}"


def parallel_session_metadata(
    *,
    artifact_root: pathlib.Path,
    worktree: pathlib.Path,
    mode: str,
    tmux_session: str,
    zmux_binary: pathlib.Path,
    zmux_socket: pathlib.Path,
    zmux_gdb_script: pathlib.Path,
    zmux_driver_cmd: list[str],
    tmux_binary: pathlib.Path,
    tmux_socket: pathlib.Path,
    tmux_gdb_script: pathlib.Path,
    tmux_driver_cmd: list[str],
) -> dict[str, object]:
    return {
        "artifact_root": str(artifact_root),
        "mode": mode,
        "worktree": str(worktree),
        "tmux_session": tmux_session,
        "attach_command": shlex.join(["tmux", "attach-session", "-t", tmux_session]),
        "runz_command": preload_command(worktree, zmux_driver_cmd),
        "runt_command": preload_command(worktree, tmux_driver_cmd),
        "wind_down_command": shlex.join(
            [
                sys.executable,
                str(ROOT_DIR / "regress" / "session-group-lab.py"),
                "--artifact-root",
                str(artifact_root),
                "wind-down",
            ]
        ),
        "zmux_binary": str(zmux_binary),
        "zmux_socket": str(zmux_socket),
        "zmux_gdb_script": str(zmux_gdb_script),
        "zmux_driver_command": shlex.join(zmux_driver_cmd),
        "tmux_binary": str(tmux_binary),
        "tmux_socket": str(tmux_socket),
        "tmux_gdb_script": str(tmux_gdb_script),
        "tmux_driver_command": shlex.join(tmux_driver_cmd),
    }


def start_parallel_tmux_session(
    *,
    worktree: pathlib.Path,
    payload: dict[str, object],
) -> None:
    session_name = str(payload["tmux_session"])
    tmux_kill_session(session_name)

    run(["tmux", "new-session", "-d", "-s", session_name, "-n", "gdb"])
    zmux_gdb_pane = tmux_current_pane_id(f"{session_name}:gdb")
    tmux_send_keys(
        zmux_gdb_pane,
        shell_command(worktree, [
            "gdb",
            "-q",
            "-x",
            str(payload["zmux_gdb_script"]),
            "--args",
            str(payload["zmux_binary"]),
            "-D",
            "-vv",
            "-f/dev/null",
            "-S",
            str(payload["zmux_socket"]),
        ]),
        "C-m",
    )
    tmux_gdb_pane = tmux_split_window(zmux_gdb_pane)
    tmux_send_keys(
        tmux_gdb_pane,
        shell_command(worktree, [
            "gdb",
            "-q",
            "-x",
            str(payload["tmux_gdb_script"]),
            "--args",
            str(payload["tmux_binary"]),
            "-D",
            "-vv",
            "-f/dev/null",
            "-S",
            str(payload["tmux_socket"]),
        ]),
        "C-m",
    )
    run(["tmux", "select-layout", "-t", f"{session_name}:gdb", "even-horizontal"])

    run(["tmux", "new-window", "-t", session_name, "-n", "drive"])
    zmux_drive_pane = tmux_current_pane_id(f"{session_name}:drive")
    tmux_drive_pane = tmux_split_window(zmux_drive_pane)
    run(["tmux", "select-layout", "-t", f"{session_name}:drive", "even-horizontal"])
    tmux_send_keys(zmux_drive_pane, str(payload["runz_command"]))
    tmux_send_keys(tmux_drive_pane, str(payload["runt_command"]))
    run(["tmux", "select-window", "-t", f"{session_name}:gdb"])


def crash_run_dir(artifact_root: pathlib.Path, run_index: int) -> pathlib.Path:
    return lab_paths(artifact_root)["crash"] / f"run-{run_index:03d}"


def crash_driver_command(worktree: pathlib.Path, binary: pathlib.Path, socket: pathlib.Path, artifact_root: pathlib.Path, mode: str) -> list[str]:
    cmd = driver_command(worktree, binary, socket, artifact_root, mode)
    cmd.append("--keep-temp")
    return cmd


def coredump_capture(
    *,
    worktree: pathlib.Path,
    artifact_root: pathlib.Path,
    binary: pathlib.Path,
    mode: str,
    runs: int,
) -> dict[str, object]:
    baseline = {coredump_key(entry) for entry in coredump_entries(binary)}
    crash_root = lab_paths(artifact_root)["crash"]
    attempts: list[dict[str, object]] = []
    for run_index in range(1, runs + 1):
        run_dir = crash_run_dir(artifact_root, run_index)
        run_dir.mkdir(parents=True, exist_ok=True)
        socket = run_dir / "server.sock"
        driver_cmd = crash_driver_command(worktree, binary, socket, artifact_root, mode)
        started_at = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(driver_cmd, cwd=worktree, capture_output=True, text=True)
        stdout_path = run_dir / "driver.stdout"
        stderr_path = run_dir / "driver.stderr"
        stdout_path.write_text(result.stdout, encoding="utf-8")
        stderr_path.write_text(result.stderr, encoding="utf-8")
        kill_server(binary, socket)
        entries = coredump_entries(binary)
        new_entries = [entry for entry in entries if coredump_key(entry) not in baseline]
        if new_entries:
            baseline.update(coredump_key(entry) for entry in new_entries)
        attempt: dict[str, object] = {
            "run": run_index,
            "started_at": started_at,
            "returncode": result.returncode,
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "socket": str(socket),
        }
        driver_temp_dir = parse_driver_temp_dir(result.stderr)
        if driver_temp_dir:
            attempt["driver_temp_dir"] = driver_temp_dir
        if new_entries:
            entry = sorted(new_entries, key=lambda item: int(item.get("time", 0)))[-1]
            info_text = coredump_info_text(entry)
            info_path = run_dir / "coredumpctl-info.txt"
            info_path.write_text(info_text, encoding="utf-8")
            core_path = crash_root / "latest.core"
            dump_coredump(entry, core_path)
            attempt["coredump"] = entry
            manifest = {
                "backend": "coredumpctl",
                "binary": str(binary),
                "mode": mode,
                "runs": runs,
                "crash_found": True,
                "run": run_index,
                "run_dir": str(run_dir),
                "driver_command": shlex.join(driver_cmd),
                "driver_temp_dir": driver_temp_dir,
                "driver_stdout": str(stdout_path),
                "driver_stderr": str(stderr_path),
                "socket": str(socket),
                "signal": entry.get("sig"),
                "coredump": entry,
                "coredump_info": str(info_path),
                "core_path": str(core_path),
                "attempts": attempts + [attempt],
            }
            write_json(latest_crash_path(artifact_root), manifest)
            return manifest
        attempts.append(attempt)

    manifest = {
        "backend": "coredumpctl",
        "binary": str(binary),
        "mode": mode,
        "runs": runs,
        "crash_found": False,
        "attempts": attempts,
    }
    write_json(latest_crash_path(artifact_root), manifest)
    return manifest


def gdb_capture(
    *,
    worktree: pathlib.Path,
    artifact_root: pathlib.Path,
    binary: pathlib.Path,
    mode: str,
    runs: int,
) -> dict[str, object]:
    attempts: list[dict[str, object]] = []
    for run_index in range(1, runs + 1):
        run_dir = crash_run_dir(artifact_root, run_index)
        run_dir.mkdir(parents=True, exist_ok=True)
        socket = run_dir / "server.sock"
        gdb_output = run_dir / "gdb-batch.txt"
        driver_cmd = crash_driver_command(worktree, binary, socket, artifact_root, mode)
        started_at = datetime.now(timezone.utc).isoformat()
        gdb_cmd = gdb_batch_commands(
            [
                "run",
                "echo \\n--- crash backtrace ---\\n",
                "thread apply all bt full",
                "echo \\n--- end crash backtrace ---\\n",
            ]
        )
        gdb_cmd.extend(
            [
                "--args",
                str(binary),
                "-D",
                "-vv",
                "-f/dev/null",
                "-S",
                str(socket),
            ]
        )
        with gdb_output.open("w", encoding="utf-8") as handle:
            proc = subprocess.Popen(
                gdb_cmd,
                cwd=worktree,
                stdout=handle,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if not wait_for_socket(socket, proc):
                proc.wait(timeout=5)
                gdb_text = gdb_output.read_text(encoding="utf-8", errors="replace")
                attempt = {
                    "run": run_index,
                    "started_at": started_at,
                    "gdb_output": str(gdb_output),
                    "socket": str(socket),
                    "startup_failed": True,
                }
                attempts.append(attempt)
                continue
            result = subprocess.run(driver_cmd, cwd=worktree, capture_output=True, text=True)
            stdout_path = run_dir / "driver.stdout"
            stderr_path = run_dir / "driver.stderr"
            stdout_path.write_text(result.stdout, encoding="utf-8")
            stderr_path.write_text(result.stderr, encoding="utf-8")
            kill_server(binary, socket)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)

        gdb_text = gdb_output.read_text(encoding="utf-8", errors="replace")
        signal_match = re.search(r"Program terminated with signal ([A-Z0-9]+)", gdb_text)
        attempt = {
            "run": run_index,
            "started_at": started_at,
            "returncode": result.returncode,
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "socket": str(socket),
            "gdb_output": str(gdb_output),
        }
        driver_temp_dir = parse_driver_temp_dir(result.stderr)
        if driver_temp_dir:
            attempt["driver_temp_dir"] = driver_temp_dir
        if signal_match:
            manifest = {
                "backend": "gdb-batch",
                "binary": str(binary),
                "mode": mode,
                "runs": runs,
                "crash_found": True,
                "run": run_index,
                "run_dir": str(run_dir),
                "driver_command": shlex.join(driver_cmd),
                "driver_temp_dir": driver_temp_dir,
                "driver_stdout": str(stdout_path),
                "driver_stderr": str(stderr_path),
                "socket": str(socket),
                "signal": signal_match.group(1),
                "gdb_output": str(gdb_output),
                "attempts": attempts + [attempt],
            }
            write_json(latest_crash_path(artifact_root), manifest)
            return manifest
        attempts.append(attempt)

    manifest = {
        "backend": "gdb-batch",
        "binary": str(binary),
        "mode": mode,
        "runs": runs,
        "crash_found": False,
        "attempts": attempts,
    }
    write_json(latest_crash_path(artifact_root), manifest)
    return manifest


def capture_crash_manifest(worktree: pathlib.Path, artifact_root: pathlib.Path, mode: str, runs: int, backend: str) -> dict[str, object]:
    binary = build_zmux_debug(worktree)
    if backend == "auto":
        backend = "coredumpctl" if coredumpctl_usable() else "gdb"
    if backend == "coredumpctl":
        return coredump_capture(worktree=worktree, artifact_root=artifact_root, binary=binary, mode=mode, runs=runs)
    if backend == "gdb":
        return gdb_capture(worktree=worktree, artifact_root=artifact_root, binary=binary, mode=mode, runs=runs)
    die(f"unknown crash backend: {backend}")


def crash_gdb_backtrace(binary: pathlib.Path, core_path: pathlib.Path | None = None) -> str:
    cmd = gdb_batch_commands(["bt 32"])
    cmd.append(str(binary))
    if core_path is not None:
        cmd.append(str(core_path))
    result = run(cmd, capture=True)
    return result.stdout


def crash_gdb_full(binary: pathlib.Path, core_path: pathlib.Path | None = None) -> str:
    cmd = gdb_batch_commands(["thread apply all bt full"])
    cmd.append(str(binary))
    if core_path is not None:
        cmd.append(str(core_path))
    result = run(cmd, capture=True)
    return result.stdout


def analyze_crash_manifest(artifact_root: pathlib.Path, manifest: dict[str, object]) -> dict[str, object]:
    if not manifest.get("crash_found"):
        die("latest capture did not record a crash")

    binary = pathlib.Path(str(manifest["binary"]))
    core_path = pathlib.Path(str(manifest["core_path"])) if "core_path" in manifest else None
    if core_path is not None and not core_path.exists():
        coredump = manifest.get("coredump")
        if isinstance(coredump, dict):
            dump_coredump(coredump, core_path)

    if core_path is not None:
        bt_text = crash_gdb_backtrace(binary, core_path)
        full_text = crash_gdb_full(binary, core_path)
    else:
        gdb_output_path = pathlib.Path(str(manifest["gdb_output"]))
        bt_text = gdb_output_path.read_text(encoding="utf-8", errors="replace")
        full_text = bt_text
    bt_path = lab_paths(artifact_root)["crash"] / "backtrace.txt"
    bt_path.write_text(bt_text, encoding="utf-8")
    full_path = lab_paths(artifact_root)["crash"] / "backtrace-full.txt"
    full_path.write_text(full_text, encoding="utf-8")

    frames = parse_gdb_frames(bt_text)
    frame_details: list[dict[str, object]] = []
    for frame in frames:
        snapshot = ""
        location = None
        if core_path is not None:
            snapshot = gdb_frame_snapshot(binary, int(frame["index"]), core_path)
            location = frame_location_from_snapshot(snapshot)
        anchor = frame_anchor(str(frame["function"]), location)
        frame_details.append(
            {
                **frame,
                "location": location,
                "anchor": anchor,
                "snapshot": snapshot,
            }
        )

    app_frame = None
    for frame in frame_details:
        if runtime_frame(str(frame["function"]), str(frame["raw"]), frame.get("location")):
            continue
        app_frame = frame
        break
    if app_frame is None:
        die("unable to identify application frame from crash backtrace")

    caller_frame = None
    for frame in frame_details:
        if int(frame["index"]) == int(app_frame["index"]) + 1:
            caller_frame = frame
            break

    default_anchor = app_frame.get("anchor") or (caller_frame.get("anchor") if isinstance(caller_frame, dict) else None)
    counterpart = None
    if isinstance(default_anchor, str):
        tmux_target = anchor_locations(pathlib.Path(load_manifest(artifact_root)["worktree"])).get(default_anchor, {}).get("tmux")
        if tmux_target:
            counterpart = {"anchor": default_anchor, "location": tmux_target}

    conditional_excerpt = extract_conditional_excerpt(str(app_frame["snapshot"]))
    analysis = {
        "backend": manifest["backend"],
        "signal": manifest.get("signal"),
        "binary": str(binary),
        "core_path": str(core_path) if core_path is not None else None,
        "backtrace_path": str(bt_path),
        "backtrace_full_path": str(full_path),
        "crash_site": str(frame_details[0]["raw"]) if frame_details else None,
        "app_frame": {
            "index": app_frame["index"],
            "function": app_frame["function"],
            "raw": app_frame["raw"],
            "location": app_frame.get("location"),
            "anchor": app_frame.get("anchor"),
        },
        "caller_frame": {
            "index": caller_frame["index"],
            "function": caller_frame["function"],
            "raw": caller_frame["raw"],
            "location": caller_frame.get("location"),
            "anchor": caller_frame.get("anchor"),
        } if caller_frame is not None else None,
        "default_anchor": default_anchor,
        "tmux_counterpart": counterpart,
        "conditional_excerpt": conditional_excerpt,
    }

    summary_lines = [
        f"backend: {analysis['backend']}",
        f"signal: {analysis.get('signal')}",
        f"crash site: {analysis.get('crash_site')}",
        f"default anchor: {analysis.get('default_anchor')}",
        "",
        "application frame:",
        str(analysis["app_frame"]["raw"]),
        f"location: {analysis['app_frame'].get('location')}",
        "",
        "caller frame:",
        str(analysis["caller_frame"]["raw"]) if analysis["caller_frame"] else "(none)",
    ]
    if analysis["caller_frame"]:
        summary_lines.append(f"location: {analysis['caller_frame'].get('location')}")
    if conditional_excerpt:
        summary_lines.extend(["", "captured locals/args:"])
        summary_lines.extend(conditional_excerpt)
    crash_analysis_path(artifact_root).write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    write_json(lab_paths(artifact_root)["crash"] / "analysis.json", analysis)
    return analysis


def cmd_setup(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = args.worktree.resolve()
    requested_branch = args.branch or default_branch_name(worktree)
    ensure_artifact_dirs(artifact_root)
    branch = ensure_worktree(ROOT_DIR, worktree, requested_branch)
    write_manifest(ROOT_DIR, artifact_root, worktree, branch)
    print(f"artifact root: {artifact_root}")
    print(f"worktree: {worktree}")
    print(f"branch: {branch}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    manifest = load_manifest(artifact_root)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    worktree = pathlib.Path(manifest["worktree"])
    status = run(["git", "status", "--short"], cwd=worktree, capture=True)
    branch = worktree_branch(worktree)
    print("--- worktree branch ---")
    print(branch or "(detached HEAD)")
    print("--- worktree status ---")
    print(status.stdout.rstrip() or "(clean)")
    current = current_phase_path(artifact_root)
    print("--- current phase ---")
    if current.exists():
        print(current.read_text(encoding="utf-8").rstrip())
    else:
        print("(none)")
    parallel = parallel_session_path(artifact_root)
    print("--- parallel session ---")
    if parallel.exists():
        print(parallel.read_text(encoding="utf-8").rstrip())
    else:
        print("(none)")
    crash = latest_crash_path(artifact_root)
    print("--- latest crash ---")
    if crash.exists():
        print(crash.read_text(encoding="utf-8").rstrip())
    else:
        print("(none)")
    analysis = crash_analysis_path(artifact_root)
    print("--- crash analysis ---")
    if analysis.exists():
        print(analysis.read_text(encoding="utf-8").rstrip())
    else:
        print("(none)")
    return 0


def cmd_phase1_zmux_gdb(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    binary = build_zmux_debug(worktree)
    socket = phase_socket(artifact_root, "phase1-zmux-gdb", args.mode)
    gdb_script = write_zmux_gdb_script(worktree, artifact_root, args.mode)
    driver_cmd = driver_command(worktree, binary, socket, artifact_root, args.mode)
    payload = phase_metadata(
        artifact_root=artifact_root,
        worktree=worktree,
        phase="phase1-zmux-gdb",
        mode=args.mode,
        binary=binary,
        socket=socket,
        driver_cmd=driver_cmd,
        extra={"gdb_script": str(gdb_script)},
    )
    write_current_phase(artifact_root, payload)
    print_phase_summary(payload)
    if args.run:
        os.chdir(worktree)
        os.execvp(
            "gdb",
            [
                "gdb",
                "-q",
                "-x",
                str(gdb_script),
                "--args",
                str(binary),
                "-D",
                "-vv",
                "-f/dev/null",
                "-S",
                str(socket),
            ],
        )
    return 0


def cmd_phase2_tmux_gdb(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    binary = build_tmux_debug(worktree)
    socket = phase_socket(artifact_root, "phase2-tmux-gdb", args.mode)
    gdb_script = write_tmux_gdb_script(worktree, artifact_root, args.mode)
    driver_cmd = driver_command(worktree, binary, socket, artifact_root, args.mode)
    payload = phase_metadata(
        artifact_root=artifact_root,
        worktree=worktree,
        phase="phase2-tmux-gdb",
        mode=args.mode,
        binary=binary,
        socket=socket,
        driver_cmd=driver_cmd,
        extra={"gdb_script": str(gdb_script)},
    )
    write_current_phase(artifact_root, payload)
    print_phase_summary(payload)
    if args.run:
        os.chdir(worktree)
        os.execvp(
            "gdb",
            [
                "gdb",
                "-q",
                "-x",
                str(gdb_script),
                "--args",
                str(binary),
                "-D",
                "-vv",
                "-f/dev/null",
                "-S",
                str(socket),
            ],
        )
    return 0


def cmd_parallel_gdb(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    manifest = load_manifest(artifact_root)
    worktree = pathlib.Path(manifest["worktree"])

    for message in stop_parallel_session(artifact_root):
        print(message)

    tmux_session = args.tmux_session
    if tmux_has_session(tmux_session):
        tmux_kill_session(tmux_session)

    analysis = None
    anchor_name = args.anchor
    mode = args.mode or "switch-only"
    if args.from_crash:
        crash_manifest = latest_crash_manifest(artifact_root)
        analysis = analyze_crash_manifest(artifact_root, crash_manifest)
        if args.mode is None:
            mode = str(crash_manifest.get("mode", "switch-only"))
        if anchor_name is None:
            value = analysis.get("default_anchor")
            anchor_name = str(value) if value else None

    zmux_binary = build_zmux_debug(worktree)
    tmux_binary = build_tmux_debug(worktree)
    zmux_socket = phase_socket(artifact_root, "parallel-zmux-gdb", mode)
    tmux_socket = phase_socket(artifact_root, "parallel-tmux-gdb", mode)
    zmux_gdb_script = write_zmux_gdb_script(worktree, artifact_root, mode, anchor_name=anchor_name, analysis=analysis)
    tmux_gdb_script = write_tmux_gdb_script(worktree, artifact_root, mode, anchor_name=anchor_name, analysis=analysis)
    zmux_driver_cmd = driver_command(worktree, zmux_binary, zmux_socket, artifact_root, mode)
    tmux_driver_cmd = driver_command(worktree, tmux_binary, tmux_socket, artifact_root, mode)

    payload = parallel_session_metadata(
        artifact_root=artifact_root,
        worktree=worktree,
        mode=mode,
        tmux_session=tmux_session,
        zmux_binary=zmux_binary,
        zmux_socket=zmux_socket,
        zmux_gdb_script=zmux_gdb_script,
        zmux_driver_cmd=zmux_driver_cmd,
        tmux_binary=tmux_binary,
        tmux_socket=tmux_socket,
        tmux_gdb_script=tmux_gdb_script,
        tmux_driver_cmd=tmux_driver_cmd,
    )
    start_parallel_tmux_session(worktree=worktree, payload=payload)
    write_parallel_session(artifact_root, payload)
    print_parallel_summary(payload)
    return 0


def cmd_capture_crash(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    manifest = capture_crash_manifest(
        worktree,
        artifact_root,
        args.mode,
        args.runs,
        args.backend,
    )
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0 if manifest.get("crash_found") else 1


def cmd_analyze_crash(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    analysis = analyze_crash_manifest(artifact_root, latest_crash_manifest(artifact_root))
    print(crash_analysis_path(artifact_root).read_text(encoding="utf-8").rstrip())
    if analysis.get("default_anchor"):
        print(f"anchor: {analysis['default_anchor']}")
    return 0


def phase3_common(args: argparse.Namespace, *, phase: str, builder) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    binary = builder(worktree)
    socket = phase_socket(artifact_root, phase, args.mode)
    prefix = lab_paths(artifact_root)["strace"] / phase_tag(phase, args.mode)
    driver_cmd = driver_command(worktree, binary, socket, artifact_root, args.mode)
    payload = phase_metadata(
        artifact_root=artifact_root,
        worktree=worktree,
        phase=phase,
        mode=args.mode,
        binary=binary,
        socket=socket,
        driver_cmd=driver_cmd,
        extra={"strace_prefix": str(prefix)},
    )
    write_current_phase(artifact_root, payload)
    print_phase_summary(payload)
    if args.run:
        os.chdir(worktree)
        os.execvp(
            "strace",
            [
                "strace",
                "-ff",
                "-ttT",
                "-e",
                "trace=signal,kill,rt_sigaction,rt_sigprocmask,wait4,exit_group",
                "-o",
                str(prefix),
                str(binary),
                "-D",
                "-vv",
                "-f/dev/null",
                "-S",
                str(socket),
            ],
        )
    return 0


def cmd_phase3_zmux_strace(args: argparse.Namespace) -> int:
    return phase3_common(args, phase="phase3-zmux-strace", builder=build_zmux_debug)


def cmd_phase3_tmux_strace(args: argparse.Namespace) -> int:
    return phase3_common(args, phase="phase3-tmux-strace", builder=build_tmux_debug)


def patch_phase_common(args: argparse.Namespace, *, phase: str, builder, scope: str) -> int:
    artifact_root = args.artifact_root.resolve()
    worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    binary = builder(worktree)
    socket = phase_socket(artifact_root, phase, args.mode)
    driver_cmd = driver_command(worktree, binary, socket, artifact_root, args.mode)
    payload = phase_metadata(
        artifact_root=artifact_root,
        worktree=worktree,
        phase=phase,
        mode=args.mode,
        binary=binary,
        socket=socket,
        driver_cmd=driver_cmd,
        extra={"edit_scope": scope},
    )
    write_current_phase(artifact_root, payload)
    print_phase_summary(payload)
    print(f"edit scope: {scope}")
    print("next steps:")
    print(f"  edit files in {worktree}")
    print(
        "  snapshot patch with "
        + shlex.join(
            [
                sys.executable,
                str(ROOT_DIR / "regress" / "session-group-lab.py"),
                "--artifact-root",
                str(artifact_root),
                "save-patch",
                "--label",
                phase_tag(phase, args.mode),
            ]
        )
    )
    return 0


def cmd_phase4_zmux_patch(args: argparse.Namespace) -> int:
    return patch_phase_common(
        args,
        phase="phase4-zmux-patch",
        builder=build_zmux_debug,
        scope="src/control.zig src/server-client.zig src/cmd-find.zig src/cmd-switch-client.zig src/session.zig src/server.zig",
    )


def cmd_phase5_tmux_patch(args: argparse.Namespace) -> int:
    return patch_phase_common(
        args,
        phase="phase5-tmux-patch",
        builder=build_tmux_debug,
        scope="tmux-museum/src/control.c tmux-museum/src/server-client.c tmux-museum/src/cmd-find.c tmux-museum/src/cmd-switch-client.c tmux-museum/src/session.c tmux-museum/src/server.c",
    )


def cmd_drive(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    if args.binary and args.socket:
        binary = pathlib.Path(args.binary)
        socket = pathlib.Path(args.socket)
        mode = args.mode or "switch-only"
        worktree = pathlib.Path(load_manifest(artifact_root)["worktree"])
    else:
        current = load_current_phase(artifact_root)
        binary = pathlib.Path(str(current["binary"]))
        socket = pathlib.Path(str(current["socket"]))
        mode = args.mode or str(current["mode"])
        worktree = pathlib.Path(str(current["worktree"]))

    cmd = driver_command(worktree, binary, socket, artifact_root, mode)
    print(shlex.join(cmd))
    result = subprocess.run(cmd, cwd=worktree)
    return result.returncode


def cmd_save_patch(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    manifest = load_manifest(artifact_root)
    worktree = pathlib.Path(manifest["worktree"])
    label = args.label or f"patch-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    path = save_patch(worktree, artifact_root, label)
    if path is None:
        print("lab: no tracked diff to save", file=sys.stderr)
        return 0
    print(path)
    return 0


def kill_server(binary: pathlib.Path, socket: pathlib.Path) -> None:
    if not binary.exists():
        return
    subprocess.run(
        [str(binary), "-N", "-S", str(socket), "-f/dev/null", "kill-server"],
        check=False,
        capture_output=True,
        text=True,
    )


def cmd_wind_down(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    messages: list[str] = []

    current = current_phase_path(artifact_root)
    if current.exists():
        payload = load_current_phase(artifact_root)
        binary = pathlib.Path(str(payload["binary"]))
        socket = pathlib.Path(str(payload["socket"]))
        kill_server(binary, socket)
        clear_current_phase(artifact_root)
        messages.append(f"killed server on {socket} (best effort)")

    messages.extend(stop_parallel_session(artifact_root))

    if not messages:
        print("lab: nothing to wind down")
        return 0

    for message in messages:
        print(message)
    return 0


def worktree_dirty(worktree: pathlib.Path) -> bool:
    status = run(["git", "status", "--porcelain"], cwd=worktree, capture=True)
    return bool(status.stdout.strip())


def cmd_teardown(args: argparse.Namespace) -> int:
    artifact_root = args.artifact_root.resolve()
    manifest = load_manifest(artifact_root)
    worktree = pathlib.Path(manifest["worktree"])

    if current_phase_path(artifact_root).exists():
        current = load_current_phase(artifact_root)
        kill_server(pathlib.Path(str(current["binary"])), pathlib.Path(str(current["socket"])))
        clear_current_phase(artifact_root)

    for message in stop_parallel_session(artifact_root):
        print(message)

    if worktree.exists() and worktree_dirty(worktree):
        label = f"teardown-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
        path = save_patch(worktree, artifact_root, label)
        if path is not None:
            print(f"saved patch: {path}")

    if worktree.exists():
        run(["git", "worktree", "remove", "--force", str(worktree)], cwd=ROOT_DIR)
        print(f"removed worktree: {worktree}")

    if args.purge_artifacts and artifact_root.exists():
        shutil.rmtree(artifact_root)
        print(f"removed artifacts: {artifact_root}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="layered session-group tracing lab")
    parser.add_argument("--artifact-root", type=pathlib.Path, default=DEFAULT_ARTIFACT_ROOT)
    parser.add_argument("--worktree", type=pathlib.Path, default=DEFAULT_WORKTREE)
    sub = parser.add_subparsers(dest="command", required=True)

    setup = sub.add_parser("setup")
    setup.add_argument("--branch")
    setup.set_defaults(func=cmd_setup)

    status = sub.add_parser("status")
    status.set_defaults(func=cmd_status)

    for name, func in (
        ("phase1-zmux-gdb", cmd_phase1_zmux_gdb),
        ("phase2-tmux-gdb", cmd_phase2_tmux_gdb),
        ("phase3-zmux-strace", cmd_phase3_zmux_strace),
        ("phase3-tmux-strace", cmd_phase3_tmux_strace),
        ("phase4-zmux-patch", cmd_phase4_zmux_patch),
        ("phase5-tmux-patch", cmd_phase5_tmux_patch),
    ):
        phase = sub.add_parser(name)
        phase.add_argument("--mode", choices=("switch-only", "full"), default="switch-only")
        phase.add_argument("--run", action="store_true")
        phase.set_defaults(func=func)

    parallel = sub.add_parser("parallel-gdb")
    parallel.add_argument("--mode", choices=("switch-only", "full"))
    parallel.add_argument("--from-crash", action="store_true")
    parallel.add_argument("--anchor", choices=tuple(anchor_locations(ROOT_DIR).keys()))
    parallel.add_argument("--tmux-session", default=DEFAULT_PARALLEL_TMUX_SESSION)
    parallel.set_defaults(func=cmd_parallel_gdb)

    crash = sub.add_parser("capture-crash")
    crash.add_argument("--mode", choices=("switch-only", "full"), default="switch-only")
    crash.add_argument("--runs", type=int, default=10)
    crash.add_argument("--backend", choices=("auto", "coredumpctl", "gdb"), default="auto")
    crash.set_defaults(func=cmd_capture_crash)

    analyze = sub.add_parser("analyze-crash")
    analyze.set_defaults(func=cmd_analyze_crash)

    drive = sub.add_parser("drive")
    drive.add_argument("--mode", choices=("switch-only", "full"))
    drive.add_argument("--binary")
    drive.add_argument("--socket")
    drive.set_defaults(func=cmd_drive)

    save = sub.add_parser("save-patch")
    save.add_argument("--label")
    save.set_defaults(func=cmd_save_patch)

    wind = sub.add_parser("wind-down")
    wind.set_defaults(func=cmd_wind_down)

    teardown = sub.add_parser("teardown")
    teardown.add_argument("--purge-artifacts", action="store_true")
    teardown.set_defaults(func=cmd_teardown)

    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

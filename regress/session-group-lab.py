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
from datetime import datetime, timezone


ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ARTIFACT_ROOT = pathlib.Path(tempfile.gettempdir()) / "zmux-session-group-lab"
DEFAULT_WORKTREE = ROOT_DIR.parent / "zmux-session-group-lab"


def die(message: str) -> "NoReturn":
    print(f"lab: {message}", file=sys.stderr)
    raise SystemExit(1)


def lab_paths(artifact_root: pathlib.Path) -> dict[str, pathlib.Path]:
    return {
        "root": artifact_root,
        "gdb": artifact_root / "gdb",
        "strace": artifact_root / "strace",
        "patches": artifact_root / "patches",
        "sockets": artifact_root / "sockets",
    }


def manifest_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return artifact_root / "manifest.json"


def current_phase_path(artifact_root: pathlib.Path) -> pathlib.Path:
    return artifact_root / "current-phase.json"


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


def write_zmux_gdb_script(worktree: pathlib.Path, artifact_root: pathlib.Path, mode: str) -> pathlib.Path:
    script_path = lab_paths(artifact_root)["gdb"] / f"{phase_tag('phase1-zmux-gdb', mode)}.gdb"
    switch_line = line_number(worktree / "src" / "cmd-switch-client.zig", "fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {")
    lines = [
        "set pagination off",
        "set breakpoint pending on",
        "set print pretty on",
        "handle SIGPIPE nostop noprint pass",
        "echo Loaded zmux session-group breakpoint set.\\n",
        "echo Recommended on stop: bt 8 ; info args ; info locals\\n",
        f"break {worktree / 'src' / 'cmd-switch-client.zig'}:{switch_line}",
        "break server_request_exit",
        "break server_send_exit",
        "break server_signal",
        "break control_read_callback",
        "break server_client_command_done",
        "break cmd_find_target",
        "break resolve_current_state",
        "break session_repair_current",
        "break session_set_current",
    ]
    script_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return script_path


def write_tmux_gdb_script(artifact_root: pathlib.Path, mode: str) -> pathlib.Path:
    script_path = lab_paths(artifact_root)["gdb"] / f"{phase_tag('phase2-tmux-gdb', mode)}.gdb"
    lines = [
        "set pagination off",
        "set breakpoint pending on",
        "set print pretty on",
        "handle SIGPIPE nostop noprint pass",
        "echo Loaded tmux session-group breakpoint set.\\n",
        "echo Recommended on stop: bt 8 ; info args ; info locals\\n",
        "break cmd_switch_client_exec",
        "break server_request_exit",
        "break server_send_exit",
        "break server_signal",
        "break control_read_callback",
        "break server_client_command_done",
        "break cmd_find_target",
        "break session_set_current",
    ]
    script_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return script_path


def build_zmux_debug(worktree: pathlib.Path) -> pathlib.Path:
    run(["zig", "build", "-Doptimize=Debug"], cwd=worktree)
    binary = worktree / "zig-out" / "bin" / "zmux"
    if not binary.exists():
        die(f"expected zmux debug binary at {binary}")
    return binary


def build_tmux_debug(worktree: pathlib.Path) -> pathlib.Path:
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
    gdb_script = write_tmux_gdb_script(artifact_root, args.mode)
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
    current = load_current_phase(artifact_root)
    binary = pathlib.Path(str(current["binary"]))
    socket = pathlib.Path(str(current["socket"]))
    kill_server(binary, socket)
    clear_current_phase(artifact_root)
    print(f"killed server on {socket} (best effort)")
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

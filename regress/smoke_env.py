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

import os
import pathlib
import shlex
import shutil


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
DEFAULT_HELPER = str(ROOT_DIR / "zig-out/bin/hello-shell-ansi")


def probe_real_shell() -> str | None:
    override = os.environ.get("SMOKE_TEST_SHELL")
    if override and os.path.isabs(override) and os.access(override, os.X_OK):
        return override
    if os.path.exists("/bin/sh") and os.access("/bin/sh", os.X_OK):
        return "/bin/sh"
    resolved = shutil.which("sh")
    return resolved


def _prepare_home_dirs(home_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path]:
    home_dir.mkdir(parents=True, exist_ok=True)
    xdg_config = home_dir / ".config"
    xdg_cache = home_dir / ".cache"
    xdg_data = home_dir / ".local/share"
    bin_dir = home_dir / ".smoke-bin"
    runtime_dir = home_dir / ".tmp"
    xdg_config.mkdir(parents=True, exist_ok=True)
    xdg_cache.mkdir(parents=True, exist_ok=True)
    xdg_data.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    return xdg_config, xdg_cache, xdg_data, bin_dir, runtime_dir


def _link_smoke_tool(bin_dir: pathlib.Path, name: str, target: str | None) -> None:
    if not target:
        return
    try:
        argv = shlex.split(target)
    except ValueError:
        return
    if not argv:
        return
    resolved = pathlib.Path(argv[0])
    if not resolved.is_absolute():
        which = shutil.which(argv[0], path="/bin:/usr/bin:/usr/local/bin")
        if which is None:
            return
        resolved = pathlib.Path(which)
    if not resolved.exists():
        return
    link_path = bin_dir / name
    if link_path.exists() or link_path.is_symlink():
        link_path.unlink()
    link_path.symlink_to(resolved)


def build_smoke_env(
    *,
    mode: str = "ambient",
    home_dir: pathlib.Path | None = None,
    helper_mode: str | None = None,
    helper_path: str | None = None,
    zmux_binary: str | None = None,
    oracle_tmux: str | None = None,
) -> dict[str, str]:
    term = os.environ.get("TERM", "screen")
    shell = os.environ.get("SHELL") or probe_real_shell() or "/bin/sh"
    path_prefix = "/bin:/usr/bin"
    home = None
    if home_dir is not None:
        xdg_config, xdg_cache, xdg_data, bin_dir, runtime_dir = _prepare_home_dirs(home_dir)
        _link_smoke_tool(bin_dir, "zmux", zmux_binary or os.environ.get("TEST_ZMUX"))
        _link_smoke_tool(bin_dir, "tmux", oracle_tmux or os.environ.get("TEST_ORACLE_TMUX", "/usr/bin/tmux"))
        path_prefix = f"{bin_dir}:/bin:/usr/bin"
        home = str(home_dir)

    if mode == "ambient":
        env = os.environ.copy()
        env["PATH"] = path_prefix
        env["TERM"] = term
        env.setdefault("COLORTERM", "truecolor")
        env["SHELL"] = shell
        if home is not None:
            env["HOME"] = home
            env["USER"] = "smoke"
            env["LOGNAME"] = "smoke"
            env["XDG_CONFIG_HOME"] = str(xdg_config)
            env["XDG_CACHE_HOME"] = str(xdg_cache)
            env["XDG_DATA_HOME"] = str(xdg_data)
            env["TMUX_TMPDIR"] = str(runtime_dir)
            env["ZMUX_TMPDIR"] = str(runtime_dir)
        return env

    if home_dir is None:
        raise RuntimeError("non-ambient smoke env requires home_dir")

    env = {
        "PATH": path_prefix,
        "TERM": term,
        "COLORTERM": "truecolor",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
        "HOME": home,
        "USER": "smoke",
        "LOGNAME": "smoke",
        "XDG_CONFIG_HOME": str(xdg_config),
        "XDG_CACHE_HOME": str(xdg_cache),
        "XDG_DATA_HOME": str(xdg_data),
        "TMUX_TMPDIR": str(runtime_dir),
        "ZMUX_TMPDIR": str(runtime_dir),
    }

    if mode == "deterministic":
        env["SHELL"] = os.environ.get("TEST_ZMUX_HELPER", DEFAULT_HELPER)
        if helper_mode is not None:
            env["ZMUX_SMOKE_HELPER_MODE"] = helper_mode
        if helper_path is not None:
            env["ZMUX_SMOKE_HELPER_PATH"] = helper_path
        return env

    if mode == "shell-sentinel":
        env["SHELL"] = shell
        return env

    raise RuntimeError(f"unknown smoke env mode: {mode}")

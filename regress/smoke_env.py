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


def build_smoke_env(
    *,
    mode: str = "ambient",
    home_dir: pathlib.Path | None = None,
    helper_mode: str | None = None,
    helper_path: str | None = None,
) -> dict[str, str]:
    term = os.environ.get("TERM", "screen")
    if mode == "ambient":
        env = os.environ.copy()
        env["PATH"] = "/bin:/usr/bin"
        env["TERM"] = term
        env.setdefault("COLORTERM", "truecolor")
        return env

    if home_dir is None:
        raise RuntimeError("non-ambient smoke env requires home_dir")

    home_dir.mkdir(parents=True, exist_ok=True)
    xdg_config = home_dir / ".config"
    xdg_cache = home_dir / ".cache"
    xdg_data = home_dir / ".local/share"
    xdg_config.mkdir(parents=True, exist_ok=True)
    xdg_cache.mkdir(parents=True, exist_ok=True)
    xdg_data.mkdir(parents=True, exist_ok=True)

    env = {
        "PATH": "/bin:/usr/bin",
        "TERM": term,
        "COLORTERM": "truecolor",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
        "HOME": str(home_dir),
        "USER": "smoke",
        "LOGNAME": "smoke",
        "XDG_CONFIG_HOME": str(xdg_config),
        "XDG_CACHE_HOME": str(xdg_cache),
        "XDG_DATA_HOME": str(xdg_data),
    }

    if mode == "deterministic":
        env["SHELL"] = os.environ.get("TEST_ZMUX_HELPER", DEFAULT_HELPER)
        if helper_mode is not None:
            env["ZMUX_SMOKE_HELPER_MODE"] = helper_mode
        if helper_path is not None:
            env["ZMUX_SMOKE_HELPER_PATH"] = helper_path
        return env

    if mode == "shell-sentinel":
        shell = probe_real_shell()
        if shell is None:
            raise RuntimeError("no suitable real shell found")
        env["SHELL"] = shell
        return env

    raise RuntimeError(f"unknown smoke env mode: {mode}")

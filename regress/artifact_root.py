#!/usr/bin/env python3

from __future__ import annotations

import os
import pathlib
import shutil
import time


DEFAULT_ROOT = "/tmp/zmux"
DEFAULT_PRUNE_MAX_AGE_HOURS = 72.0


def _path_from_env(var_name: str, fallback: str) -> pathlib.Path:
    raw = os.environ.get(var_name)
    path = pathlib.Path(raw) if raw else pathlib.Path(fallback)
    path.mkdir(parents=True, exist_ok=True)
    return path


def default_tmp_root() -> pathlib.Path:
    return _path_from_env("ZMUX_TMP_ROOT", DEFAULT_ROOT)


def default_artifact_root() -> pathlib.Path:
    raw = os.environ.get("SMOKE_ARTIFACT_ROOT")
    if raw:
        path = pathlib.Path(raw)
        path.mkdir(parents=True, exist_ok=True)
        return path
    return default_tmp_root()


def default_sandbox_root() -> pathlib.Path:
    raw = os.environ.get("ZMUX_TEST_ROOT")
    if raw:
        path = pathlib.Path(raw)
        path.mkdir(parents=True, exist_ok=True)
        return path
    return default_tmp_root()


def prune_stale_children(
    root: pathlib.Path, *, max_age_hours: float | None = None
) -> int:
    if max_age_hours is None:
        raw = os.environ.get("ZMUX_SMOKE_PRUNE_MAX_AGE_HOURS")
        max_age_hours = float(raw) if raw is not None else DEFAULT_PRUNE_MAX_AGE_HOURS
    if max_age_hours <= 0:
        return 0

    now = time.time()
    removed = 0
    for child in root.iterdir():
        try:
            stat = child.stat(follow_symlinks=False)
        except OSError:
            continue
        age_hours = (now - stat.st_mtime) / 3600.0
        if age_hours < max_age_hours:
            continue
        try:
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
            removed += 1
        except OSError:
            continue
    return removed

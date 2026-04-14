#!/usr/bin/env python3

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys

import artifact_root as artifact_root_module


LEGACY_TMP_ROOT = pathlib.Path("/tmp")
OLD_MANAGED_ROOT = pathlib.Path("/tmp/zmux-smoke")
LEGACY_PREFIXES = ("zmux_test_",)
MANAGED_PREFIXES = (
    "zmux_test_",
    "zmux-contained-",
    "zmux-smoke-",
    "zmux-recursive-attach-",
    "zaf-",
)
TMP_LOG_PREFIX = "zmux-"
TMP_LOG_SUFFIX = ".log"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="remove managed zmux smoke artifacts under ZMUX_TMP_ROOT and ZMUX_TEST_ROOT plus legacy /tmp entries"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would be removed without deleting it",
    )
    return parser.parse_args(argv)


def should_remove_named(entry: pathlib.Path, prefixes: tuple[str, ...]) -> bool:
    return any(entry.name.startswith(prefix) for prefix in prefixes)


def should_remove_tmp_log(entry: pathlib.Path) -> bool:
    return (
        entry.is_file()
        and entry.name.startswith(TMP_LOG_PREFIX)
        and entry.name.endswith(TMP_LOG_SUFFIX)
    )


def remove_path(path: pathlib.Path, *, dry_run: bool) -> bool:
    if dry_run:
        return True
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=False)
        return True
    path.unlink()
    return True


def collect_root_children(
    root: pathlib.Path, prefixes: tuple[str, ...]
) -> list[pathlib.Path]:
    if not root.exists() or not root.is_dir():
        return []
    matches: list[pathlib.Path] = []
    for entry in sorted(root.iterdir()):
        if should_remove_named(entry, prefixes):
            matches.append(entry)
    return matches


def collect_tmp_logs(root: pathlib.Path) -> list[pathlib.Path]:
    if not root.exists() or not root.is_dir():
        return []
    matches: list[pathlib.Path] = []
    for entry in sorted(root.iterdir()):
        if should_remove_tmp_log(entry):
            matches.append(entry)
    return matches


def maybe_remove_empty_root(root: pathlib.Path, *, dry_run: bool) -> bool:
    if not root.exists() or not root.is_dir():
        return False
    if any(root.iterdir()):
        return False
    if dry_run:
        return True
    root.rmdir()
    return True


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    current_root = artifact_root_module.default_tmp_root()
    sandbox_root = artifact_root_module.default_sandbox_root()
    roots_to_scan = [LEGACY_TMP_ROOT]
    managed_roots = [current_root]
    if sandbox_root != current_root:
        managed_roots.append(sandbox_root)
    if OLD_MANAGED_ROOT != current_root:
        managed_roots.append(OLD_MANAGED_ROOT)

    candidates: list[pathlib.Path] = []
    seen: set[pathlib.Path] = set()

    for path in collect_root_children(LEGACY_TMP_ROOT, LEGACY_PREFIXES):
        if path not in seen:
            candidates.append(path)
            seen.add(path)
    for path in collect_tmp_logs(LEGACY_TMP_ROOT):
        if path not in seen:
            candidates.append(path)
            seen.add(path)
    for root in managed_roots:
        for path in collect_root_children(root, MANAGED_PREFIXES):
            if path not in seen:
                candidates.append(path)
                seen.add(path)

    removed = 0
    failures: list[str] = []
    for path in candidates:
        try:
            remove_path(path, dry_run=args.dry_run)
            removed += 1
            action = "would remove" if args.dry_run else "removed"
            print(f"{action} {path}")
        except OSError as exc:
            failures.append(f"{path}: {exc}")

    for root in managed_roots:
        try:
            if maybe_remove_empty_root(root, dry_run=args.dry_run):
                action = "would remove" if args.dry_run else "removed"
                print(f"{action} {root}")
        except OSError as exc:
            failures.append(f"{root}: {exc}")

    if failures:
        for line in failures:
            print(line, file=sys.stderr)
        return 1

    noun = "candidate" if args.dry_run else "artifact"
    print(f"cleanup complete: {removed} {noun}{'' if removed == 1 else 's'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

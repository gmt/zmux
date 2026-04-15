#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import cast

import test_orchestrator as orch


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="reduce sharded Zig test results")
    parser.add_argument("--results-dir", required=True)
    parser.add_argument(
        "--suite",
        required=True,
        choices=(
            "zig-unit",
            "zig-stress",
            "smoke-fast",
            "smoke-oracle",
            "smoke-fuzz",
            "smoke-recursive",
            "smoke-docker",
            "smoke-soak",
        ),
    )
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--workers", type=int, default=1)
    return parser.parse_args(argv)


def read_shard_payload(path: pathlib.Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def shard_index_from_path(path: pathlib.Path) -> int:
    stem = path.stem
    prefix = "shard-"
    if not stem.startswith(prefix):
        raise ValueError(f"unexpected shard filename: {path.name}")
    return int(stem[len(prefix) :])


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.shard_count <= 0:
        print("shard reducer: --shard-count must be positive", file=sys.stderr)
        return 2

    results_by_order: list[tuple[int, orch.CaseResult]] = []
    results_dir = pathlib.Path(args.results_dir)

    try:
        shard_files = sorted(
            results_dir.glob("shard-*.json"), key=shard_index_from_path
        )
        if len(shard_files) != args.shard_count:
            raise orch.HarnessError(
                f"expected {args.shard_count} shard files, found {len(shard_files)}"
            )
        for shard_file in shard_files:
            expected_shard_index = shard_index_from_path(shard_file)
            payload = read_shard_payload(shard_file)
            payload_shard_index = int(cast(int | str, payload["shard_index"]))
            payload_shard_count = int(cast(int | str, payload["shard_count"]))
            if payload_shard_index != expected_shard_index:
                raise orch.HarnessError(f"unexpected shard index in {shard_file.name}")
            if payload_shard_count != args.shard_count:
                raise orch.HarnessError(f"unexpected shard count in {shard_file.name}")
            payload_suite = cast(str, payload["suite"])
            if payload_suite != args.suite:
                raise orch.HarnessError(
                    f"unexpected suite {payload_suite!r} in {shard_file.name}"
                )
            for item in cast(list[dict[str, object]], payload["results"]):
                entry = cast(dict[str, object], item)
                results_by_order.append(
                    (
                        int(cast(int | str, entry["case_order"])),
                        orch.case_result_from_json(entry),
                    )
                )
    except FileNotFoundError as exc:
        print(f"shard reducer: missing shard result: {exc.filename}", file=sys.stderr)
        return 1
    except (
        ValueError,
        KeyError,
        TypeError,
        orch.HarnessError,
        json.JSONDecodeError,
    ) as exc:
        print(f"shard reducer: {exc}", file=sys.stderr)
        return 1

    results = [
        result for _, result in sorted(results_by_order, key=lambda item: item[0])
    ]
    if not results:
        print("no cases selected", file=sys.stderr)
        return 1
    print(orch.summarize_results(results, workers=args.workers))
    orch.print_kept_sandboxes(results)
    return (
        0
        if all(
            result.status in {"PASS", "SKIP"} and not result.cleanup_failed
            for result in results
        )
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

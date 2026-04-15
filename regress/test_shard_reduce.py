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
    parser.add_argument("--suite", required=True, choices=("zig-unit", "zig-stress"))
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--workers", type=int, default=1)
    return parser.parse_args(argv)


def read_shard_payload(path: pathlib.Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.shard_count <= 0:
        print("shard reducer: --shard-count must be positive", file=sys.stderr)
        return 2

    results_by_order: list[tuple[int, orch.CaseResult]] = []
    results_dir = pathlib.Path(args.results_dir)

    try:
        for shard_index in range(args.shard_count):
            payload = read_shard_payload(results_dir / f"shard-{shard_index}.json")
            payload_shard_index = int(cast(int | str, payload["shard_index"]))
            payload_shard_count = int(cast(int | str, payload["shard_count"]))
            if payload_shard_index != shard_index:
                raise orch.HarnessError(
                    f"unexpected shard index in shard-{shard_index}.json"
                )
            if payload_shard_count != args.shard_count:
                raise orch.HarnessError(
                    f"unexpected shard count in shard-{shard_index}.json"
                )
            payload_suite = cast(str, payload["suite"])
            if payload_suite != args.suite:
                raise orch.HarnessError(
                    f"unexpected suite {payload_suite!r} in shard-{shard_index}.json"
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

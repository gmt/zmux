#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import cast

import test_orchestrator as orch


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="reduce multiple sharded test families into one aggregate summary"
    )
    parser.add_argument(
        "--family-result",
        action="append",
        required=True,
        help="family_name:/path/to/results",
    )
    parser.add_argument("--workers", type=int, default=1)
    return parser.parse_args(argv)


def read_shard_payload(path: pathlib.Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    all_results: list[orch.CaseResult] = []
    overall_rc = 0

    for family_spec in args.family_result:
        try:
            family_name, results_dir_str = family_spec.split(":", 1)
            results_dir = pathlib.Path(results_dir_str)
            shard_files = sorted(results_dir.glob("shard-*.json"))
            if not shard_files:
                print(f"warning: no shard files in {results_dir}", file=sys.stderr)
                continue
            for shard_index, shard_file in enumerate(shard_files):
                payload = read_shard_payload(shard_file)
                payload_suite = cast(str, payload["suite"])
                if payload_suite != family_name:
                    raise orch.HarnessError(
                        f"unexpected suite {payload_suite!r} in {shard_file.name}"
                    )
                payload_shard_index = int(cast(int | str, payload["shard_index"]))
                if payload_shard_index != shard_index:
                    raise orch.HarnessError(
                        f"unexpected shard index in {shard_file.name}"
                    )
                for item in cast(list[dict[str, object]], payload["results"]):
                    entry = cast(dict[str, object], item)
                    all_results.append(orch.case_result_from_json(entry))
        except (
            FileNotFoundError,
            ValueError,
            KeyError,
            TypeError,
            orch.HarnessError,
            json.JSONDecodeError,
        ) as exc:
            print(
                f"bundle reducer: error reading {family_spec}: {exc}", file=sys.stderr
            )
            overall_rc = 1

    if not all_results:
        print("no cases selected", file=sys.stderr)
        return 1

    print(orch.summarize_results(all_results, workers=args.workers))
    orch.print_kept_sandboxes(all_results)
    if overall_rc != 0:
        return overall_rc
    return (
        0
        if all(
            result.status in {"PASS", "SKIP"} and not result.cleanup_failed
            for result in all_results
        )
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

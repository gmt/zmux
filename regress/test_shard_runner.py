#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import test_orchestrator as orch


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="run one sharded Zig test suite")
    parser.add_argument("--suite", required=True, choices=("zig-unit", "zig-stress"))
    parser.add_argument("--zig-test-binary", required=True)
    parser.add_argument("--shard-index", type=int, required=True)
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--result-path", required=True)
    parser.add_argument("--test-filter", action="append", default=[])
    return parser.parse_args(argv)


def clear_progress_line() -> None:
    if sys.stdout.isatty():
        print("\r\033[2K", end="", flush=True)


def print_result(
    result: orch.CaseResult,
    shard_index: int,
    shard_count: int,
    position: int,
    total: int,
) -> None:
    if result.status == "PASS" and not result.cleanup_failed:
        if sys.stdout.isatty():
            print(
                f"\r\033[2K[{shard_index + 1}/{shard_count}] PASS {position}/{total} {result.case.case_id}",
                end="",
                flush=True,
            )
        return
    clear_progress_line()
    suffix = f" cleanup={result.cleanup_failed}" if result.cleanup_failed else ""
    detail = f" {result.detail}" if result.detail else ""
    print(
        f"[{shard_index + 1}/{shard_count}] {result.status:12s} {result.case.case_id} {result.elapsed_s:6.2f}s{suffix}{detail}",
        flush=True,
    )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.shard_count <= 0:
        print("shard runner: --shard-count must be positive", file=sys.stderr)
        return 2
    if args.shard_index < 0 or args.shard_index >= args.shard_count:
        print("shard runner: --shard-index out of range", file=sys.stderr)
        return 2

    runner_args = orch.parse_args(
        [
            args.suite,
            "--zig-test-binary",
            args.zig_test_binary,
            "--summary-format",
            "none",
            "--skip-prune",
            *sum((["--test-filter", item] for item in args.test_filter), []),
        ]
    )

    try:
        runner = orch.SuiteRunner(runner_args)
        cases = runner.selected_cases()
        shard_cases = [
            (case_order, case)
            for case_order, case in enumerate(cases)
            if case_order % args.shard_count == args.shard_index
        ]
        results: list[dict[str, object]] = []
        for position, (case_order, case) in enumerate(shard_cases, start=1):
            result = runner.run_case(case)
            results.append(orch.case_result_to_json(result, case_order=case_order))
            print_result(
                result, args.shard_index, args.shard_count, position, len(shard_cases)
            )
        clear_progress_line()
        payload = {
            "suite": args.suite,
            "shard_index": args.shard_index,
            "shard_count": args.shard_count,
            "results": results,
        }
        result_path = pathlib.Path(args.result_path)
        result_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = result_path.with_suffix(result_path.suffix + ".tmp")
        tmp_path.write_text(
            json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8"
        )
        tmp_path.replace(result_path)
        return 0
    except orch.HarnessError as exc:
        clear_progress_line()
        print(f"shard runner: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        clear_progress_line()
        print(f"shard runner: infrastructure exception: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

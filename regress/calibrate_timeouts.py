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
import math
import pathlib
import statistics
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

import test_orchestrator as orch


CALIBRATABLE_SUITES = (
    "zig-unit",
    "zig-stress",
    "smoke-fast",
    "smoke-oracle",
    "smoke-recursive",
    "smoke-soak",
    "smoke-docker",
    "fuzz-smoke",
)

DEFAULT_SAMPLE_TIMEOUTS = {
    "zig-unit": 300.0,
    "zig-stress": 300.0,
    "smoke-fast": 300.0,
    "smoke-oracle": 300.0,
    "smoke-recursive": 300.0,
    "smoke-soak": 1800.0,
    "smoke-docker": 3600.0,
    "fuzz-smoke": 300.0,
}


@dataclass
class Sample:
    elapsed_s: float
    status: str
    detail: str
    cleanup_failed: bool


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def round_timeout(seconds: float) -> int:
    if seconds <= 15.0:
        step = 1.0
    elif seconds <= 120.0:
        step = 5.0
    elif seconds <= 600.0:
        step = 15.0
    else:
        step = 60.0
    return int(math.ceil(seconds / step) * step)


def sample_timeout_for_suite(args: argparse.Namespace, suite: str) -> float:
    if args.sample_timeout is not None:
        return args.sample_timeout
    return DEFAULT_SAMPLE_TIMEOUTS[suite]


def sample_target(case: orch.Case, first_sample: Sample) -> int:
    if first_sample.status == "TIMEOUT":
        return 1
    if case.family in {"smoke-soak", "smoke-docker"}:
        return 3
    return 5 if first_sample.elapsed_s < 5.0 else 3


def serialize_sample(result: orch.CaseResult) -> Sample:
    return Sample(
        elapsed_s=result.elapsed_s,
        status=result.status,
        detail=result.detail,
        cleanup_failed=result.cleanup_failed,
    )


def compute_proposal(
    samples: list[Sample],
    *,
    sigma: float,
    slow_host_factor: float,
    minimum_timeout: float,
    sample_timeout: float,
) -> tuple[float, float, float, int]:
    elapsed_values = [sample.elapsed_s for sample in samples]
    mean_s = statistics.fmean(elapsed_values)
    stdev_s = statistics.stdev(elapsed_values) if len(elapsed_values) > 1 else 0.0
    max_s = max(elapsed_values)
    local_budget = max(max_s, mean_s + sigma * stdev_s)
    if any(sample.status == "TIMEOUT" for sample in samples):
        local_budget = max(local_budget, sample_timeout)
    scaled_budget = max(minimum_timeout, local_budget * slow_host_factor)
    return mean_s, stdev_s, max_s, round_timeout(scaled_budget)


def load_report(path: pathlib.Path) -> dict[str, object]:
    if not path.exists():
        return {
            "meta": {},
            "results": {},
        }
    return json.loads(path.read_text(encoding="utf-8"))


def write_report(path: pathlib.Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_tsv(path: pathlib.Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(
            "case_id\tfamily\tlabel\tsample_count\tmean_s\tstdev_s\tmax_s\tproposal_s\tstatuses\n"
        )
        for case_id in sorted(payload["results"]):
            entry = payload["results"][case_id]
            statuses = ",".join(sample["status"] for sample in entry["samples"])
            handle.write(
                f"{case_id}\t{entry['family']}\t{entry['label']}\t{entry['sample_count']}\t"
                f"{entry['mean_s']:.6f}\t{entry['stdev_s']:.6f}\t{entry['max_s']:.6f}\t"
                f"{entry['proposal_seconds']}\t{statuses}\n"
            )


def merge_policy(policy_path: pathlib.Path, case_timeouts: dict[str, int]) -> None:
    payload = json.loads(policy_path.read_text(encoding="utf-8"))
    merged_cases = {str(key): float(value) for key, value in payload.get("cases", {}).items()}
    for case_id, timeout_s in case_timeouts.items():
        merged_cases[case_id] = float(timeout_s)
    new_payload = {
        "defaults": payload["defaults"],
        "cases": {key: merged_cases[key] for key in sorted(merged_cases)},
    }
    policy_path.write_text(json.dumps(new_payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def build_runner_args(args: argparse.Namespace, suite: str) -> argparse.Namespace:
    zig_test_binary = None
    if suite == "zig-unit":
        zig_test_binary = args.zig_unit_binary
    elif suite == "zig-stress":
        zig_test_binary = args.zig_stress_binary

    return argparse.Namespace(
        suite=suite,
        zig_test_binary=zig_test_binary,
        input_fuzzer=args.input_fuzzer,
        cmd_preprocess_fuzzer=args.cmd_preprocess_fuzzer,
        zmux_binary=args.zmux_binary,
        oracle_binary=args.oracle_binary,
        helper_binary=args.helper_binary,
        test_filter=list(args.test_filter),
        case_filter=list(args.case_filter),
        timeout_override=None,
        allow_default_timeouts=True,
        list_cases=False,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="calibrate per-case test timeouts")
    parser.add_argument("--suite", action="append", required=True, choices=CALIBRATABLE_SUITES)
    parser.add_argument("--zig-unit-binary")
    parser.add_argument("--zig-stress-binary")
    parser.add_argument("--input-fuzzer")
    parser.add_argument("--cmd-preprocess-fuzzer")
    parser.add_argument("--zmux-binary")
    parser.add_argument("--oracle-binary")
    parser.add_argument("--helper-binary")
    parser.add_argument("--test-filter", action="append", default=[])
    parser.add_argument("--case-filter", action="append", default=[])
    parser.add_argument("--sample-timeout", type=float)
    parser.add_argument("--sigma", type=float, default=4.0)
    parser.add_argument("--slow-host-factor", type=float, default=5.0)
    parser.add_argument("--minimum-timeout", type=float, default=5.0)
    parser.add_argument("--json-report", required=True)
    parser.add_argument("--tsv-report")
    parser.add_argument("--write-policy")
    parser.add_argument("--force", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    json_report = pathlib.Path(args.json_report)
    tsv_report = pathlib.Path(args.tsv_report) if args.tsv_report else json_report.with_suffix(".tsv")
    payload = load_report(json_report)
    payload["meta"] = {
        "generated_at": now_utc(),
        "minimum_timeout": args.minimum_timeout,
        "sigma": args.sigma,
        "slow_host_factor": args.slow_host_factor,
        "suites": args.suite,
    }
    results: dict[str, object] = dict(payload.get("results", {}))

    policy_updates: dict[str, int] = {}
    for suite in args.suite:
        runner = orch.SuiteRunner(build_runner_args(args, suite))
        cases = runner.selected_cases()
        timeout_s = sample_timeout_for_suite(args, suite)
        print(f"calibrate: suite={suite} cases={len(cases)} sample_timeout={timeout_s:.1f}s")
        for case in cases:
            if case.case_id in results and not args.force:
                print(f"skip {case.case_id}")
                continue

            warmup = runner.run_case(case, timeout_s=timeout_s)
            first_sample = serialize_sample(runner.run_case(case, timeout_s=timeout_s))
            target_count = sample_target(case, first_sample)
            samples = [first_sample]
            while len(samples) < target_count:
                samples.append(serialize_sample(runner.run_case(case, timeout_s=timeout_s)))

            mean_s, stdev_s, max_s, proposal_seconds = compute_proposal(
                samples,
                sigma=args.sigma,
                slow_host_factor=args.slow_host_factor,
                minimum_timeout=args.minimum_timeout,
                sample_timeout=timeout_s,
            )
            entry = {
                "case_id": case.case_id,
                "family": case.family,
                "label": case.label,
                "proposal_seconds": proposal_seconds,
                "sample_count": len(samples),
                "mean_s": mean_s,
                "stdev_s": stdev_s,
                "max_s": max_s,
                "samples": [asdict(sample) for sample in samples],
                "warmup": asdict(serialize_sample(warmup)),
            }
            results[case.case_id] = entry
            policy_updates[case.case_id] = proposal_seconds
            payload["results"] = results
            write_report(json_report, payload)
            write_tsv(tsv_report, payload)
            if args.write_policy:
                merge_policy(pathlib.Path(args.write_policy), policy_updates)
            statuses = ",".join(sample.status for sample in samples)
            print(
                f"done {case.case_id} mean={mean_s:.3f}s stdev={stdev_s:.3f}s "
                f"max={max_s:.3f}s proposal={proposal_seconds}s statuses={statuses}"
            )

    payload["meta"]["generated_at"] = now_utc()
    payload["results"] = results
    write_report(json_report, payload)
    write_tsv(tsv_report, payload)
    if args.write_policy:
        merge_policy(pathlib.Path(args.write_policy), policy_updates)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

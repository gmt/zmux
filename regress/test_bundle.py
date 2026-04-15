#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys

import test_orchestrator as orch


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="run aggregate zmux test bundles")
    parser.add_argument("bundle", choices=("test-most", "test-all"))
    parser.add_argument("--zig-test-binary", required=True)
    parser.add_argument("--zig-stress-binary")
    parser.add_argument("--fuzz-mode", choices=orch.FUZZ_MODES, default="auto")
    parser.add_argument("--test-filter", action="append", default=[])
    parser.add_argument("--case-filter", action="append", default=[])
    parser.add_argument("--af-unix", choices=orch.host_caps.AF_UNIX_MODES)
    return parser.parse_args(argv)


def suite_argvs(args: argparse.Namespace) -> list[list[str]]:
    common = []
    if args.af_unix is not None:
        common.extend(["--af-unix", args.af_unix])
    for test_filter in args.test_filter:
        common.extend(["--test-filter", test_filter])
    for case_filter in args.case_filter:
        common.extend(["--case-filter", case_filter])

    suites: list[list[str]] = [
        [
            "zig-unit",
            "--zig-test-binary",
            args.zig_test_binary,
            "--summary-format",
            "none",
            *common,
        ]
    ]
    if args.bundle == "test-all":
        if args.zig_stress_binary is None:
            raise SystemExit("test-all requires --zig-stress-binary")
        suites.append(
            [
                "zig-stress",
                "--zig-test-binary",
                args.zig_stress_binary,
                "--summary-format",
                "none",
                *common,
            ]
        )
        suites.append(
            [
                "smoke-all",
                "--fuzz-mode",
                args.fuzz_mode,
                "--summary-format",
                "none",
                *common,
            ]
        )
    else:
        suites.append(["smoke-most", "--summary-format", "none", *common])
    return suites


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    all_results: list[orch.CaseResult] = []
    overall_rc = 0
    for suite_argv in suite_argvs(args):
        runner_args = orch.parse_args(suite_argv)
        runner = orch.SuiteRunner(runner_args)
        rc = runner.run()
        all_results.extend(runner.results)
        if rc != 0 and overall_rc == 0:
            overall_rc = rc
    print(orch.summarize_results(all_results))
    orch.print_kept_sandboxes(all_results)
    return overall_rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

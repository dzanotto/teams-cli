#!/usr/bin/env python3
"""Validate this CI invocation's reports and print a concise job summary."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys


# Reuse the runner's completeness checks and score calculation.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "mutation_runner", Path(__file__).with_name("mutation-test.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def summarize_ci(runs, baseline_outcome, mutation_outcome):
    lines = ["## Mutation testing", "",
             f"Baseline: **{baseline_outcome or 'not run'}**. "
             f"Mutation step: **{mutation_outcome or 'not run'}**.", ""]
    failed = baseline_outcome != "success" or mutation_outcome != "success"
    try:
        # Hosted runners start clean and this workflow does not restore run caches.
        # Never select an older successful report to cover a failed invocation.
        directories = list(runs.iterdir()) if runs.is_dir() else []
        if len(directories) != 1 or not directories[0].is_dir():
            raise RuntimeError("Expected exactly one mutation run directory")
        reports = directories[0]
        metadata = json.loads((reports / "run.json").read_text())
        if metadata["status"] != "completed":
            raise RuntimeError("Mutation runner did not complete; inspect run.json and runner.log")
        result = runner.read_report(reports)
        saved_summary = json.loads((reports / "summary.json").read_text())
        if saved_summary != result:
            raise RuntimeError("Saved summary does not match the complete mutation report")
        counts = result["counts"]
        lines.extend([
            "| Killed | Survived | No coverage | Timeout | Compile error |",
            "| ---: | ---: | ---: | ---: | ---: |",
            f"| {counts['Killed']} | {counts['Survived']} | {counts['NoCoverage']} | "
            f"{counts['Timeout']} | {counts['CompileError']} |", "",
            f"Score: **{result['score_percent']:.2f}%** (compile errors excluded). "
            f"Activation warnings: **{result['integrity_warnings']}**.",
        ])
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError) as error:
        failed = True
        lines.append(f"**Reports unavailable or incomplete:** {error}")
    lines.extend([
        "",
        "**Result: failed.** Baseline, tool, and report errors are fatal."
        if failed else "**Result: complete.** Survivors and uncovered mutations are report-only.",
        "See the mutation-testing artifact for available reports, logs, and the input snapshot.",
        "The equivalent focus-initialization survivor and future exception policy are documented "
        "in `docs/mutation-testing.md`.",
    ])
    return "\n".join(lines) + "\n", int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-outcome", required=True)
    parser.add_argument("--mutation-outcome", required=True)
    args = parser.parse_args()
    runs = Path(__file__).resolve().parent.parent / ".build/mutation-testing/runs"
    summary, code = summarize_ci(runs, args.baseline_outcome, args.mutation_outcome)
    print(summary, end="")
    return code


if __name__ == "__main__":
    sys.exit(main())

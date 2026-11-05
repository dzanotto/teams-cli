"""Exercise report-only results and failures without Swift or the mutation tool."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "mutation_ci", Path(__file__).resolve().parents[1] / "mutation-ci-summary.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class MutationCIReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.runs = Path(temporary.name)
        self.reports = self.runs / "current-run"
        self.reports.mkdir()
        source = "Sources/TeamsCore/FocusMonitor.swift"
        self.plan = {
            "files": [{"path": source}],
            "mutants": [{"file": source, "fingerprint": str(index)} for index in range(5)],
        }
        self.write("plan.json", self.plan)
        self.report = {
            "config": {"planSha256": ci.runner.digest(self.reports / "plan.json")},
            "files": {"/" + source: {"mutants": [
                {"fingerprint": str(index), "status": status, "activated": True}
                for index, status in enumerate(
                    ["Killed", "Survived", "NoCoverage", "Timeout", "CompileError"])
            ]}},
        }
        self.write("mutation-report.json", self.report)
        (self.reports / "mutation-report.html").write_text("<html>Report</html>")
        self.write("run.json", {"status": "completed"})
        self.write("summary.json", ci.runner.read_report(self.reports))

    def write(self, name, value):
        (self.reports / name).write_text(json.dumps(value))

    def summarize(self, baseline="success", mutation="success"):
        return ci.summarize_ci(self.runs, baseline, mutation)

    def test_survivors_uncovered_timeouts_and_compile_errors_are_report_only(self):
        text, code = self.summarize()
        self.assertEqual(code, 0)
        self.assertIn("50.00%", text)
        self.assertIn("| 1 | 1 | 1 | 1 | 1 |", text)
        self.assertIn("report-only", text)

    def test_failed_or_skipped_steps_fail_even_with_complete_reports(self):
        for baseline, mutation in [("failure", "skipped"), ("success", "failure"),
                                   ("success", "cancelled"), ("", "")]:
            with self.subTest(baseline=baseline, mutation=mutation):
                text, code = self.summarize(baseline, mutation)
                self.assertEqual(code, 1)
                self.assertIn("Result: failed", text)

    def test_missing_run_after_baseline_failure_has_a_failure_summary(self):
        text, code = ci.summarize_ci(self.runs / "missing", "failure", "skipped")
        self.assertEqual(code, 1)
        self.assertIn("Baseline: **failure**", text)
        self.assertIn("Reports unavailable or incomplete", text)

    def test_previous_run_cannot_stand_in_for_current_run(self):
        (self.runs / "older-run").mkdir()
        self.assertEqual(self.summarize()[1], 1)

    def test_failed_or_unfinished_run_rejects_existing_reports(self):
        for status in ["failed", "running"]:
            with self.subTest(status=status):
                self.write("run.json", {"status": status})
                self.assertEqual(self.summarize()[1], 1)

    def test_missing_or_malformed_reports_fail_with_a_summary(self):
        for name in ["run.json", "plan.json", "summary.json", "mutation-report.json",
                     "mutation-report.html"]:
            path = self.reports / name
            original = path.read_text()
            for replacement in [None, ""]:
                with self.subTest(name=name, replacement=replacement):
                    if replacement is None:
                        path.unlink()
                    else:
                        path.write_text(replacement)
                    text, code = self.summarize()
                    self.assertEqual(code, 1)
                    self.assertIn("Reports unavailable or incomplete", text)
                    path.write_text(original)

    def test_duplicate_mutation_cannot_hide_a_missing_mutation(self):
        mutants = next(iter(self.report["files"].values()))["mutants"]
        mutants[1]["fingerprint"] = mutants[0]["fingerprint"]
        self.write("mutation-report.json", self.report)
        self.assertEqual(self.summarize()[1], 1)

    def test_report_from_another_plan_is_rejected(self):
        self.report["config"]["planSha256"] = "wrong-plan"
        self.write("mutation-report.json", self.report)
        self.assertEqual(self.summarize()[1], 1)

    def test_unfinished_mutation_status_is_rejected(self):
        next(iter(self.report["files"].values()))["mutants"][0]["status"] = "Pending"
        self.write("mutation-report.json", self.report)
        self.assertEqual(self.summarize()[1], 1)

    def test_all_compile_errors_cannot_produce_a_meaningful_report(self):
        for mutant in next(iter(self.report["files"].values()))["mutants"]:
            mutant["status"] = "CompileError"
        self.write("mutation-report.json", self.report)
        self.assertEqual(self.summarize()[1], 1)

    def test_saved_summary_must_match_the_report(self):
        self.write("summary.json", {"score_percent": 100})
        self.assertEqual(self.summarize()[1], 1)

    def test_activation_warnings_remain_visible(self):
        next(iter(self.report["files"].values()))["mutants"][0]["activated"] = False
        self.write("mutation-report.json", self.report)
        self.write("summary.json", ci.runner.read_report(self.reports))
        text, code = self.summarize()
        self.assertEqual(code, 0)
        self.assertIn("Activation warnings: **1**", text)


if __name__ == "__main__":
    unittest.main()

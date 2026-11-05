# Mutation testing

From the repository root, run the scoped, report-only check:

```sh
bash scripts/mutation-test.sh
```

This requires Apple Silicon macOS 15+, Python 3.9+, and a working Swift/Xcode
toolchain. The first run downloads `swift-mutation-testing` 1.7.0 into
`.build/mutation-testing/tools`; each run verifies its pinned archive checksum.
The runner copies the current sources and tests, including uncommitted edits,
into a temporary workspace and removes it on completion or handled interruption.
It does not install a global tool or change the package's dependencies.

The allowlist in [`scripts/mutation-test.json`](../scripts/mutation-test.json) covers:

- `MediaActionController.swift`: shared media-action selection and verification.
- `AccessibilityExposureReadiness.swift`: bounded accessibility readiness polling.
- `NativeMediaBackend.swift`: target identity and checks immediately before dispatch.
- `CallEndController.swift`: call selection and verified window closure.
- `CallStatusSupport.swift`: shared call eligibility and control-label matching.
- `TeamsAccessibilityExposure.swift`: accessibility restoration, native Boolean conversion,
  and process-generation checks.
- `TeamsMediaCommandSupport.swift`: lock lifetime, cleanup ordering, and finalization outcomes.
- `FocusMonitor.swift`: focus-change tracking, inconclusive observations, and typed window reads.

It uses five mutation operators and only `TeamsCoreTests`. New source files are
excluded until added to that allowlist. Runs use one worker, explicit
test/build/run timeouts, and no result cache. To invoke it from another directory,
use the path to the wrapper script.

Each invocation prints a new directory under `.build/mutation-testing/runs/`
containing HTML/JSON reports, the mutation plan, per-mutant test logs, toolchain
and source hashes, and an archive of its exact input snapshot. `run.json` records
completion or failure, so an earlier report cannot stand in for a failed run.
Surviving mutations do not fail the command; tool failures, baseline build
failures, the overall run timeout, and incomplete reports do. Compile errors are
excluded from the mutation score; per-mutant timeouts and missing activation
evidence remain visible in the summary.

Review survivors for observable behavior changes before adding tests. Redundant
guards can produce equivalent mutations. Adapter tests inject process lookup,
attribute calls, and virtual time below the selection, type-validation, and
readback logic. This exercises those decisions without accessing Teams or changing
desktop focus. The thin live forwarding layer still requires platform validation.
Any unexercised mutations remain visible as `NoCoverage`.

## CI reports

The dedicated [Mutation testing workflow](../.github/workflows/mutation-testing.yml)
runs manually with `workflow_dispatch` and weekly on Mondays at 04:17 UTC. It uses
the same `macos-15` ARM runner and Xcode selection as the ARM job in regular CI.
Scheduled runs use the default branch; manual runs can select a branch after the
workflow is available on the default branch.

The job first runs the full, unchanged `swift test` baseline, then invokes the
same scoped mutation runner as the local command. A baseline failure prevents
mutation testing. Survivors and `NoCoverage` remain report-only; there is no score
threshold or `continue-on-error`. Tool errors, baseline failures, timeouts of the
overall run, and missing, malformed, or incomplete reports fail the job. Report
validation checks the plan checksum, each planned mutation's file and fingerprint,
terminal statuses, a nonempty HTML report, and agreement with the saved summary.

The job summary and artifact upload run even after a failed step. The summary
shows baseline/run outcomes, status counts, score, and activation warnings, or
explains why complete results are unavailable. The artifact retains available
HTML/JSON reports, the plan, metadata, input snapshot, baseline/runner logs, and
per-mutant logs for 30 days. Each hosted job starts without cached results; the
summary requires exactly one run directory and a completed run marker. Tool
downloads are not included in the artifact.

The baseline and mutation steps are bounded to 5 and 20 minutes respectively;
the job allows 30 minutes to leave time for reporting and upload. The runner's
shorter internal timeouts remain in force. These checks use automated tests and
do not perform live Teams actions. A score applies only to the configured files
and operators, and does not establish live Teams compatibility.

Report validation and failure-summary regression tests run before the Swift
baseline. To run them locally without invoking Swift or the mutation tool:

```sh
python3 -B -m unittest discover -s scripts/tests -v
```

## Equivalent survivor and a future gate

The reviewed equivalent survivor is the `LogicalOperatorReplacement` mutation
in `FocusMonitorState.init(baseline:)` in `FocusMonitor.swift`: it changes
`baseline.pid == nil || baseline.window == nil` to use `&&`. Before initialization
finishes, the window-registration branch independently marks every incomplete
baseline as inconclusive. The state is private and cannot be observed by callers
before that branch runs; existing tests exercise each incomplete combination.
With the pinned tool, its fingerprint is `08207af35af5190908b1899e0766ed82`.
Keep this mutation visible in reports. Its assessment and validation evidence are
recorded in [the validation history](validation.md#shared-lifecycle-and-focus-mutation-scope--2026-11-05).
Reassess equivalence if the initialization or observation lifecycle changes.

A later gate should detect new unexplained `Survived` or `NoCoverage` mutations
against an explicitly reviewed baseline, rather than require a blanket 100%
score. Exceptions should identify the source, operator, original/replacement
expression, and stable fingerprint, with a rationale and review evidence. Do not
use line numbers or total counts alone: one survivor disappearing must not hide
a different one appearing. Review new or changed exceptions and remove or
reassess stale ones when source, scope, operators, or tool version changes.
Compile errors, timeouts, and activation warnings should remain separately
visible for review; exceptions must never suppress baseline, tool, or report
integrity failures. No survivor/coverage gate or automatic exception approval is
enabled by this workflow.

# Local mutation testing

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

There is no CI mutation gate. A score applies only to the configured files and
operators, and does not establish live Teams compatibility.

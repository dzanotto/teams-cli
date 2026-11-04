# Project simplification review

## Goals and scope

Prioritize **maintainability and simple design** through clearer responsibilities and removal of unused paths—not a broad generic rewrite.

This review is based on source and test inspection at commit `1f64a0c`. No implementation changes, automated checks, or live Teams operations were performed as part of the review. Line references describe that revision and may move as the code evolves.

## 1. Separate discovery evidence from timing diagnostics

**Highest-value design improvement · moderate effort**

In `Sources/TeamsCore/TeamsCompatibilityProbe.swift:43–76`, the compatibility check creates a `CommandTimings` recorder and then retrieves main-window recognition results through:

```swift
timings.spans.flatMap(\.discoveryScans).last?.windows
```

`scripts/MainWindowAudit.swift` also uses recorded timing data to determine its exit code.

That makes diagnostic infrastructure carry evidence needed for functional decisions. Understanding compatibility now requires understanding the timing recorder’s span structure and retry history.

**Suggested simplification:** return per-window recognition/completeness evidence directly from discovery, through an internal result type. Let compatibility checks consume that evidence, and let timing instrumentation record it separately.

Preserve the existing distinction between the returned snapshot’s final scan and the audit’s scan history.

## 2. Make discovery modes explicit

**Small, focused improvement · low-to-moderate risk**

`Sources/TeamsCore/TeamsAccessibilityReader.swift:52–62` has two interacting flags:

- `auditMainWindows`
- `excludeMainWindows`

Their precedence is resolved inside the traversal, particularly around lines 136, 177, 207, and 264. Audit mode overrides exclusion, so four Boolean combinations represent only three meaningful policies.

**Suggested simplification:** replace them with a named mode, such as:

- normal discovery;
- full discovery;
- main-window audit.

Keep microphone/camera-only exclusion explicit. This makes callers easier to understand and removes combinations whose meaning depends on hidden precedence.

## 3. Remove unused paths and correct misleading organization

**Best first cleanup · low risk**

Concrete opportunities:

- `Sources/TeamsCore/MediaActionController.swift:63`: `set(_:)` has no callers; all three control adapters use `perform(targetFor:)`.
- `Sources/TeamsCore/TeamsMediaCommandSupport.swift:28` and `:52`: the two convenience overloads that supply `.live` have no callers; current callers supply an environment.
- `TeamsMediaCommandSupport.swift` contains both lifecycle orchestration and the substantial `NativeMediaBackend` implementation. Give the backend its own appropriately named file.
- `Sources/TeamsCore/MicrophoneStatus.swift` houses shared `ControlSnapshot`, `WindowSnapshot`, and `ExcludedWindow` types.
- `MicrophoneCommandError` is used for shared locking/setup/cleanup failures, including call-end and compatibility operations. A shared name and location would better reflect its responsibility; preserve an alias if source compatibility matters.

These changes reduce navigation and conceptual noise without introducing another abstraction layer.

## 4. Give the CLI execution method fewer responsibilities

**Useful localized refactor · moderate effort**

`Sources/TeamsCLI/CommandRunner.swift:170` mixes:

- action dispatch;
- status discovery and window selection;
- classification;
- result-to-output conversion;
- error mapping;
- exit-code selection.

The four action branches repeat essentially the same output construction.

**Suggested simplification:** extract focused action, status, and error-output helpers, with output conversion next to `Output`.

Keep the explicit command switch. A command registry or protocol hierarchy would likely make this small command set harder to follow. Likewise, do not redesign TeamsCore’s public result types merely to shorten CLI mapping.

## 5. Consolidate tests around the already-shared action engine

**Potentially large maintenance benefit · needs careful coverage mapping**

These suites contain repeated scenarios for target replacement, focus loss, no-ops, uncertain presses, and consecutive verification:

- `Tests/TeamsCoreTests/MicrophoneControllerTests.swift`
- `Tests/TeamsCoreTests/CameraControllerTests.swift`
- `Tests/TeamsCoreTests/HandControllerTests.swift`

Production behavior already lives in `MediaActionController`, but much of its testing is repeated through each wrapper, often separately for set and toggle.

**Suggested simplification:** put common safety scenarios in a direct shared-controller suite or a small scenario harness. Retain control-specific tests for:

- target resolution and state mapping;
- camera readiness;
- hand incomplete-read recovery;
- each wrapper’s policy configuration;
- native adapter integration.

Avoid a sophisticated generic test framework. The aim is to maintain each shared rule in fewer places, not simply reduce test count.

## What to leave alone

- **Separate call-end behavior:** its identity, completion, and focus rules genuinely differ.
- **The shared action state machine:** it already captures the important common behavior.
- **Fresh dispatch checks, single-use preflight evidence, and explicit cleanup:** these are safety mechanisms, not redundant ceremony.
- **Distinct microphone/camera/hand adapters:** some repetition is easier to understand than a highly configurable universal controller.

## Recommended order

1. Start with unused paths and organization (**#3**).
2. Make discovery modes explicit (**#2**).
3. Separate discovery evidence from timing diagnostics as an independent design change (**#1**).
4. Treat CLI and test restructuring (**#4** and **#5**) as independent follow-ups.

# Checking a Teams update

The repository diagnostic checks the installed Teams app through the current
checkout's TeamsCore implementation. It reads Accessibility state and advertised
button capabilities. It never presses a control, activates Teams, restores focus,
changes `AXEnhancedUserInterface`, or opens a permission prompt. It uses the normal
WebView-helper role read to make the Accessibility tree available.

## Run a check

1. Restart Teams after updating it, so the running process corresponds to the app
   bundle version recorded in the report.
2. Keep the Teams main window open and join exactly one non-held call. Keep your
   own video tile visible; it supplies hand-state evidence, even with camera off.
3. Run from a terminal with Accessibility permission. Keep focus still while the
   check runs; Teams can stay in the background.

```sh
bash scripts/check-teams-compatibility.sh --language en
```

Supply the Teams UI language, such as `en` or `it`. The tool does not infer the
language from macOS settings; without this flag it records `unknown`. Existing
language limitations still apply, particularly the English self-video description
required for hand status.

The first run compiles a separate Swift diagnostic; subsequent runs reuse it until
its sources, compiler, SDK path, or architecture change. Swift 6+ and the Command
Line Tools or Xcode are required. Generated binaries, module cache, and the default
report stay in ignored `.build/teams-compatibility/`. Old cached binaries can be
removed by deleting that directory, which also removes reports saved there.

The check prints a readable summary and writes
`.build/teams-compatibility/latest.json`. Use `--json` for JSON on stdout and
`--output FILE` to choose the report destination. Custom destination directories
must already exist. Paths are relative to your current working directory. Run
`--help` to inspect options without reading Teams.

## Save and compare a baseline

Before an update, save a passing report:

```sh
bash scripts/check-teams-compatibility.sh --language en \
  --save-baseline .build/teams-compatibility/baseline.json
```

After updating and restarting Teams, repeat in a similar call/window configuration:

```sh
bash scripts/check-teams-compatibility.sh --language en \
  --baseline .build/teams-compatibility/baseline.json
```

Baselines are written only when every required read-only check passes. A failed or
inconclusive run leaves the saved baseline unchanged. Nothing promotes a run to the
baseline automatically: pass `--save-baseline` again to replace it deliberately.
`--baseline` and `--save-baseline` can reference the same file; `--output` must be
different from both. Invalid, incompatible-schema, and non-passing baselines are
rejected before inspection or report writes.

The comparison reports changed check outcomes/reasons and environment metadata.
Normal microphone, camera, and hand state differences do not count as regressions.
It flags scan duration above twice the baseline with an increase over 250 ms as an
advisory warning, without changing the exit code. Repeat measurements under similar
conditions before attributing a slowdown to an update. Compilation, report I/O and
process startup are excluded from recorded timings.

## Interpret the result

| Exit code | Result | Meaning |
| --- | --- | --- |
| `0` | `PASS` | All required read-only checks passed; also used for help. |
| `1` | `FAIL` | A complete observation exposed an unsupported label, missing/duplicate control, or conflicting main-window layout. |
| `2` | `INCONCLUSIVE` | Preconditions or evidence were insufficient, with no definitive failing check. |
| `64` | Usage error | Invalid options or overlapping report/baseline destinations. |
| `74` | Report error | Baseline validation, decoding, or file I/O failed. |

Compilation failures occur before a report can be produced and use the compiler's
nonzero exit code. A `FAIL` takes precedence over other inconclusive checks, but
does not itself prove that an update caused the problem. Compare the baseline and
check the call configuration.

The diagnostic checks permission, a single Teams process, complete full discovery,
one active call, the main-shell layout, all four control states, unique controls,
enabled flags and advertised `AXPress` actions. It checks foreground app/window
identity at the scan endpoints and confirms the Teams process generation is stable
through inspection. A process restart invalidates the structural/state evidence.
The full scan also covers content skipped by normal microphone/camera discovery;
call controls inside a recognized main shell fail its layout assumption.

No call, only held calls, multiple active calls, missing self-video, a closed or
unrecognized main shell, incomplete reads, disabled controls, unavailable focus,
and changed focus are inconclusive. A disabled button can reflect meeting policy
or a temporary transition. Keep the main shell open and repeat after transitions
settle. If a renamed Leave button makes the call unrecognizable, the result is
inconclusive (`no_call_controls`), not a claim that no call exists.

`axpress_not_advertised_read_only` is also inconclusive, even when state discovery
passes. Action commands temporarily enable `AXEnhancedUserInterface` through the
shared lock/setup/cleanup lifecycle before checking button actions. The diagnostic
does not perform that setup. Teams may therefore advertise different actions here
than it does during a real CLI command. This finding neither proves a regression
nor qualifies action compatibility; it remains visible and prevents saving a
passing baseline. The report records the enhanced Accessibility setting before
the scan and after the probe (`true`, `false`, or `unavailable`) without writing it.
A value of `true` alone does not establish that the action tree is ready.

The JSON report includes schema version, scope, timestamp, Teams bundle version
and build, user-supplied language, macOS version, source CLI version (`dev`), Git
revision and dirty state, enhanced Accessibility observations, fixed reason strings,
recognized states, and timings. Existing schema-v1 passing baselines remain usable;
older reports simply lack the enhanced Accessibility metadata.
It excludes AX snapshots, labels, meeting/window titles, participant names, and
application paths. The probe is compiled from this checkout; it does not exercise
a Homebrew/downloaded `teams-cli` executable. Check out the corresponding CLI tag
when qualifying that version. A dirty checkout is identified but is not a uniquely
reproducible revision.

## Evidence limits

A pass establishes discovery and advertised capabilities for the observed state
and layout only. The check takes one full observation, not a transition test; it
cannot establish both sides of a toggle, transient focus safety, successful
Accessibility setup/cleanup, actual `AXPress` behavior, or call-end verification.
Endpoint focus comparisons can miss transient focus changes. No audio/video
delivery is measured.

Live action qualification remains a separate, explicitly authorized test in a
disposable call: microphone/camera/hand in both directions, then Leave last, using
the existing controllers and stopping on any uncertain outcome. That action
harness is not part of this read-only diagnostic. Cold startup, minimized windows,
other languages and other call layouts require their own observations.

`swift test` exercises this diagnostic with scripted Accessibility trees, including
layout conflicts, changed labels, unavailable evidence, capability reads, process
changes, privacy, and baseline validation. It does not launch or control Teams.

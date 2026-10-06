# Validation Notes

Historical evidence collected on 2026-10-05 and 2026-10-06, condensed from the
original README. These checks describe the builds and local sessions tested at
the time; they are not a fresh validation of every subsequent change. Performance
comparisons below retain their original baselines and measurement caveats.
See the [README](../README.md) for current command behavior and how to run tests.

## Live checks and remaining gaps

The environment recorded for the 2026-10-05 checks was macOS 27.0.1 on Apple Silicon
with Teams 26213.1006.5011.1671.

| Area | Recorded evidence | Limits |
| --- | --- | --- |
| Status and call selection | Multiple microphone states returned `ambiguous`; explicit selection and held-call exclusion worked with `focus_unchanged: true`. Camera-on status also excluded the held call. | Cold startup after restarting Teams and minimized-window behavior were not validated. |
| Microphone mute/unmute | A revised build completed both transitions and repeated desired-state no-ops, with verified cleanup and independent final status reads. | Successful action checks used one active call and no held call; held-call filtering had separate read-only and automated evidence. |
| Microphone toggle | User-confirmed manual testing, followed by successful measured live toggles on 2026-10-06. | Timings and outcomes apply to the tested local sessions. |
| Camera on/off and toggle | The user manually tested both features and confirmed they worked. | No automated live camera cycle was recorded. |
| Call end | The user manually tested leaving a call and confirmed it worked. | No automated live call-end test was recorded. |
| Hand status and raise/lower | Diagnostics exposed stale button descriptions; the revised implementation read the own-video indicator. A subsequent independent status read confirmed `lowered`, and the user confirmed revised raise/lower commands worked. | Camera-off tile descriptions had automated coverage only. |
| Hand toggle | Automated toggle coverage, release build, help, and invalid-argument checks passed for the change. | No live hand-toggle actions were run for that change. |

English labels were checked locally. Italian microphone/camera mappings and
supported Leave-label variants had automated coverage; these checks do not
establish compatibility with an Italian Teams installation. Reported media states
reflect Teams' UI, not physical capture or receipt by other participants.

## Diagnostic findings

### Microphone press without a verified change

The initial live `mic mute` dispatched one `AXPress`, but the microphone remained
unmuted, also confirmed by the user. The CLI returned exit 6 with
`verification_timeout`, `action_attempted: true`, and `changed: null`. No focus
change was observed and the CLI did not retry.

After temporary enhanced Accessibility setup was added, read-only diagnostics
verified setup and restoration without observed focus changes. On a new call,
a revised build completed `muted` → `unmuted` → `muted` and both no-ops, all with
exit 0, `success: true`, verified cleanup, and `focus_unchanged: true`. Independent
reads confirmed the final microphone and camera states. Both the call and
Accessibility setup had changed between trials, so this did not isolate the cause
of the earlier no-effect press.

### Stale hand-button descriptions

Early hand status used the button's `AXCustomContent` action description. Later
manual testing found successful hand changes with failed CLI verification.
Authorized diagnostics reproduced raise and lower attempts where that description
remained stale through verification and six post-cleanup reads. During lowering,
the own-video raised marker disappeared on the first post-press read, approximately
0.34 seconds after the preflight sample, and stayed absent.

The implementation switched to the own-video indicator for status, preflight,
and verification. A rebuilt release then independently reported `hand: lowered`,
exit 0, and `focus_unchanged: true`; the user confirmed the revised raise/lower
commands worked. Stale descriptions and incomplete scans have regression tests.
The originally reported `inspection_incomplete` failure was not reproduced live;
bounded recovery from incomplete verification scans was tested automatically.
The earlier diagnostic attempts used the superseded implementation.

## Performance measurements — 2026-10-06

### Discovery consolidation

Alternating two-toggle pairs between the readiness-polling release and the discovery-consolidation
candidate produced four measurements per binary. All eight toggles returned
`success: true`, `changed: true`, and `focus_unchanged: true`; independent status
reads confirmed the microphone started and finished unmuted. The candidate's
median was 1.000 seconds (range 0.959–1.098), compared with 1.073 seconds
(range 0.953–1.218) for the baseline in the same session. The observed median
reduction was 73 ms (6.8%). Ranges overlap and there are only four runs per binary,
so this is preliminary timing evidence. Median CLI CPU time fell from 89.4 to
75.9 ms; this excludes Teams' CPU usage. These results measure command completion
and Teams-reported UI state, not audio delivery. Camera and hand actions share
the consolidated backend but were not tested live in this validation.

### Instrumented comparison

A temporary copy of the release at the time used the same buffered, monotonic
timing spans as the initial profile. All six
microphone toggles succeeded with `focus_unchanged: true`; independent status
reads confirmed the microphone started and finished unmuted. The table compares
arithmetic means from six instrumented toggles per version, in milliseconds.
The initial and revised runs occurred at different times, so UI and load
differences remain possible; these are observed timings, not isolated causal
estimates for each change.

| Stage | Initial mean (ms) | Revised mean (ms) |
| --- | ---: | ---: |
| Accessibility setup | 416.5 | 10.2 |
| Accessibility cleanup | 402.6 | 1.0 |
| Full UI reads | 738.0 | 631.0 |
| Verification waits | 306.4 | 306.6 |
| Focus monitoring | 28.0 | 28.5 |
| Button-press dispatch | 0.09 | 0.12 |
| Other, including startup and output | 52.5 | 38.3 |
| **Total** | **1,944.2** | **1,015.7** |

Every revised run performed four full reads instead of five. Both accessibility
readbacks matched on their first poll, with no polling sleeps in these runs.
The initial profile averaged 4,960 visited nodes per command and the revised
profile averaged 4,008; average scan sizes were approximately 992 and 1,002 nodes.
UI reads and verification waits in the revised build accounted for approximately 92% of command
time. "Other" includes trace serialization/output and process startup/exit;
the instrumented revised median was 1.003 seconds (range 0.854–1.140).
The temporary profiling build did not change the normal release executable.

### Accessibility readiness polling

Six release-candidate microphone toggles all returned `success: true`,
`changed: true`, and `focus_unchanged: true`.
Independent status reads before and after confirmed the microphone started and
finished unmuted. Median command time was 1.641 seconds (range 1.598–1.672),
compared with 1.955 seconds (range 1.853–2.059) in six earlier runs of the previous
release. This is an observed reduction of 314 ms (16%); the runs were measured
separately, so changes in Teams' UI and system load are not controlled for.
The measurement includes process startup, output, verification, and cleanup;
it measures Teams-reported state, not audio delivery. Camera, hand, and call-end
actions share the updated accessibility lifecycle but were not tested live in
this validation.

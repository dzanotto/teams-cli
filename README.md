# Teams CLI for macOS

Reads microphone mute and camera on/off states in the Microsoft Teams desktop app
and provides microphone mute/unmute/toggle, camera on/off/toggle, and call-end commands.
It does not explicitly activate Teams, raise windows, send keyboard shortcuts,
or restore focus. Media commands enforce focus checks; leaving a call allows
Teams to change focus.

## Build and run

Requires macOS 13 or later and Swift 6 or later (Xcode or Command Line Tools).
There are no third-party dependencies.

```sh
cd teams-cli
swift build -c release
.build/release/teams mic status
.build/release/teams mic status --json
.build/release/teams camera status
.build/release/teams camera status --json
.build/release/teams mic mute --json
.build/release/teams mic unmute --json
.build/release/teams mic toggle --json
.build/release/teams camera on --json
.build/release/teams camera off --json
.build/release/teams camera toggle --json
.build/release/teams call end --json
```

The executable is already built at `.build/release/teams` in this workspace.
It can be invoked by absolute path from another directory.

For one identified call window, microphone output is `muted` or `unmuted`;
camera output is `on` or `off`. These describe the corresponding Teams button's
state. They do not measure audio/video capture, physical device switches,
device permissions, or whether remote participants receive the media.

Calls on hold are excluded automatically. A held call is identified by an exact
`resume-button` Accessibility button in the same window as `hangup-button`;
a muted or disabled microphone alone is not evidence that a call is on hold.
Held windows appear in JSON as `excluded_windows` with the reason `on_hold`.
If every detected call is on hold, the result is `unknown` with reason
`all_calls_on_hold`, including when `--window` explicitly selects a held call.

If Teams exposes multiple remaining call windows, the command returns `ambiguous`
and reports each window separately. Use the index in the JSON output to select one:

```sh
.build/release/teams mic status --json --window 1
```

Indices are 1-based positions in Teams' current accessibility window list.
They can change when windows open, close, or reorder. Refresh `--json` before
selecting a window; indices are not persistent meeting identifiers. The CLI
never silently selects the first call. Multiple microphone controls with
conflicting labels within a selected window are also ambiguous. The same rules
apply to camera controls, and `--window N` is supported by both commands.

Example for multiple call windows (states and indices are illustrative):

```json
{
  "excluded_windows": [],
  "focus_unchanged": true,
  "microphone": "ambiguous",
  "reason": "multiple_call_windows",
  "windows": [
    { "state": "muted", "window": 1 },
    { "state": "unmuted", "window": 2 }
  ]
}
```

For camera JSON, the top-level status key is `camera`; microphone JSON continues
to use `microphone`. Both include `windows`, `excluded_windows`, and any reason.

For status commands, `focus_unchanged` compares the foreground application and its focused
window before and after the read. It is omitted when either window cannot be
inspected. This is an endpoint comparison, not continuous monitoring; a user
switching windows while the command runs may make it `false`. The command never
attempts to restore focus, since doing so could override a deliberate user action.

## Microphone and camera controls

`teams mic mute`, `teams mic unmute`, `teams camera on`, and `teams camera off`
request a specific state. When that state is already present, they succeed
without pressing anything, even if the button is disabled. This no-op confirms
the existing Teams-reported state.

`teams mic toggle` and `teams camera toggle` request the opposite of the first
confirmed state for the chosen control: muted becomes unmuted and vice versa;
camera on becomes off and vice versa. The read and change run under
the same process lock and checks as the explicit state commands. The desired
state stays fixed through rechecks: if someone else reaches it before the command's pre-press read,
the command succeeds without pressing (`changed: false`, `action_attempted: false`).
A later state change detected at dispatch is refused. Each new invocation reads
the current state again; toggle is not idempotent.

All media action commands require exactly one non-held call
with a known state for the requested control. `--window` is deliberately
limited to status reads because its indices can reorder between invocations.

Before a change, the command rereads Teams, pins the current process generation
and exact window/media-button/hang-up objects, checks that the chosen control is enabled
and supports `AXPress`, then rechecks the live label and focus. It dispatches at
most one press and requires two consecutive observations of the desired state.
For camera changes, those observations must also show that the camera button is
enabled and supports pressing again: a temporarily disabled button during startup
is allowed to settle within the verification budget, without another press.
It never repeats an uncertain press or restores the old media state as an
automatic recovery action.

Action commands temporarily enable Teams' `AXEnhancedUserInterface` attribute
when its known original value is false. They verify the readback and restore the
original value on completion, only for the same Teams process generation.
Unavailable setup or unverified cleanup is reported as a failure. Status commands
do not write this attribute. Cleanup finishes before the final focus check;
deferred cleanup cannot issue later writes.

Media actions use activation and focused-window notifications in addition to focus
snapshots. Unavailable focus evidence or an observed focus change causes refusal
before dispatch, or an unverified result afterward. Nothing attempts to restore
focus. Notifications are best effort: the monitor detects reported changes but
cannot guarantee that a Teams version will never shift focus during a press.

JSON retains the corresponding `microphone` or `camera` status fields and adds:

| Field | Meaning |
| --- | --- |
| `action` | `mute`, `unmute`, `toggle`, `on`, or `off` |
| `success` | Requested state confirmed with focus preserved |
| `action_attempted` | An `AXPress` was dispatched or may have been dispatched |
| `changed` | `false` for a no-op/refusal, `true` after verified change, `null` when an attempted action's outcome is uncertain |

Microphone, camera, and call-end commands share a per-user process lock so concurrent CLI
invocations cannot overlap actions or accessibility setup/cleanup.
A second invocation returns `command_in_progress`
without waiting or pressing. The lock file stays in `/tmp`; the OS releases the
lock when the process exits. Action sampling has an eight-second shared budget
with at most eight verification observations for microphone changes and twenty
for camera changes and call end; observations are spaced by 150 ms waits, and in-flight AX
calls add overhead.

Teams exposes a toggle rather than an atomic set-state API. Fresh reads and the
process lock narrow races, but another controller or user can still change Teams
between a check and the press. AX object identity also cannot prove a meeting's
identity if Teams reuses the same objects. No handles persist between commands.
On an unverified outcome, inspect status and the situation before issuing a new
command.

## Leaving a call

`teams call end` presses the Leave button for your one active, non-held call.
It leaves your participation; it does not choose Teams' "End meeting for all"
action. It requires a recognized Leave label, one enabled `hangup-button` with
`AXPress`, and an unambiguous call. Missing controls, all-held calls, duplicate
Leave buttons, or multiple active calls cause refusal. `--window` is not supported
for actions. This command does not resume held calls or dismiss confirmation dialogs.

Focus changes are allowed by default for this command, as requested. Teams can
bring its main window forward when the call window closes. `focus_unchanged` is
reported when available, but a focus change or unavailable focus evidence does
not make an otherwise verified call end fail. Microphone and camera commands
retain their existing focus requirements.

The command pins the Teams process generation and exact call-window/Leave-button
objects, rereads them before dispatch, and sends at most one press. To report
`ended`, two consecutive complete scans must show that the pinned call window
has disappeared, the original Teams process still has another inspectable window,
and no non-held call controls remain. Held windows remain listed in
`excluded_windows`. No call controls at startup do not mean "already ended".

Missing controls alone, an empty window list, a replaced process or call,
incomplete reads, and a timeout cannot confirm completion. A call hosted inside
a window that remains open after leaving may therefore end successfully in Teams
while the CLI returns an unverified result. An uncertain result never triggers
another press or attempts to rejoin the call.

With `--json`, the status key is `call`, the action is `end`, and successful
completion reports `call: ended`, `success: true`, `changed: true`, and
`action_attempted: true`. An uncertain attempted action reports `call: unknown`,
`success: false`, and `changed: null`. Accessibility cleanup must still succeed.
The shared lock, setup/cleanup lifecycle, eight-second sampling budget, and
bounded verification used by media commands also apply to call end.

## Accessibility permission

The terminal or launcher running the CLI must have macOS Accessibility access.
In **System Settings → Privacy & Security → Accessibility**, enable your terminal
app or launcher. If macOS attributes the request to the executable instead, add
the absolute path to `teams` using the `+` control. Then rerun the command.

The CLI checks permission without prompting and does not open System Settings.
Changing the launcher or rebuilding/moving a directly authorized executable may
require granting access again. A sandboxed runner can also prevent access to
other applications; run the CLI from a normal terminal in your logged-in desktop
session. No administrator privileges, microphone access, or screen recording
permission are requested by this program.

## Exit codes

| Code | Output | Meaning |
| --- | --- | --- |
| 0 | `muted` / `unmuted` / `on` / `off` / `ended` | A recognized media state or verified call end |
| 2 | `unknown` / `ambiguous` | Inconclusive read or multiple possible controls |
| 3 | `permission_denied` | Accessibility permission unavailable |
| 4 | `not_running` | Teams was not found after the permission check |
| 5 | `unknown` | Accessibility communication failed |
| 6 | `unknown` / `ambiguous` | Action refused, busy, or outcome/focus not verified |
| 64 | Usage on stderr | Invalid command or options |

With `--json`, stdout is one JSON object; otherwise stdout is one status word
and additional diagnostics go to stderr. `reason` is present for inconclusive
or failed results. Per-window states in an `inspection_incomplete` result are
observations from a partial scan, not definitive overall status.

## Implementation and limits

- Uses [Apple's Accessibility API](https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication)
  to inspect `com.microsoft.teams2` and its embedded WebView helper.
- Reads the browser helper's `AXRole` to initialize its native accessibility
  tree. This behavior is visible in the
  [Chromium implementation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm).
  Status reads do not write accessibility attributes or enable a screen reader.
  Action commands additionally use the temporary exposure described above.
- Matches only `AXButton` controls with the exact `microphone-button` identifier,
  with a `hangup-button` in the same window. Participant microphone labels and
  pre-join controls are excluded. `Mute mic` means currently unmuted; `Unmute mic`
  means currently muted.
- Camera status uses the exact `video-button` identifier in a window with a
  `hangup-button`. `Turn camera off` means currently on; `Turn camera on` means
  currently off. Microphone and camera states are classified independently.
- An exact `AXButton` with identifier `resume-button` and a `hangup-button` in
  the same window identifies a call on hold. This was observed live; Microsoft's
  [hold instructions](https://support.microsoft.com/en-gb/teams/calls-devices/put-a-call-on-hold-in-microsoft-teams)
  also describe Resume as the way to return to a held call. Unrelated resume
  controls, participant text, and microphone enabled state are not used to
  exclude calls. Incomplete scans still return `unknown`.
- English labels were verified locally. Italian `Attiva microfono`,
  `Disattiva microfono`, `Attiva videocamera`, and `Disattiva videocamera`
  mappings are unit-tested but have not been verified against an Italian Teams
  installation. Other labels return `unknown`.
- Call end accepts exact `Leave`, `Hang up`, `Esci`, and `Abbandona` labels
  (including supported shortcut suffixes). These mappings are unit-tested.
  Other labels are refused; manual command validation is recorded below.
- Missing controls are `unknown`, never assumed muted or out of a call. Hidden
  or minimized content, unsupported Teams versions, an uninitialized web tree,
  or a changing UI can make a read inconclusive. Retrying may help after the
  interface finishes loading.
- Traversal has a 12,000-node cap, depth limit, shared eight-second scan budget,
  and short per-message timeouts. In-flight Accessibility requests and setup
  add some overhead; this is not a hard real-time deadline.
- Status commands perform no call actions. Changes use only the exact
  microphone, camera, or Leave button's `AXPress` action. There is no explicit activation, window raising,
  key/mouse event injection, network request, or logging of chat/meeting text.
- Uses observed Teams UI identifiers, not a supported Microsoft control API;
  future Teams updates may require changes. The older third-party integration
  API is unsuitable for a new dependency: [Elgato documents its discontinuation](https://www.elgato.com/us/en/explorer/products/stream-deck/control-microsoft-teams-meetings-with-stream-deck/).

## Validation

```sh
swift test
```

The 122 automated tests cover label inversion, language/shortcut handling, pre-join and
participant exclusions, conflicting/duplicate controls, multiple call windows,
unknown labels, incomplete reads, and held-call exclusion (including all-held
and explicitly selected held windows). Camera tests additionally check that
microphone state does not influence camera status.
Controller tests cover both desired states, no-ops, state and target races,
disabled controls, focus refusal/loss, uncertain errors, stable confirmation,
pre-dispatch rejection, and the no-retry rule.
Camera-controller tests also exercise delayed startup and temporarily disabled
controls without repeating the press or confirming success prematurely.
Toggle tests cover both directions, repeated invocations, concurrent state changes,
held-call exclusion, target identity, unavailable states/controls, focus checks,
stable confirmation, and uncertain outcomes without retries.
Camera toggle also waits through delayed startup and requires two consecutive
observations with the desired state and a ready camera control after a press.
Call-end tests cover Leave labels, refusal of "End meeting for all", call selection,
held calls, target races, two consecutive closure observations, uncertain outcomes,
the focus-change exception, cleanup failures, and the no-retry rule.

Live validation on 2026-10-05: macOS 27.0.1, Apple Silicon, Teams
26213.1006.5011.1671. The release executable read two call windows with different
microphone states and returned `ambiguous`, with `focus_unchanged: true`.
Background probing also succeeded while Ghostty remained foregrounded.
An explicit window selection returned `muted` with `focus_unchanged: true`;
window reordering was also observed during validation. Cold startup after
restarting Teams and minimized-window behavior have not yet been
validated. Control-command validation is described below.

After adding held-call exclusion, the release executable returned `unmuted`
for the remaining call (window 3) and listed window 2 in `excluded_windows`
with reason `on_hold`. The read completed in approximately 0.44 seconds with
`focus_unchanged: true`. Read-only inspection also found the held call's
`resume-button`, `hold-timer`, and an `On hold` status; Mattermost remained
foregrounded throughout that inspection. No call state was changed for testing.

Camera status was also verified live: `teams camera status --json` returned
`camera: on`, excluded the held call, and reported `focus_unchanged: true`.
The read took approximately 0.37 seconds. Camera off is covered by classification
tests; no camera toggles were performed for this check.

Mute/unmute builds and all 58 automated tests pass. The first live `mic mute`
dispatched one `AXPress`, but the microphone remained unmuted; the user also
confirmed no change. The command returned exit 6, `verification_timeout`,
`action_attempted: true`, and `changed: null`, with no focus change observed.
The test stopped without another press.

Temporary enhanced accessibility setup was then added. Read-only diagnostics
verified setup and restoration with no focus changes observed.
A later status read found no call controls while
the user changed calls; this is not evidence that setup restoration hid them.
The new call subsequently returned microphone `muted` and camera `off`, with
`focus_unchanged: true` for both reads.

With the user's approval, the revised release executable was tested on that new
call. Both microphone transitions succeeded: `muted` → `unmuted` → `muted`.
Repeating each desired-state command succeeded without another press
(`changed: false`, `action_attempted: false`). All four action invocations
returned exit 0 and `success: true`, including verified accessibility cleanup.
No focus changes were observed; every result reported `focus_unchanged: true`.
The actual transitions took approximately 1.75 and 1.76 seconds; no-ops took
approximately 1.05 seconds each. The final independent reads returned microphone
`muted` and camera `off`. No camera actions were dispatched.

This qualifies the commands for the tested call and local Teams/macOS version,
not every Teams configuration. Because both the call and accessibility setup
changed between trials, the test does not isolate the cause of the earlier
no-effect press. There was one active call and no held call in the successful
action run; held-call filtering has the earlier read-only and automated evidence.

Camera on/off commands build successfully, and all 74 tests pass (including 16
camera-controller tests). Release CLI checks also passed for six help forms and
nine invalid operation/option combinations. The rebuilt executable read camera
`on` and microphone `muted`, with `focus_unchanged: true` for both status commands.
The user subsequently tested camera on/off manually and confirmed that everything
works. No automated live camera cycle was run.

Microphone toggle builds successfully, and all 86 tests pass (including 12 new
toggle tests). Release CLI checks passed for nine help forms and ten invalid
argument combinations. The user subsequently tested microphone toggle manually
and confirmed that it works. No automated live microphone toggle was run.

Camera toggle builds successfully, and all 98 tests pass (including 12 new
camera-toggle tests). Release CLI checks passed for ten help forms and fourteen
invalid argument combinations. The user subsequently tested camera toggle manually
and confirmed that it works. No automated live camera toggle was run.

Call end builds successfully, and all 122 tests pass (including 24 new call-end
tests). Release CLI checks passed for eleven help forms and twenty-seven invalid
argument combinations. Action-refusal checks verified the JSON fields for call,
microphone, and camera commands and plain-text call output; the sandbox returned
`accessibility_permission_required` before any action or accessibility setup.
The user subsequently tested call end manually and confirmed that it works.
No automated live call-end test was run.

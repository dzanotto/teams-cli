# Teams CLI for macOS

Reads microphone mute and camera on/off states in the Microsoft Teams desktop app
and provides explicit microphone mute/unmute commands. It never activates Teams,
raises its windows, sends keyboard shortcuts, or restores focus as a workaround.
Camera controls and leaving a call are future work.

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

## Mute and unmute

`teams mic mute` and `teams mic unmute` request a specific state. When that state
is already present, they succeed without pressing anything. Both commands require
exactly one non-held call with a known microphone state. `--window` is deliberately
limited to status reads because its indices can reorder between invocations.

Before a change, the command rereads Teams, pins the current process generation
and exact window/microphone/hang-up objects, checks that the microphone is enabled
and supports `AXPress`, then rechecks the live label and focus. It dispatches at
most one press and requires two consecutive observations of the desired state.
It never repeats an uncertain press or restores the old microphone state as an
automatic recovery action.

Action commands temporarily enable Teams' `AXEnhancedUserInterface` attribute
when its known original value is false. They verify the readback and restore the
original value on completion, only for the same Teams process generation.
Unavailable setup or unverified cleanup is reported as a failure. Status commands
do not write this attribute. Cleanup finishes before the final focus check;
deferred cleanup cannot issue later writes.

Actions use activation and focused-window notifications in addition to focus
snapshots. Unavailable focus evidence or an observed focus change causes refusal
before dispatch, or an unverified result afterward. Nothing attempts to restore
focus. Notifications are best effort: the monitor detects reported changes but
cannot guarantee that a Teams version will never shift focus during a press.

JSON retains the existing microphone status fields and adds:

| Field | Meaning |
| --- | --- |
| `action` | `mute` or `unmute` |
| `success` | Requested state confirmed with focus preserved |
| `action_attempted` | An `AXPress` was dispatched or may have been dispatched |
| `changed` | `false` for a no-op/refusal, `true` after verified change, `null` when an attempted action's outcome is uncertain |

Commands take a per-user process lock so concurrent CLI invocations cannot both
act on the same old state. A second invocation returns `command_in_progress`
without waiting or pressing. The lock file stays in `/tmp`; the OS releases the
lock when the process exits. Action sampling has an eight-second shared budget
with at most eight verification observations; in-flight AX calls add overhead.

Teams exposes a toggle rather than an atomic set-state API. Fresh reads and the
process lock narrow races, but another controller or user can still change Teams
between a check and the press. AX object identity also cannot prove a meeting's
identity if Teams reuses the same objects. No handles persist between commands.
On an unverified outcome, inspect status and the situation before issuing a new
command.

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
| 0 | `muted` / `unmuted` / `on` / `off` | A recognized media control in one call window |
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
- Missing controls are `unknown`, never assumed muted or out of a call. Hidden
  or minimized content, unsupported Teams versions, an uninitialized web tree,
  or a changing UI can make a read inconclusive. Retrying may help after the
  interface finishes loading.
- Traversal has a 12,000-node cap, depth limit, shared eight-second scan budget,
  and short per-message timeouts. In-flight Accessibility requests and setup
  add some overhead; this is not a hard real-time deadline.
- Status commands perform no call actions. Mute/unmute use only the exact
  microphone button's `AXPress` action. There is no activation, window raising,
  key/mouse event injection, network request, or logging of chat/meeting text.
- Uses observed Teams UI identifiers, not a supported Microsoft control API;
  future Teams updates may require changes. The older third-party integration
  API is unsuitable for a new dependency: [Elgato documents its discontinuation](https://www.elgato.com/us/en/explorer/products/stream-deck/control-microsoft-teams-meetings-with-stream-deck/).

## Validation

```sh
swift test
```

The 58 tests cover label inversion, language/shortcut handling, pre-join and
participant exclusions, conflicting/duplicate controls, multiple call windows,
unknown labels, incomplete reads, and held-call exclusion (including all-held
and explicitly selected held windows). Camera tests additionally check that
microphone state does not influence camera status.
Controller tests cover both desired states, no-ops, state and target races,
disabled controls, focus refusal/loss, uncertain errors, stable confirmation,
pre-dispatch rejection, and the no-retry rule.

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

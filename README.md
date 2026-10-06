# Teams CLI for macOS

Read and control your microphone, camera, and raised hand in the Microsoft Teams
desktop app, or leave your active call. The CLI uses macOS Accessibility and
reports Teams' UI state; it does not measure audio/video capture or delivery to
other participants.

## Build and run

Requires macOS 13+ and Swift 6+ (Xcode or Command Line Tools). There are no
third-party dependencies. From the repository root:

```sh
swift build -c release
.build/release/teams --help
```

The executable is written to `.build/release/teams`. Use that path in place of
`teams` in the command reference below, or invoke it by absolute path from another
directory.

## Accessibility permission

The terminal or launcher running the CLI must have macOS Accessibility access.
In **System Settings → Privacy & Security → Accessibility**, enable your terminal
app or launcher. If macOS attributes the request to the executable instead, add
the absolute path to `teams` using the `+` control.

The CLI checks permission without prompting or opening System Settings. Rebuilding
or moving a directly authorized executable, or changing its launcher, may require
granting access again. Sandboxed runners may prevent access to other applications;
run from a normal terminal in your logged-in desktop session. The program does
not request administrator privileges, microphone access, or screen recording.

## Command reference

All commands support `--json`. Only status commands support `--window N`.

| Command | Behavior |
| --- | --- |
| `teams mic status` | Read microphone state: `muted` or `unmuted` |
| `teams mic mute` | Mute the microphone |
| `teams mic unmute` | Unmute the microphone |
| `teams mic toggle` | Request the opposite microphone state |
| `teams camera status` | Read camera state: `on` or `off` |
| `teams camera on` | Turn the camera on |
| `teams camera off` | Turn the camera off |
| `teams camera toggle` | Request the opposite camera state |
| `teams hand status` | Read your own hand state: `raised` or `lowered` |
| `teams hand raise` | Raise your own hand, or succeed without pressing if already raised |
| `teams hand lower` | Lower your own hand, or succeed without pressing if already lowered |
| `teams hand toggle` | Request the opposite state for your own hand |
| `teams call end` | Leave your active call; report `ended` after verification |

`--help` and `-h` work on their own, after a command group, or after a complete
command, for example `teams hand --help` or `teams hand status --help`.

```sh
.build/release/teams mic status --json
.build/release/teams camera off
.build/release/teams hand toggle --json
```

## Selecting a call window

Calls on hold are excluded and listed in JSON as `excluded_windows` with reason
`on_hold`. A Resume control identifies a held call; a muted or disabled microphone
alone does not. If all detected calls are held, the result is `unknown` with reason
`all_calls_on_hold`, including when explicitly selecting a held window.

Multiple remaining call windows produce `ambiguous`; the CLI never silently
chooses the first. For status reads, use an index from the JSON output:

```sh
.build/release/teams mic status --json
.build/release/teams mic status --json --window 1
```

Indices are 1-based positions in Teams' current Accessibility window list. They
can change when windows open, close, or reorder, so refresh the output before
selecting one. Actions do not accept `--window` and require exactly one non-held
call. Conflicting controls within a window can also produce `ambiguous`.

## Action behavior

Microphone, camera, and hand actions require a recognized state. Commands requesting
a specific state succeed without pressing when that state is already present,
even if the button is disabled (`changed: false`, `action_attempted: false`).

A toggle requests the opposite of the first confirmed state and keeps that target
through subsequent checks. If another actor reaches it before the pre-press read,
the command succeeds without pressing; a later change detected at dispatch causes
refusal. Each invocation reads the current state again, so toggle is not idempotent.

All actions share these rules:

- Recheck the Teams process, target window, control identity, and press capability
  before acting. Dispatch at most one `AXPress` and require two consecutive
  verification observations before reporting a change. Camera verification also
  waits for its control to become ready after startup.
- Serialize actions with a per-user process lock. A concurrent action returns
  `command_in_progress` without waiting or pressing.
- Temporarily enable `AXEnhancedUserInterface` when its known original value is
  false, then verify restoration for the same Teams process. Unavailable setup or
  unverified cleanup is a failure. Status commands do not write this attribute.
- Bound sampling and verification. The shared action sampling budget is eight
  seconds; setup, cleanup, and in-flight Accessibility calls can add overhead.
- Never retry an uncertain press or automatically restore the previous state.
  Inspect status and the situation before issuing another command.

The CLI does not activate Teams, raise windows, inject keyboard/mouse input, or
restore focus. Microphone, camera, and hand actions require preserved focus:
missing focus evidence or an observed change causes refusal before dispatch or
an unverified result afterward. Monitoring is best effort and cannot guarantee
that a Teams version will never shift focus during a press.

Fresh checks and locking reduce races, but another user or controller can still
change Teams between a check and a press. Reused Accessibility objects also cannot
prove a meeting's identity.

### Leaving a call

`teams call end` leaves your participation using the Leave button. It does not
choose "End meeting for all", resume held calls, or dismiss confirmation dialogs.
It requires one recognized, enabled Leave control in one non-held call.

Focus changes are allowed for this command: Teams may bring its main window
forward when the call closes. `focus_unchanged` is reported when available, but
changed or unavailable focus evidence does not invalidate a verified call end.

To report `ended`, two consecutive complete scans must show that the pinned call
window disappeared, the same Teams process still has another inspectable window,
and no non-held call controls remain. Missing controls alone, an empty window list,
or no call at startup do not establish completion. A call hosted in a window that
stays open after leaving may end in Teams while the CLI returns an unverified result.

## Output and exit codes

Text output is one status word on stdout, with diagnostics on stderr. With
`--json`, stdout is one JSON object. The state key is `microphone`, `camera`,
`hand`, or `call`; results also contain `windows`, `excluded_windows`, and a
`reason` for inconclusive or failed outcomes.

Example for multiple call windows (indices and states are illustrative):

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

For status reads, `focus_unchanged` compares the foreground application and focused
window before and after inspection. It is omitted when either window cannot be
inspected. This endpoint comparison does not detect every intervening focus change;
a user switching windows during the read can make it `false`.

Action results add:

| Field | Meaning |
| --- | --- |
| `action` | `mute`, `unmute`, `toggle`, `on`, `off`, `raise`, `lower`, or `end` |
| `success` | Requested outcome and cleanup verified, with focus preserved for microphone, camera, and hand actions |
| `action_attempted` | An `AXPress` was dispatched or may have been dispatched |
| `changed` | `false` for a no-op/refusal, `true` after verified change, `null` when an attempted action's outcome is uncertain |

Successful call end reports `call: ended` and `success: true`. An uncertain
attempt reports `call: unknown`, `success: false`, and `changed: null`.
Per-window states in an `inspection_incomplete` result are partial observations,
not a definitive overall status.

| Code | Output | Meaning |
| --- | --- | --- |
| 0 | `muted` / `unmuted` / `on` / `off` / `raised` / `lowered` / `ended` | A recognized control state or verified call end |
| 2 | `unknown` / `ambiguous` | Inconclusive read or multiple possible controls |
| 3 | `permission_denied` | Accessibility permission unavailable |
| 4 | `not_running` | Teams was not found after the permission check |
| 5 | `unknown` | Accessibility communication failed |
| 6 | `unknown` / `ambiguous` | Action refused, busy, or outcome/focus not verified |
| 64 | Usage on stderr | Invalid command or options |

## Compatibility and limitations

- Uses observed Teams UI identifiers through Apple's Accessibility API. Teams
  updates can change or hide these controls; this is not a supported Microsoft
  control API. The CLI makes no network requests and does not log chat/meeting text.
- English microphone and camera labels were verified locally. Italian mappings
  are unit-tested but have not been verified against an Italian Teams installation.
  Call end recognizes `Leave`, `Hang up`, `Esci`, and `Abbandona`, including supported
  shortcut suffixes. Unrecognized labels produce `unknown` or action refusal.
- Hand state comes from your own video tile's English Accessibility description,
  alongside the hand and call controls. The button's action description can remain
  stale and is not state evidence. Missing, hidden, localized, or unrecognized tiles
  produce `unknown`; duplicate matching tiles produce `ambiguous`. Camera-off tile
  descriptions are unit-tested but have not been verified live. Tile descriptions
  and other participants' names are not included in output.
- The CLI does not open menus to reveal hidden controls. Missing controls and
  incomplete scans produce `unknown`, never an assumption that media is off or a
  call has ended. Cold startup after restarting Teams and minimized-window behavior
  have not been validated live.

## Testing

```sh
swift test
```

XCTest suites use fake backends and scripted observations to cover classification,
state transitions, races, focus checks, cleanup, and uncertain outcomes. Automated
tests do not establish compatibility with every Teams version. See
[validation notes](docs/validation.md) for historical live checks, known gaps, and
performance measurements, and [Repository Guidelines](AGENTS.md) for contribution
conventions.

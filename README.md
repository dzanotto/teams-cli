# Teams CLI for macOS

> [!IMPORTANT]
> **UNOFFICIAL PROJECT — NOT AFFILIATED WITH MICROSOFT.**
> This is an independent project. It is not developed, endorsed, sponsored, or
> supported by Microsoft. It is not a Microsoft product or an official Microsoft
> Teams integration.

Read and control your microphone, camera, and raised hand in the Microsoft Teams
desktop app, or leave your active call. The CLI uses macOS Accessibility and
reports Teams' UI state; it does not measure audio/video capture or delivery to
other participants.

## Install with Homebrew

Requires macOS 13+ and [Homebrew](https://brew.sh). Install from the custom
[`dzanotto/tap`](https://github.com/dzanotto/homebrew-tap) tap:

```sh
brew tap dzanotto/tap
brew install dzanotto/tap/teams-cli
teams-cli --help
```

The formula installs a prebuilt executable, so Swift is not required.
Grant [Accessibility permission](#accessibility-permission) to your terminal or
launcher before using the CLI.

## Download a release

Download an archive and `SHA256SUMS` from
[GitHub Releases](https://github.com/dzanotto/teams-cli/releases):

- `teams-cli-vX.Y.Z-macos-arm64.tar.gz` for Apple Silicon.
- `teams-cli-vX.Y.Z-macos-x86_64.tar.gz` for Intel.

In the download directory, run `shasum -a 256 --check --ignore-missing SHA256SUMS`
and confirm your archive is reported as `OK`. Extract the archive and run
`./teams-cli --help` from the extracted directory, or move `teams-cli` to a
directory on your `PATH`. The archives require macOS 13+; Swift is only needed
when building from source. Each archive contains only `teams-cli` and `LICENSE`
inside its versioned directory. Usage and installation documentation is available
in this repository.

Release binaries are not Developer ID signed or notarized. Accessibility access
is still required as described below.

## Build and run

Requires macOS 13+ and Swift 6+ (Xcode or Command Line Tools). There are no
third-party dependencies. From the repository root:

```sh
swift build -c release
.build/release/teams-cli --help
```

The executable is written to `.build/release/teams-cli`. Use that path in place of
`teams-cli` in the command reference below, or invoke it by absolute path from another
directory.

Ordinary source builds report `teams-cli dev` with `--version`, even from a tagged
checkout. To embed a release version, use the build script described in
[the release procedure](docs/releases.md#check-packaging-locally).

The executable was renamed from `teams` to `teams-cli`; no compatibility alias is
provided. Update existing scripts and integrations to use `.build/release/teams-cli`
or its absolute path.

## Accessibility permission

The terminal or launcher running the CLI must have macOS Accessibility access.
In **System Settings → Privacy & Security → Accessibility**, enable your terminal
app or launcher. If macOS attributes the request to the executable instead, add
the absolute path to `teams-cli` using the `+` control.

The CLI checks permission without prompting or opening System Settings. Rebuilding
or moving a directly authorized executable, or changing its launcher, may require
granting access again. Sandboxed runners may prevent access to other applications;
run from a normal terminal in your logged-in desktop session. The program does
not request administrator privileges, microphone access, or screen recording.

## Command reference

All Teams commands below support `--json`. Only status commands support `--window N`.
Microphone and camera toggles also support [`--timings`](#timing-diagnostics).

| Command | Behavior |
| --- | --- |
| `teams-cli mic status` | Read microphone state: `muted` or `unmuted` |
| `teams-cli mic mute` | Mute the microphone |
| `teams-cli mic unmute` | Unmute the microphone |
| `teams-cli mic toggle` | Request the opposite microphone state |
| `teams-cli camera status` | Read camera state: `on` or `off` |
| `teams-cli camera on` | Turn the camera on |
| `teams-cli camera off` | Turn the camera off |
| `teams-cli camera toggle` | Request the opposite camera state |
| `teams-cli hand status` | Read your own hand state: `raised` or `lowered` |
| `teams-cli hand raise` | Raise your own hand, or succeed without pressing if already raised |
| `teams-cli hand lower` | Lower your own hand, or succeed without pressing if already lowered |
| `teams-cli hand toggle` | Request the opposite state for your own hand |
| `teams-cli call end` | Leave your active call; report `ended` after verification |

`--help` and `-h` work on their own, after a command group, or after a complete
command, for example `teams-cli hand --help` or `teams-cli hand status --help`.

`teams-cli --version` prints the embedded build version, for example
`teams-cli 0.1.2`, followed by a newline. Ordinary source builds print `teams-cli dev`.
Use `--version` on its own; combining it with commands, `--json`, or other flags
returns exit code `64`. Help and version exit with code `0`, leave stderr empty,
and work without Teams running or Accessibility permission.

```sh
teams-cli mic status --json
teams-cli camera off
teams-cli hand toggle --json
```

## Selecting a call window

Calls on hold are excluded and listed in JSON as `excluded_windows` with reason
`on_hold`. A Resume control identifies a held call; a muted or disabled microphone
alone does not. If all detected calls are held, the result is `unknown` with reason
`all_calls_on_hold`, including when explicitly selecting a held window.

Multiple remaining call windows produce `ambiguous`; the CLI never silently
chooses the first. For status reads, use an index from the JSON output:

```sh
teams-cli mic status --json
teams-cli mic status --json --window 1
```

Indices are 1-based positions in Teams' current Accessibility window list. They
can change when windows open, close, or reorder, so refresh the output before
selecting one. Actions do not accept `--window` and require exactly one non-held
call. Conflicting controls within a window can also produce `ambiguous`.

Microphone and camera discovery recognizes the Teams main window using its profile
button and global search combo box, then skips the rest of that window. It reads
the window list and recognizes the shell again on every observation, without
caching window positions or using titles. Recognition is limited to the first
256 visited nodes and depth 24. Missing markers, failed recognition reads, or call
controls encountered before the match retain the full traversal. Call windows
still receive full scans; hand and call-end discovery are unchanged.

This optimization supports the Teams layout where calls open in separate windows.
It relies on the recognized main shell not hosting an embedded call toolbar;
controls deeper in excluded content cannot be checked. The read-only
`bash scripts/audit-main-window.sh` tool checks that assumption using full scans.

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

Microphone and camera actions wait 50 ms before each verification read, capped by
the remaining eight-second sampling budget. Both initial discovery reads,
dispatch, waits, and verification share that deadline; verification does not start
a new budget after pressing. Success still requires two consecutive complete
observations, and camera observations must also report a ready control. Reads
returning at or after the deadline cannot confirm success. Hand and call-end
retain their existing 150 ms waits and sample limits.

The microphone and camera deadline replaces the former limits of eight and twenty
verification samples. This gives slow transitions time to settle with the faster
polling cadence, but an unchanged control can take longer to report a verification
timeout. Setup, cleanup, and in-flight Accessibility calls can still add overhead
beyond the sampling budget.

Fresh checks and locking reduce races, but another user or controller can still
change Teams between a check and a press. Reused Accessibility objects also cannot
prove a meeting's identity.

### Leaving a call

`teams-cli call end` leaves your participation using the Leave button. It does not
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

For Teams commands, text output is one status word on stdout, with diagnostics on
stderr. With `--json`, stdout is one JSON object. The state key is `microphone`, `camera`,
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
| 0 | Help text / `teams-cli <version>` | Help or version requested |
| 2 | `unknown` / `ambiguous` | Inconclusive read or multiple possible controls |
| 3 | `permission_denied` | Accessibility permission unavailable |
| 4 | `not_running` | Teams was not found after the permission check |
| 5 | `unknown` | Accessibility communication failed |
| 6 | `unknown` / `ambiguous` | Action refused, busy, or outcome/focus not verified |
| 64 | Usage on stderr | Invalid command or options |

## Timing diagnostics

Add `--timings` to a microphone or camera toggle to collect a buffered timing trace:

```sh
.build/release/teams-cli mic toggle --json --timings
.build/release/teams-cli camera toggle --json --timings
```

These commands perform real toggles. The flag measures the normal action; it is
not a dry run. Use the release build when investigating latency. No polling,
timeouts, verification requirements, or focus rules change when tracing is enabled.

Normal stdout and exit codes are unchanged. After cleanup, focus monitoring
shutdown, lock release, and normal result output, the CLI writes one compact JSON
record to stderr. Existing stderr errors may precede it on separate lines. Hand,
status, desired-state, and call-end commands do not accept `--timings`.

The record has `type: "timings"`, `schema_version: 1`, `command`, `exit_code`,
`elapsed_ms`, `outcome`, and `spans`. Outcome fields contain the available state,
reason, success, action-attempted, and changed values; unavailable values are omitted.
Each span has an `id`, optional `parent_id`, `name`, `start_ms`, `duration_ms`,
`threw`, `counters`, `details`, `aggregates`, and `discovery_scans`.
IDs and offsets follow span start order.
Durations include child spans: **do not sum parents and their children**.
`threw` means that the measured operation threw an error, not that every returned
failure has that flag; use the command outcome to determine success.

The trace separates lock acquisition/release, focus checks and monitoring,
Accessibility setup/cleanup, initial/preflight observations, dispatch validation,
AXPress, every verification wait/observation, and result output. Observation details
include state and `can_press`, so a camera label change can be distinguished from
the control becoming ready. `accessibility_read` includes discovery; its nested
`discovery` span includes reader focus checks and any retry wait. Discovery counters
report visited nodes across scan attempts, total attribute calls (including batch
calls), batch attribute calls, scan attempts, and excluded main windows. These
counters cover discovery requests, excluding focus snapshots and direct
dispatch/readiness checks. Successful
reads report completeness; thrown reads retain partial counters. Setup failure
recovery is included in the setup span. No labels, titles, or participant data are
recorded.

Discovery `aggregates` group native batch requests into `node_attributes`,
`button_identifiers`, `main_window_identifiers`, `control_labels`, and (for hand
discovery) `image_labels`.
Each present group has `count` and summed `duration_ms`, including failed requests.
These durations are already included in discovery and exclude attribute decoding,
traversal, focus checks, and single-attribute requests. Aggregation avoids a span
per visited node. Discovery reads role and children per visited node, identifiers
for buttons and candidate search combo boxes, and labels only for relevant controls.

Each discovery span also records one `discovery_scans` entry per scan attempt,
including retries and partial failures. Entries contain `complete` and `windows`.
Each window reports its scan-local `window` number (matching the status snapshot),
`complete`, `visited_nodes`, traversal `duration_ms`, native-request `aggregates`,
and `branches`. `excluded_main_window` identifies an early exit after recognizing
the main shell; its counts and durations cover only the inspected prefix.
`complete` means that discovery completed for call selection, not that excluded
content was traversed. Optional `main_window_recognition` reports `main_shell`,
`call_surface`, `conflicting`, `unknown`, or `incomplete` from the inspected nodes.
Window duration excludes application/window-list discovery and includes local
traversal work; aggregate durations measure only native batches.

Branches partition the visited nodes at the first two forks, following single-child
wrapper chains without splitting them. Each has a local `id`, optional `parent_id`,
`root_depth` and `root_role`, plus `visited_nodes`, `max_depth`, role/control counts,
and native-request aggregates. Branch zero contains the window and initial wrappers.
Parent buckets exclude nodes assigned to child buckets, so branch counts and native
durations sum to their window totals. Shared nodes belong to the first path that
scheduled them. Up to 64 buckets per window are recorded; excess branches share an
`overflow: true` bucket without skipping any Accessibility reads. Unvisited buckets
may appear when a scan stops early. Window and branch IDs are not stable identities
across scans. Roles are normalized to a fixed allowlist, and control counts include
only known Teams call-control identifiers; titles, labels, and other identifiers
are never recorded. These profiles use existing reads and do not narrow discovery.

`bash scripts/audit-main-window.sh` builds and runs a separate, read-only qualification
tool with main-window exclusion disabled. It performs the full traversal and prints
a timing record with `main_window_recognition` for each window. Main-shell recognition
requires both the profile button (`idna-me-control-avatar-trigger`) and search
combo box (`ms-searchux-input`) with their expected roles. Any known call button
in the same window conflicts with that match, including one found later or deeper
in the tree. Incomplete scans cannot qualify a window. The tool reads identifiers
for every combo box, including those beyond the normal classification limits.
Conflicting or incomplete evidence produces a nonzero exit code; an unknown window
remains eligible for full discovery.
Use it when qualifying a different Teams layout or version. The audit does not
activate Teams, press controls, or write AX attributes; it only primes the WebView
helper with the usual role read. Its focus result compares endpoints, not transient
changes during inspection.

Timing uses a monotonic clock. `elapsed_ms` starts at the CLI's first timestamp,
after collecting raw arguments and detecting the flag, and ends after normal
result output and command finalization. It excludes process startup before that
timestamp, trace serialization/writing, and process teardown. Measure launch-to-exit
time externally when those costs matter. Spans do not partition the entire elapsed
time; uninstrumented work and recorder overhead occupy the gaps. Instrumentation
adds overhead, so compare traced stage timings with separate untraced total timings.
Without the flag, no recorder is allocated and no diagnostic clock is read.

Handled failures produce partial traces. A diagnostic write failure does not change
the action result or trigger another action. Automated fake-backend tests validate
timing accounting and behavior preservation; live latency measurements are separate
evidence.

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

## CI and releases

GitHub Actions runs the automated tests, a release build, CLI help and version,
and an archive smoke check on pull requests and pushes to `main`, using native Apple Silicon and
Intel macOS runners with Xcode 16.4. This does not validate live Teams behavior or
runtime compatibility with every supported macOS version.

Pushing a stable version tag such as `v0.1.0` runs the same checks on the tagged
commit and publishes both archives, `SHA256SUMS`, and generated release notes to
GitHub Releases. The tag's version is embedded in each executable, and packaging
checks that the binary and extracted archive report that version. See
[the release procedure](docs/releases.md) for exact commands and recovery instructions.

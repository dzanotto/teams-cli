# Timing and discovery diagnostics

See the [README](../README.md) for installation and command behavior.
Run the examples below from the repository root. The timing commands use a
release build.

## Collect a timing trace

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

## Timing record

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
dispatch/readiness checks. Successful reads report completeness; thrown reads
retain partial counters. Setup failure recovery is included in the setup span.
No labels, titles, or participant data are recorded.

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

## Measurement boundaries

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

## Main-window discovery

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

## Audit a Teams layout

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
